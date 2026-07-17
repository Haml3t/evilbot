# evilbot storage & host monitoring → Telegram

Proactive alerting for the evilbot Proxmox host: ZFS pool degradation, drive
failure, SMART early-warning, capacity, guest/service health — plus a two-layer
**dead-man's switch** so a dead monitor can't be mistaken for "all healthy".

Everything runs **on evilbot** (and a watchdog on **opsbot**), never on claudebot.
Alerts are delivered by a single sender, `notify-telegram.sh`, which curls the
Telegram Bot API using credentials in `/etc/zfs-alert.env` (root-only, **not in
this repo** — see `zfs-alert.env.example`). The sender talks to Telegram directly,
so alerts work even if the Telegram bot process is down.

## Layout

```
bin/                     scripts installed to /usr/local/bin on evilbot
  notify-telegram.sh       generic sender (reads /etc/zfs-alert.env)
  zfs-health-check.sh      daily: pool health, early SMART wear, capacity
  host-health-check.sh     daily: critical guests running + failed systemd units
  health-heartbeat.sh      weekly proof-of-life ("monitoring is alive")
  zfs-scrub-guarded.sh     monthly scrub, auto-skips while degraded/resilvering
  heartbeat-push.sh        pushes a liveness heartbeat to the opsbot watchdog
zed.d/                   ZFS Event Daemon zedlets → /etc/zfs/zed.d (run beside stock email)
  statechange-telegram.sh  vdev FAULTED/DEGRADED/UNAVAIL/REMOVED
  data-telegram.sh         checksum/data errors (early corruption)
  resilver_finish-telegram.sh / scrub_finish-telegram.sh
smartd/
  20telegram               /etc/smartmontools/run.d/ hook (fires beside 10mail email)
  DEVICESCAN.snippet       smartd.conf options: scheduled self-tests + temp alerts
systemd/                 units → /etc/systemd/system (timers + OnFailure alerter)
opsbot-watchdog/         the off-host half — installs on opsbot (see below)
```

## Alert triggers

| Source | Fires on |
|---|---|
| ZED `statechange` zedlet | a vdev goes FAULTED/DEGRADED/UNAVAIL/REMOVED |
| ZED `data` zedlet | checksum / read / write errors |
| ZED `resilver_finish` / `scrub_finish` | resilver or scrub completes (⚠️ if errors) |
| smartd `20telegram` | health fail, new pending/reallocated sectors, temp threshold, self-test fail |
| `zfs-health-check` (daily) | already-degraded pool, early SMART wear, tank ≥80/90% full |
| `host-health-check` (daily) | a critical guest (100/200/400/500/600) down, or any failed unit |
| `zfs-scrub-guarded` (monthly) | starts a scrub only if pool is ONLINE; else notifies it skipped |

## Dead-man's switch (so silence never reads as health)

- **On-host:** every monitoring unit has `OnFailure=alert-failure@%n.service` (it
  pings if a job fails to execute). `health-heartbeat` sends a weekly "alive"
  message; its absence is a human-detectable signal.
- **Off-host (opsbot):** evilbot pushes a heartbeat to opsbot every 15 min via a
  locked-down forced-command SSH key. `heartbeat-watchdog` on opsbot alerts if the
  heartbeat goes stale (>1 h) → catches evilbot being **down / hung / monitor-dead**,
  and sends a RECOVERED notice when it returns. Conversely `heartbeat-push.sh`
  alerts if evilbot can't reach opsbot → catches the watchdog itself being down.
  Mutual monitoring; each side covers the other.

## Install (evilbot)

```bash
install -m 0755 bin/*.sh /usr/local/bin/
install -m 0755 zed.d/*.sh /etc/zfs/zed.d/           # then: systemctl restart zfs-zed
install -m 0755 smartd/20telegram /etc/smartmontools/run.d/
# append smartd/DEVICESCAN.snippet options to /etc/smartd.conf; smartd -q onecheck; systemctl restart smartd
install -m 0644 systemd/* /etc/systemd/system/
cp zfs-alert.env.example /etc/zfs-alert.env && chmod 600 /etc/zfs-alert.env   # then fill in real token + chat_id
systemctl daemon-reload
systemctl enable --now zfs-health-check.timer host-health-check.timer \
  health-heartbeat.timer zfs-scrub-guarded.timer heartbeat-push.timer
```

## Install (opsbot watchdog)

```bash
install -m 0755 opsbot-watchdog/bin/*.sh /usr/local/bin/
install -m 0644 opsbot-watchdog/systemd/* /etc/systemd/system/
cp zfs-alert.env.example /etc/zfs-alert.env && chmod 600 /etc/zfs-alert.env   # fill in
# add opsbot-watchdog/authorized_keys.snippet (with evilbot's heartbeat pubkey) to /root/.ssh/authorized_keys
systemctl daemon-reload && systemctl enable --now heartbeat-watchdog.timer
```

## Notes

- The bot token now lives on three hosts (telegram VM, evilbot, opsbot), all in
  root-only `/etc/zfs-alert.env` (0600), never committed.
- ZED does **not** re-fire for an already-degraded pool on restart — the daily
  `zfs-health-check` covers that gap (and nags daily while degraded).
