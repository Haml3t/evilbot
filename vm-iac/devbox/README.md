# devbox

Disposable dev sandbox containers — pre-loaded with work repos and Claude Code.

Each devbox is an LXC on evilbot. Spin one up, use it, destroy it. The next one
comes up identical.

## What you get

- Debian 12, Node.js 22, Python 3, git
- Claude Code CLI pre-installed — first SSH triggers OAuth login automatically (one-time, browser-based)
- Work SSH key wired to `github.com` so you can push/pull immediately
- Work repos cloned into `~/work/` automatically
- Bootstrap log at `/root/bootstrap.log`

## One-time setup (do this once, not per container)

### 1. Create the secrets file on evilbot

```bash
# From claudebot:
scp devbox-secrets.env.example root@192.168.1.145:/root/.secrets/devbox.env
ssh root@192.168.1.145 "vi /root/.secrets/devbox.env"
```

Fill in:
- `GITHUB_USER` / `GITHUB_EMAIL` — for git config
- `GITHUB_SSH_KEY_B64` — base64-encoded work SSH private key
- No API key needed — Claude Code uses OAuth login on first SSH:

```bash
# Generate a new key (or encode an existing one):
ssh-keygen -t ed25519 -f ~/.ssh/work_devbox_id_ed25519 -C "devbox@work"
base64 < ~/.ssh/work_devbox_id_ed25519   # paste into GITHUB_SSH_KEY_B64

# Add the public key to GitHub:
cat ~/.ssh/work_devbox_id_ed25519.pub    # → GitHub → Settings → SSH and GPG keys
```

### 2. Add your work repos to repos.txt

```bash
cp repos.txt.example repos.txt
```

Edit `repos.txt` and add SSH clone URLs — one per line:

```
git@github.com:work-org/backend.git
git@github.com:work-org/frontend.git
```

`repos.txt` is gitignored (it lists private repo names) — never commit it.
New devboxes read it locally at provision time.

### 3. Create terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars   # fill in token, vm_id, hostname, ssh_public_key
```

`terraform.tfvars` is gitignored — never commit it.

## Spinning up a new devbox

```bash
cd vm-iac/devbox

# Create the container
terraform init   # first time only
terraform apply

# Bootstrap it (installs tools, injects secrets, clones repos)
./provision.sh <vmid>   # vmid from your terraform.tfvars, e.g. 301
```

That's it. `provision.sh` prints the SSH command when it finishes.

## Destroying a devbox

```bash
terraform destroy
```

No cleanup needed — secrets live on evilbot, not in the container.

## Rotating secrets

Edit `/root/.secrets/devbox.env` on evilbot. The next container you provision
picks up the new values automatically. Existing containers keep their old values
(they're already bootstrapped).

## File layout

```
vm-iac/devbox/
  main.tf                      # LXC Terraform resource
  variables.tf
  outputs.tf
  terraform.tfvars.example     # Sanitized template — commit this
  terraform.tfvars             # Real values — NEVER commit
  repos.txt.example            # Sanitized template — commit this
  repos.txt                    # Real work repo list — gitignored, NEVER commit
  devbox-secrets.env.example   # Template for evilbot secrets — commit this
  bootstrap.sh                 # Runs inside container at provision time
  provision.sh                 # Orchestrates everything after terraform apply
```
