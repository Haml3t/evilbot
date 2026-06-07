#!/usr/bin/env python3
"""
PreToolUse guard for claudebot.

Routes risky/infra-touching tool calls to a per-command APPROVAL PROMPT (not a
hard block) by emitting permissionDecision="ask". The harness then asks the human
to confirm and runs the command only if approved. "ask" overrides allow-list
auto-approval AND the auto-mode classifier, so these never run unattended.

Tiers (Bash):
  1. CATASTROPHIC  — zpool/zfs destroy, mkfs, dd of=/dev, rm -rf <sensitive>, etc.
  2. REMOTE/INFRA  — any ssh/scp to a host (the main channel to evilbot & VMs).
  3. HOST-MUTATING — terraform apply/destroy, mutating Proxmox API calls (curl
                     -X POST/PUT/DELETE to :8006). These change evilbot from
                     *claudebot itself*, so an ssh match wouldn't catch them.
Plus self-modification of governance files (settings/hooks/CLAUDE.md/ssh keys).

Everything else returns no opinion (exit 0) so ordinary local work still flows in
auto mode. Fails OPEN on parse errors — never wedges the harness.

Why "ask" not "deny": the human wants to approve each infra command and have
Claude execute it, not be forced to drop to a shell.
"""
import json
import re
import sys

# ---- Tier 1: catastrophic / irreversible (specific reason shown) ----
DANGEROUS = [
    (re.compile(r"\bzpool\s+(destroy|labelclear)\b"),
     "zpool destroy/labelclear — irreversible destruction of the entire pool"),
    (re.compile(r"\bzfs\s+destroy\b"),
     "zfs destroy — irreversible dataset/snapshot deletion"),
    (re.compile(r"\bzfs\s+rollback\b"),
     "zfs rollback — discards data newer than the snapshot"),
    (re.compile(r"\bpct\s+destroy\b"), "pct destroy — deletes an LXC container"),
    (re.compile(r"\bqm\s+destroy\b"), "qm destroy — deletes a VM"),
    (re.compile(r"\bpvesm\s+(remove|free)\b"), "pvesm remove/free — storage removal"),
    (re.compile(r"\b(lvremove|vgremove|pvremove)\b"), "LVM removal"),
    (re.compile(r"\bmkfs(\.\w+)?\b"), "mkfs — formats a filesystem"),
    (re.compile(r"\bwipefs\b"), "wipefs — erases filesystem signatures"),
    (re.compile(r"\bdd\b[^\n]*\bof=\s*/dev/"), "dd to a block device"),
]
SENSITIVE_RM_TARGET = re.compile(
    r"(\$\{?\w*\}?|/tank\b|/etc\b|/root\b|/var\b|/usr\b|/boot\b|/dev\b)")

# ---- Tier 2: any ssh/scp to a host (exclude ssh-keygen/-keyscan/-add, sshd) ----
REMOTE = re.compile(r"\b(ssh|scp)\b(?!-)")

# ---- Tier 3: host-mutating actions issued from claudebot itself ----
HOST_MUTATING = [
    (re.compile(r"\bterraform\s+(apply|destroy)\b"),
     "terraform apply/destroy — creates or tears down containers on evilbot"),
    (re.compile(r"\bpveum\b"), "pveum — modifies Proxmox users/roles/ACLs"),
    (re.compile(r"\bcurl\b[^\n]*-X\s*(POST|PUT|DELETE)[^\n]*192\.168\.1\.\d+:8006"),
     "mutating Proxmox API call to the host"),
]

# ---- Self-modification of governance files ----
SELF_MOD = [
    (re.compile(r"/\.claude/settings(\.local)?\.json$"),
     "edits the agent's own permission/hook settings"),
    (re.compile(r"/\.claude/hooks/"), "edits the agent's own guard hooks"),
    (re.compile(r"/\.claude\.json$"), "edits the agent's global config"),
    (re.compile(r"/CLAUDE\.md$"), "edits the agent's standing instructions"),
    (re.compile(r"/\.ssh/(authorized_keys|config)$"), "edits SSH trust/config"),
]


def ask(reason: str) -> int:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }}))
    return 0


def rm_is_dangerous(cmd: str) -> bool:
    for m in re.finditer(r"\brm\b((?:\s+-\S+|\s+[^\s;|&]+)*)", cmd):
        args = m.group(1)
        flags = "".join(re.findall(r"(?:^|\s)-(\w+)", args))
        if "r" in flags and "f" in flags:
            if SENSITIVE_RM_TARGET.search(args) or re.search(r"\s/\s*($|;|&|\|)", args):
                return True
    return False


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # fail open

    tool = data.get("tool_name", "")
    tin = data.get("tool_input", {}) or {}

    if tool == "Bash":
        cmd = tin.get("command", "") or ""
        if not cmd:
            return 0
        for pat, reason in DANGEROUS:
            if pat.search(cmd):
                return ask("Catastrophic command (%s). Irreversible loss possible "
                           "on the Proxmox host — approve only if exactly intended." % reason)
        if rm_is_dangerous(cmd):
            return ask("Recursive force-remove (rm -rf) on a sensitive path or "
                       "unquoted variable — approve only if intended.")
        for pat, reason in HOST_MUTATING:
            if pat.search(cmd):
                return ask("Host-mutating: %s. Approve to run against evilbot." % reason)
        if REMOTE.search(cmd):
            return ask("Remote command over ssh/scp to an infrastructure host. "
                       "Approve to run it on the remote machine.")
        return 0

    if tool in ("Edit", "Write", "MultiEdit"):
        path = tin.get("file_path", "") or ""
        for pat, reason in SELF_MOD:
            if pat.search(path):
                return ask("Self-modification: this %s (%s). Approve to let the "
                           "agent change its own guardrails." % (reason, path))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
