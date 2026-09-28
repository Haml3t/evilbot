# Satellite playbook (personal Ubuntu machines)

Brings a personal machine to the Hermes safety baseline. Generic and public; every
machine-specific value (hostnames, IPs, restic passwords) lives OUTSIDE this repo,
on hermesbot in `~/.hermes/fleet/` (inventory + host_vars, mode 0600).

Order per machine (see ~/.hermes/plans/ on hermesbot for the full plan):

1. Operator runs `fleet/satellite-bootstrap.sh`, which creates `hermes`, installs
   hermes-grant, and opens a 120-min sudo window.
2. Hermes runs `ansible-playbook -i ~/.hermes/fleet/inventory.ini satellite.yml -l <host>`.
   The last task closes the sudo window.
3. Hermes runs `fleet/satellite-gate.sh <host>`. It passes only when every
   check passes.

What the playbook enforces:
- `hermes` user: locked password, pubkey only, no supplementary groups, sshd
  `Match User hermes` (no forwarding)
- every other /home/* has no access for "other", so hermes can't read the operator's
  or a future work user's files
- standing sudo allowlist `/etc/sudoers.d/hermes` (read-only diagnostics +
  backup status/verify), with the same audit Defaults as fleet/grant-hermes-sudo.sh
- restic backup to the append-only rest-server on evilbot-nas: daily systemd
  timer, Persistent=true (catches up after the laptop is off), skipped cleanly
  when the NAS is unreachable
- `backup_exclude_users`: set a work user here so it is never backed up
