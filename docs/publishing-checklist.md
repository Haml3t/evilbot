# Publishing Checklist

Practical, copy-pasteable steps to run **before every commit and push** to this
public repo. Pair this with [`SECURITY.md`](../SECURITY.md), which defines what
is and isn't safe to publish.

The golden rule: **scan the staged diff, not just the working tree.** Git
commits what is staged, so that is what you must inspect.

---

## One-time setup

The scan commands read your real sensitive terms from a **gitignored** file so
those terms never enter history. Create it from the template:

```bash
cp .safety-denylist.example .safety-denylist
# Edit .safety-denylist and fill in the REAL employer name, personal names,
# tailnet name, private repo names, and personal/employer emails.
```

`.safety-denylist` is gitignored; `.safety-denylist.example` (placeholders
only) is the public template. Verify it is ignored:

```bash
git check-ignore .safety-denylist   # should print: .safety-denylist
```

---

## Pre-commit scan

Run these from the repo root after `git add`, before `git commit`.

### 1. See exactly what is staged

```bash
git diff --cached --stat        # files + line counts
git diff --cached                # full staged diff — actually read it
```

### 2. Block any file that should never be committed

```bash
# List staged paths and flag the dangerous ones.
git diff --cached --name-only | grep -E \
  '(\.tfvars$|\.tfstate|\.env$|devbox-secrets\.env|devbox/repos\.txt$|devbox/CLAUDE\.md\.template$|\.safety-denylist$)' \
  && echo ">>> STOP: a never-commit file is staged. Unstage it." \
  || echo "OK: no obviously forbidden filenames staged."
```

> `.example` files are intentionally allowed — `terraform.tfvars.example` and
> `repos.txt.example` won't match the patterns above because of the `$`
> anchors. If a match fires, run `git restore --staged <file>` and confirm
> it's covered by `.gitignore`.

### 3. Scan the staged diff for secret-shaped strings

```bash
git diff --cached | grep -nEi \
  'password|passwd|secret|api[_-]?key|token|private[_-]?key|BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY|authorization:|bearer ' \
  && echo ">>> REVIEW the matches above — are any real secrets?" \
  || echo "OK: no secret-shaped strings in staged diff."
```

A hit is not automatically a leak (e.g. a variable named `api_token` with a
placeholder value is fine). Read each match and decide.

### 4. Scan the staged diff against your personal/employer denylist

```bash
# Matches the staged diff against the real terms in .safety-denylist.
grep -vE '^\s*(#|$)' .safety-denylist > /tmp/_denylist.$$    # strip comments/blanks
git diff --cached | grep -nFi -f /tmp/_denylist.$$ \
  && echo ">>> STOP: a denylisted personal/employer term is staged." \
  || echo "OK: no denylisted terms in staged diff."
rm -f /tmp/_denylist.$$
```

This catches the real employer name, real personal names, the real tailnet
name, private work-repo names, and personal/employer emails — without those
terms ever being written into a committed file.

### 5. Sanity-check commit author identity

```bash
git config user.name && git config user.email
```

Make sure this is the **public** identity you intend to publish under — not an
employer email or a personal name you keep private. Set per-repo if needed:

```bash
git config user.name  "Haml3t"
git config user.email "<your-public-noreply-email>"
```

### 6. For each new secret-bearing file, confirm the `.example` exists

```bash
# For anything sensitive you added, there should be a sanitized sibling.
git diff --cached --name-only
ls -la <dir>   # confirm foo.example is present and foo is gitignored
```

---

## Pre-push scan

`.gitignore` only protects files going forward — it does **not** retroactively
remove anything already committed. Before pushing, confirm nothing sensitive is
already tracked anywhere in the tree:

```bash
# Are any forbidden files currently tracked by git?
git ls-files | grep -E \
  '(\.tfvars$|\.tfstate|\.env$|devbox-secrets\.env|devbox/repos\.txt$|devbox/CLAUDE\.md\.template$|\.safety-denylist$)' \
  && echo ">>> STOP: forbidden file is tracked. Scrub before pushing." \
  || echo "OK: no forbidden files tracked."

# Scan the FULL history for denylisted terms (slower; do before first publish
# and after any history rewrite).
grep -vE '^\s*(#|$)' .safety-denylist > /tmp/_denylist.$$
git grep -nFi -f /tmp/_denylist.$$ $(git rev-list --all) -- 2>/dev/null \
  && echo ">>> STOP: denylisted term found in history." \
  || echo "OK: history clean of denylisted terms."
rm -f /tmp/_denylist.$$
```

If everything is clean: `git push`.

---

## Runbook: a secret was already committed

If a real secret (or a real identity) made it into a commit — staged, pushed,
or both — do these steps **in order**. Order matters.

### Step 1 — Rotate the secret FIRST (most important)

Assume it is compromised the instant it touched the repo, especially if pushed
to GitHub. Rewriting history does **not** un-leak it.

- Proxmox API token → revoke + reissue (Datacenter → Permissions → API Tokens).
- Telegram bot token → regenerate via @BotFather.
- Transmission RPC / any password → change it.
- SSH private key → generate a new keypair, replace `authorized_keys` entries.

History scrubbing is damage control; rotation is the actual fix.

### Step 2 — Rewrite history to remove the value

Use [`git filter-repo`](https://github.com/newren/git-filter-repo) (not the
deprecated `filter-branch`). Work on a fresh clone or ensure a backup exists.

Remove a specific file from all history:

```bash
git filter-repo --invert-paths --path path/to/leaked.tfvars
```

Redact specific strings (read replacements from a file so the real secret
isn't in your shell history). Create `replacements.txt`:

```
literal:REAL_SECRET_VALUE==>REDACTED
regex:tok_[0-9a-f]{32}==>REDACTED
```

Then:

```bash
git filter-repo --replace-text replacements.txt
rm replacements.txt   # don't leave the real value lying around
```

`filter-repo` intentionally removes the `origin` remote after rewriting. Re-add
it:

```bash
git remote add origin git@github.com:Haml3t/evilbot.git
```

### Step 3 — Force-push the rewritten history

Prefer `--force-with-lease` over `--force` so you don't clobber commits you
haven't seen:

```bash
git push --force-with-lease --all
git push --force-with-lease --tags
```

### Step 4 — Mind the lingering-commits caveat

Even after a successful force-push, **the old commits are not gone from GitHub
immediately.** They remain reachable by their raw SHA (e.g. via cached views,
forks, pull-request refs, and the API) until GitHub's garbage collection runs —
which is not on a schedule you control.

- If anyone forked or pulled, the secret lives in their copy too.
- To force removal sooner, **contact GitHub Support** and ask them to purge the
  stale references / run GC, citing the rewrite.
- This is exactly why **Step 1 (rotate) is non-negotiable** — by the time GC
  runs, a leaked live credential may already have been scraped.

### Step 5 — Re-verify

Re-run the pre-push history scan above. Confirm the file/term no longer appears
in `git rev-list --all`, and that `git ls-files` no longer tracks it.
