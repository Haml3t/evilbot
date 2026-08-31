# Tailscale autoApprovers.routes — change doc

Status: PROPOSED, not applied. Written 2026-08-31 by the Hermes agent.

## The problem this fixes

`fleet/inventory.yaml` (evilbot trap) records a failure that cost ~7 weeks in
2026:

> "A re-advertised route is NOT auto-approved; the stale approval also persists.
> Missing this broke tailnet LAN access for ~7 weeks."

Concretely: when evilbot re-advertises its subnet route (e.g. after a network
move), Tailscale does not auto-approve the re-advertisement, AND the stale
approval from the old advertisement persists. The result is a silently broken
tailnet-LAN path that looks configured but isn't — the same failure shape as the
image-api subnet regression (no error, just a dead route).

## What to change

Add `autoApprovers` to the tailnet ACL policy so subnet-route re-advertisements
are self-healing. The change is made in the Tailscale admin console (or via the
`tailscale` policy file / API), not on any host.

The policy fragment (names redacted for the public repo — the real tailnet name
and real route are in the local-only vault / admin console):

```jsonc
{
  // ... existing ACL policy ...
  "autoApprovers": {
    // Subnet routes advertised by the tailnet's own router host are approved
    // automatically, so a re-advertisement does not strand the LAN path.
    "routes": {
      "192.168.0.0/24": ["<router-host-tag-or-user>"]
    }
  }
}
```

The `<router-host-tag-or-user>` is whatever identity evilbot's tailnet node
carries — a tag (e.g. `tag:infra`) or the account email. Using a **tag** is
preferred over an email: a tag survives node re-registration, whereas an
email/user binding breaks if the node is re-keyed.

## Why it is safe

- `autoApprovers` only affects *route approval*, not device approval. Devices
  still require their own approval to join the tailnet.
- The route is `192.168.0.0/24` — the LAN the tailnet is already meant to
  bridge. Auto-approving it does not expand reach: it removes a manual step that
  was being missed.
- The existing trap says the stale approval *persists*, so the current manual
  flow leaves a half-state. Auto-approval makes the outcome deterministic.

## Verification after applying

1. Re-advertise the route on evilbot (or wait for the next natural re-key).
2. In the admin console, confirm the route shows as approved without manual
   action.
3. From a tailnet client, confirm `192.168.0.x` hosts are reachable over the
   tailnet.
4. Update `fleet/inventory.yaml`: mark the `also_update` checklist item and the
   evilbot trap as resolved, so the trap no longer reads as an active landmine.

## Not in scope

- Device auto-approval (`autoApprovers` for nodes) — NOT requested; the trap is
  specifically about routes.
- Migrating the tailnet ACL to a committed file. The policy is currently managed
  in the admin console; moving it into version control is a separate decision
  (and would need the real tailnet name redacted, which the public repo forbids).

## Open question for the human

- Does evilbot's tailnet node carry a tag, or is it bound to the account email?
  The answer determines the `<router-host-tag-or-user>` value. This can only be
  read from the admin console (or `tailscale status` on evilbot), not from the
  repo.
