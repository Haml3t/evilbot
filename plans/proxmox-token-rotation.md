# Proxmox token rotation — runbook

Status: DRAFT, not executed. Written 2026-08-31 by the Hermes agent.

## Why

`inventory.yaml` records the read-only Proxmox token as `hermes-ro@pve!ro`
(PVEAuditor, granted on `/`), credentials in `~/.hermes/proxmox-ro.env` mode 600
on hermesbot. The handoff's P3 item: "Rotate the read-only Proxmox token. Its
secret was displayed on a terminal during setup. Low blast radius, but hygiene."

The secret value was shown in cleartext during setup, so treat it as exposed and
rotate it. Blast radius is genuinely low — the token is read-only PVEAuditor —
so this is hygiene, not emergency. Do it in a maintenance window when no cron
depends on the API for a few minutes.

## What the rotation touches

Three places reference this token, and all three must agree or the agent goes
blind (read-only API access silently 403s):

1. The Proxmox token itself (`pveum` on evilbot).
2. `~/.hermes/proxmox-ro.env` on hermesbot (mode 600).
3. The canonical copy in `/tank/vault/secrets.git` once it is seeded.

The read-only token has **no** consumer other than Hermes — no Terraform, no
cron on other hosts uses `hermes-ro@pve!ro`. (Terraform uses a *different*
token, `terraform-lxc@pve!lxc`.) So rotation is low-risk: only hermesbot reads it.

## Steps

### 1. Remove the old token (evilbot, as root)

```
pveum user token remove hermes-ro@pve ro
```

Do NOT touch the `hermes-ro@pve` *user* — only the token under it. The user
carries the PVEAuditor role grant on `/`; keep it.

### 2. Re-create with a fresh secret (evilbot, as root)

```
pveum user token add hermes-ro@pve ro --privsep 1
```

This prints the new secret once, to stdout. Capture it immediately. If you miss
it, remove and re-add — the secret is not retrievable afterward.

### 3. Update hermesbot (as hermes, on hermesbot)

```
chmod 600 ~/.hermes/proxmox-ro.env
printf 'PVE_API_URL=https://192.168.0.145:8006\n' > ~/.hermes/proxmox-ro.env
printf 'PVE_TOKEN_ID=hermes-ro@pve!ro\n' >> ~/.hermes/proxmox-ro.env
printf 'PVE_TOKEN_SECRET=<new-secret>\n' >> ~/.hermes/proxmox-ro.env
```

The `.env` currently uses keys `PVE_API_URL`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`
(verified from the file). Preserve those exact names — Hermes reads them
directly.

### 4. Verify (from hermesbot)

```
. ~/.hermes/proxmox-ro.env
curl -sk -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
  "${PVE_API_URL%/}/api2/json/nodes/evilbot/status" | jq -r .data.status
```

Expect `"online"`. If you get a 401/403, re-check step 2 (privsep intersection —
the user grant must exist, see inventory note) and step 3's token id.

### 5. Store the canonical copy in the vault

Once `/tank/vault/secrets.git` is seeded, commit the new secret there so the
vault is the source of truth and hermesbot's `.env` is a working copy.

## Revert

If verification fails, re-run step 2 (a new secret), then step 3 and 4. There is
no rollback of a secret that was printed once — you rotate forward, not back.
Because the token is read-only and single-consumer, forward rotation is cheap.

## Not affected

- `terraform-lxc@pve!lxc` (the IaC token) — not touched. Its secret lives in the
  vault/`tfvars`, not in the agent's read-only path.
- The `hermes-ro@pve` user and its PVEAuditor role grant — unchanged.
