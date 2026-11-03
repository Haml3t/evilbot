# CT 810 `logseq` — headless Logseq DB sync client for Hermes

Purpose: a live, synced copy of the operator's Logseq DB graph that Hermes can read and write
over SSH with the official `logseq` CLI. Same graph as the operator's desktop and phone, via Logseq
cloud sync (db-sync). No listening ports. Hermes has full read/write access by decision on 2026-10-22.

## Why it looks like this

- **The CLI comes from the desktop release, not npm.** `@logseq/cli` on npm (0.4.x) is
  the old pre-sync CLI. The sync-capable CLI (`login`, `sync`, `graph backup`) ships only
  inside the desktop app's `app.asar`. `install-logseq-cli.sh` extracts it and runs it on
  plain Node.
- **Missing modules.** Three modules aren't in the desktop bundle's node_modules: `@emoji-mart/data`,
  `chrono-node`, `jszip`. The installer finds them by scanning `require()`s and pins them
  from the release's own package.json. They go in `/opt/logseq/extra-<ver>` and load via `NODE_PATH`.
- **`libsecret-1-0` is required.** keytar dlopens it, and without it the worker exits with
  "Worker exited before becoming ready". There's no keychain daemon, so the E2EE password falls back to
  `~/logseq/kv-store.json` (mode 600). That's the reason this is its own container.
- **No MCP server.** In 2.0.2 the MCP endpoint exists only in the Electron app's API
  server, not in the CLI. Hermes drives the CLI over SSH (`ssh logseq logseq ...`).

## Layout

| Path | What |
| --- | --- |
| `/opt/node` | Node LTS (sha256-verified tarball) |
| `/opt/logseq/<ver>`, `/opt/logseq/current` | extracted CLI + db-worker-node |
| `/usr/local/bin/logseq` | wrapper |
| `/usr/local/sbin/install-logseq-cli` | installer/upgrader (`install-logseq-cli.sh`) |
| `/usr/local/bin/logseq-sync-loop` | keeps `sync start` alive (`logseq-sync.service`) |
| `/usr/local/bin/logseq-backup` | hourly snapshot, keep 72 (`logseq-backup.timer`) |
| `~hermes/.config/logseq-sync.env` | `GRAPH=<name>` — which graph to sync |
| `~hermes/logseq/` | CLI root: graphs, auth.json, kv-store.json, cli.edn |

## Build (already done 2026-10-22)

1. `cd vm-iac/logseq-lxc && terraform apply` using the `hermes-lxc@pve!lxc` token (pool `hermesbots`).
2. As root on CT 810: `apt-get install -y unzip curl ca-certificates sudo xz-utils libsecret-1-0 unattended-upgrades`,
   install Node LTS to `/opt/node`, create user `hermes` (pubkey only, password locked), then
   `install-logseq-cli 2.0.2`.
3. Copy the two scripts and `systemd.units` sections into place, then
   `systemctl enable --now logseq-sync.service logseq-backup.timer`.
4. `install-hermes-grant.sh` plus the standing sudoers below. Then empty `/root/.ssh/authorized_keys`.
   Recovery is `pct enter 810` on evilbot.

Standing sudo (`/etc/sudoers.d/hermes`, I/O-logged): start/stop/restart `logseq-sync.service`,
start `logseq-backup.service`, and `install-logseq-cli <x.y.z>`. Everything else goes through `hermes-grant`.

## Operator steps (once)

**A. Nightly vzdump** — done 2026-10-27: `nightly-guests` now covers `100,200,300,400,700,800,810`.
Check with `pvesh get /cluster/backup/nightly-guests --output-format json | grep -o '"vmid":"[^"]*"'`.

**B. Log in (browser flow only).** Password login (`--username/--password`) does not work for
accounts that use Google/Apple sign-in. The CLI calls `xdg-open`, which CT 810 doesn't have, so
`~hermes/bin/xdg-open` is a shim (on PATH via `~/.profile`, so use `su - hermes`). It writes the
URL to `~/login-url`. The callback listens on CT 810's `[::1]:8765`, so the browser redirect fails
and you replay it with curl. Use two shells, both via `pct enter 810` then `su - hermes`:
```
# shell 1: leave it running, don't Ctrl-C (it waits about 5 minutes)
logseq login
# shell 2
cat ~/login-url              # open in browser, sign in, copy the failed localhost:8765/auth/callback?... URL
read -rp 'callback URL: ' C; curl -sg "${C/localhost/[::1]}"; unset C
```
Shell 1 then writes `~/logseq/auth.json`. Tokens refresh by themselves after that.

**C. First sync.** The graph must already exist remotely, created and synced from the desktop app.
```
G=<graph name>
read -rsp 'E2EE password: ' E; echo
logseq sync download --graph "$G" --e2ee-password "$E" --progress
logseq sync start    --graph "$G" --e2ee-password "$E" --timeout-ms 30000; unset E
sed -i "s/^GRAPH=.*/GRAPH=$G/" ~/.config/logseq-sync.env
```
`sync remote-graphs` needs `--graph` and does not list all remote graphs. Get the name from the desktop app.
If `sync start` times out and `~/logseq/graphs/$G/db-worker-node-*.log` shows
`:client-op-not-ready`, make one edit in the desktop app, let it sync, then run
`logseq graph remove --graph "$G"` and repeat C.

**Gate (passed 2026-10-27):** `sync status` shows `ws-state: open` and `pending-local: 0`. A page written
on CT 810 shows up on the desktop and the phone.

## Upgrades

- CLI: upgrade only **after** the operator's desktop is on the new version (the sync protocol changes between betas).
  Run `sudo install-logseq-cli 2.0.3 && sudo systemctl restart logseq-sync.service`.
  Old versions stay in `/opt/logseq/`. Roll back by repointing `current` (needs hermes-grant).
- OS: unattended-upgrades, Debian security updates.
- Node: manual, LTS only, via hermes-grant.

## Restore

```
sudo systemctl stop logseq-sync.service
logseq graph backup list --graph "$G"
logseq graph backup restore --graph "$G" --src <backup-name>
```
Warning: a restored local graph and the remote copy can disagree. Restoring here doesn't roll back
the other devices. For a remote-side mistake, restore on one device, check it, then let sync
carry it forward. Test this on a throwaway graph first.
