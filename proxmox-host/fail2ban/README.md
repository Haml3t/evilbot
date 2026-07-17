# fail2ban (evilbot)

Bans IPs that repeatedly fail SSH auth. evilbot is **journald-only** (no `rsyslog`,
no `/var/log/auth.log`), which breaks the stock Debian sshd jail — it aborts at
startup with `status=255` ("Have not found any log file for sshd jail"), leaving the
host with **no brute-force protection**.

## Fix

`jail.local` → `/etc/fail2ban/jail.local`, then:

```bash
fail2ban-client -t              # validate config
systemctl restart fail2ban
systemctl status fail2ban       # active
fail2ban-client status sshd     # jail loaded; check "Journal matches"
```

Two things matter on this host:
1. `backend = systemd` — read auth events from the journal, not a file.
2. `journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd` — Debian logs sshd under
   `ssh.service`, but the stock filter matches `sshd.service`. Without this override
   fail2ban starts cleanly but detects nothing.

Confirm it actually matches real failures (read-only, no bans):

```bash
fail2ban-regex --journalmatch "_SYSTEMD_UNIT=ssh.service + _COMM=sshd" \
  systemd-journal /etc/fail2ban/filter.d/sshd.conf
```
