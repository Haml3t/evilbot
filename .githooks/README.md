# Git hooks

This directory holds repo-managed git hooks that guard against leaking secrets
or sensitive personal/employer information into this **public** repository.

## Install

Git does not run hooks from a committed directory by default. Point git at this
directory once per clone:

```bash
git config core.hooksPath .githooks
```

That's it — `pre-commit` will now run on every `git commit` in this clone.

To confirm it is active:

```bash
git config --get core.hooksPath   # should print: .githooks
```

## What `pre-commit` checks

It scans the **staged** changes (the content that would actually be committed)
and blocks the commit if it finds any of:

- **Private keys** — `-----BEGIN ... PRIVATE KEY-----` blocks.
- **Secret assignments** — `password=`, `token=`, `secret=`, `api_key=`, AWS
  access key ids, and long high-entropy secret-looking values.
- **Secret files** — content of any staged `*.tfvars`, `*.tfstate`,
  `*.tfstate.*`, `.env`, or `devbox-secrets.env` file. (`*.example` templates
  are allowed.)
- **Sensitive terms** — personal names, employer/internal markers, and the
  private tailnet name, read from a **local, gitignored** denylist file.

The structural secret patterns above are generic and hardcoded in the hook (they
are not themselves sensitive). The personal/employer/tailnet terms are **never**
hardcoded in this public hook — they are read at runtime from `.safety-denylist`.

## Set up the local denylist (required for sensitive-term checks)

`.safety-denylist` is **gitignored** and holds your real sensitive terms, so they
never enter git history. Create it from the public template:

```bash
cp .safety-denylist.example .safety-denylist
# then edit .safety-denylist and add your real names / employer / tailnet terms
```

Each non-comment, non-blank line is a case-insensitive extended regex. Use word
boundaries for short tokens (e.g. `\bjon\b`) to avoid false positives.

If `.safety-denylist` is absent, the hook still runs but prints a warning and
skips the sensitive-term checks (structural secret checks still apply).

## Bypassing (discouraged)

If you are **certain** a finding is a false positive, you can bypass the hook:

```bash
git commit --no-verify
```

Prefer fixing the finding (or refining `.safety-denylist`) over bypassing.
