# evilbot PVE service hardening

systemd drop-ins that make the Proxmox host daemons **self-heal after a crash**.

## Why

On **2026-07-24 07:44 EDT** `pvestatd` took a perl general protection fault and was
killed with SIGSEGV:

```
kernel: traps: pvestatd[2220] general protection fault ip:5a604c85ee3a
        sp:7fff60e65990 error:0 in perl[5a604c767000+195000]
systemd[1]: pvestatd.service: Main process exited, code=killed, status=11/SEGV
```

The stock `/lib/systemd/system/pvestatd.service` ships **no `Restart=` directive**,
so nothing brought it back. It sat failed for **3 days** until the daily
`host-health-check` (see `../monitoring/`) alerted to Telegram. Guests kept running
— pvestatd only collects stats — but the web UI showed stale metrics and the RRD
graphs have a 3-day gap.

Its sibling daemons (`pve-cluster`, `pvedaemon`, `pveproxy`) already ship
`Restart=on-failure` upstream. pvestatd was simply the odd one out.

## What's covered

| Unit | Stock `Restart=` | Here |
|---|---|---|
| `pve-cluster`, `pvedaemon`, `pveproxy` | `on-failure` | — (already fine upstream) |
| `pvestatd` | *(none)* | `on-failure` ✅ |
| `pve-firewall` | `no` | `on-failure` ✅ |
| `pvescheduler` | `no` | `on-failure` ✅ |
| `pve-ha-lrm`, `pve-ha-crm` | `no` | **deliberately left alone** ⚠️ |
| `spiceproxy` | `no` | skipped (unused here) |

⚠️ **Do not add these drop-ins to the `pve-ha-*` units.** HA has its own fencing
semantics — a node that cannot run its HA services is *supposed* to stay down so
the cluster can fence it. Auto-restarting them papers over that.

## Install (evilbot)

```bash
cp -r pvestatd.service.d pve-firewall.service.d pvescheduler.service.d \
  /etc/systemd/system/
chmod 0644 /etc/systemd/system/*.service.d/restart.conf
systemctl daemon-reload
```

Drop-ins live in `/etc/systemd/system/`, so they survive `apt full-upgrade` —
package updates only replace the units under `/lib/systemd/system/`.

## Verify

```bash
for u in pvestatd pve-firewall pvescheduler; do
  printf '%-16s %s\n' "$u" "$(systemctl show $u -p Restart --value)"
done
# expect: on-failure for all three

# and confirm the HA units were NOT touched
for u in pve-ha-lrm pve-ha-crm; do
  printf '%-16s %s\n' "$u" "$(systemctl show $u -p Restart --value)"
done
# expect: no
```

End-to-end test — reproduce the original crash signature and watch it recover
(safe; pvestatd is stats-only):

```bash
kill -SEGV "$(systemctl show -p MainPID --value pvestatd.service)"
sleep 25 && systemctl is-active pvestatd.service   # -> active
```

Verified working 2026-07-27: systemd logged `Scheduled restart job, restart counter
is at 1` and the daemon was back **10 s** later with a new PID.
