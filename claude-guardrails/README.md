# claude-guardrails

Guardrails that bound what Claude Code (running as the **claudebot** AI workspace) can do to
the Proxmox host. Background and rationale: [`../docs/claudebot-hardening.md`](../docs/claudebot-hardening.md).

## `guard-destructive.py`

A Claude Code **PreToolUse hook**. On every tool call it inspects the command/file and, for
anything that touches infrastructure or is irreversible, returns
`permissionDecision: "ask"` — forcing a per-command approval prompt that the human must
confirm before the command runs. This overrides the permission allow-list **and** auto-mode,
so risky commands never execute unattended. It fails *open* on a parse error so it can never
wedge the harness.

What it prompts on (everything else runs normally):

- **Catastrophic** — `zpool/zfs destroy`, `zfs rollback`, `pct/qm destroy`, `mkfs`,
  `wipefs`, `dd of=/dev/*`, `rm -rf` on a sensitive path or unquoted variable. Matched even
  when wrapped inside an `ssh root@host "…"` payload.
- **Remote/infra** — any `ssh`/`scp` to a host.
- **Host-mutating from claudebot itself** — `terraform apply|destroy`, local `pveum`,
  mutating Proxmox API calls (`curl -X POST/PUT/DELETE … :8006`).
- **Self-modification** — edits to the agent's own `settings*.json`, `.claude/hooks/*`,
  `CLAUDE.md`, or `~/.ssh/authorized_keys|config`.

## Installing

Copy the hook to the Claude config dir and register it in `settings.json`:

```bash
mkdir -p ~/.claude/hooks
cp guard-destructive.py ~/.claude/hooks/guard-destructive.py
```

```jsonc
// ~/.claude/settings.json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/guard-destructive.py" }] },
      { "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/guard-destructive.py" }] }
    ]
  }
}
```

Then reopen `/hooks` (or restart the session) so the hook loads, and verify it fires:

```bash
# Should produce an approval prompt before running:
ssh root@<proxmox-host> hostname
```

> Hooks added mid-session are not active until `/hooks` is reopened or the session restarts.
> In auto mode, this hook (returning `"ask"`) is what forces prompts — *removing* a
> permission allow rule does not.
