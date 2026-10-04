# hindsight-lxc

Terraform module for the Hindsight long-term memory server (vmid 800), cloned
from the `vm-iac/devbox/` pattern.

## What this creates

A Debian 12 LXC, unprivileged, in the `hermesbots` Proxmox pool, sized for
Hindsight's own stated requirements (4GB RAM min / 8GB recommended for
production; this module defaults to 6GB as a personal-deployment middle
ground). Only `nesting` is enabled: every other feature flag (incl. `keyctl`)
is root@pam-only in PVE, so the pool-scoped token cannot set it. If Docker
needs keyctl, root runs `pct set 800 --features nesting=1,keyctl=1`.
No `tags` either — PVE checks tag perms on /vms/<vmid> ignoring the pool.

Token also needs `PVESDNUser` on `/sdn/zones/localnetwork/vmbr0` (bridge
access is checked even with no SDN configured). Granted 2026-10-04.

This module creates the **empty container only**. Docker + the Hindsight
container itself are installed afterward via a separate bootstrap step (not
yet written — see Next steps), matching the fleet's existing split between
"Terraform provisions the shell" and "a bootstrap/Ansible script configures
the software."

## Prerequisites

The Proxmox API token used here (`hermes-lxc@pve!lxc`) must already exist,
scoped to the `hermesbots` pool + `local-lvm` storage + read-only `PVEAuditor`
on `/`. Created 2026-10-04 during a time-boxed `hermes-grant` window on
evilbot — see `plans/proxmox-host-safety.md` for the precedent this follows
(claudebot's `ClaudebotLXC` role) and `docs/hermes-handoff.md` for how to
re-derive it if ever lost. **No `PVEAdmin`, no `Sys.PowerMgmt`, no
`Datastore.Allocate`** — verified with negative tests (403 on host reboot,
403 on touching VMs outside the pool, 403 on storage outside `local-lvm`).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in proxmox_api_token from ~/.hermes/proxmox-lxc.env on hermesbot
terraform init
terraform plan
terraform apply
```

## Networking

DHCP on first bring-up, deliberately — not static. inferbot/opsbot/hermesbot
get static IPs because other things depend on their address; hindsight
doesn't have that dependency yet (nothing points at it until the memory
provider is wired up). Once the DHCP-assigned address is confirmed stable and
collision-free, switch it to a router-level DHCP reservation, matching how
the other static guests were pinned (see `CLAUDE.md`'s MAC-pinning note for
evilbot-nas as the precedent and its gotcha: a regenerated MAC silently moves
the IP).

## pool_id warning

`pool_id` is `ForceNew` in the `bpg/proxmox` Terraform provider. It is set
here **at creation**. Never add or change it on an *existing* applied
module — doing so plans a **destroy** of the running container. This bit
inferbot and opsbot's modules once already; both now carry a warning comment
for exactly this reason.

## Next steps (not done by this module)

1. Bootstrap: create an unprivileged `hermes` OS user + install
   `fleet/install-hermes-grant.sh`, same as every other guest. Root SSH
   (via `ssh_public_key`) is for this step only, not a long-term access path.
2. Install Docker (`apt-get install docker.io` or the official repo).
3. Run the Hindsight container:
   ```bash
   docker run -d --name hindsight --restart unless-stopped --shm-size=1g \
     -p 8888:8888 -p 9999:9999 \
     --env-file /etc/hindsight.env \
     -v hindsight-data:/home/hindsight/.pg0 \
     ghcr.io/vectorize-io/hindsight:latest
   ```
4. Decide: bind to loopback only + reverse proxy, or to the container's real
   IP for LAN/tailnet dashboard access. Hindsight has **no authentication by
   default** — worth deciding deliberately, not by default exposure.
5. Join Tailscale if off-LAN dashboard/API access is wanted.
6. Wire `hermes memory setup` on hermesbot to point at this server.
