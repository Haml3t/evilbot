# Plan: IaC for Claude Sandbox LXC Containers

**Goal:** Terraform + Proxmox provider to clone and provision new claudebot-style LXC containers on evilbot, reproducibly and without manual SSH-as-root.

---

## Status

- [ ] Phase 1: Foundations
- [ ] Phase 2: Terraform config
- [ ] Phase 3: First container provisioned
- [ ] Phase 4: Hardening & reuse

---

## Phase 1: Foundations

### 1.1 Proxmox API tokens
Create two tokens via web UI at https://192.168.1.145:8006 (Datacenter → Permissions → API Tokens):

| Token ID | Permissions | Purpose |
|---|---|---|
| `terraform-ro@pam!read` | `VM.Audit`, `Datastore.Audit` on `/` | Inspection, planning, import |
| `terraform-lxc@pam!lxc` | `VM.PowerMgmt`, `VM.Config.HWType`, `VM.Config.Options`, `VM.Config.Network`, `VM.Allocate`, `Datastore.AllocateSpace` scoped to pool `claudebots` (TBD) | Create/start/stop/delete LXC containers |

Token secrets are single-display — save them to `/root/.secrets/proxmox-tokens.env` (not committed anywhere).

### 1.2 Create a Proxmox pool
In the web UI: Datacenter → Pools → Create pool `claudebots`.
This lets us scope token permissions to just that pool rather than the whole datacenter.

### 1.3 Identify base template
Determine which CT template claudebot (vmid 300) was built from, or create a snapshot/template clone to use as the Terraform base image.

```bash
ssh root@192.168.1.145 "pct config 300"
```

Look for `ostemplate` or confirm it's a clone. If no template exists, create one:
```bash
ssh root@192.168.1.145 "pct snapshot 300 baseline-snapshot"
```
(Full template clone requires stopping the container — plan around that.)

### 1.4 Install Terraform
```bash
apt-get update && apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
apt-get update && apt-get install -y terraform
```

---

## Phase 2: Terraform Config

### 2.1 Provider
Use `bpg/proxmox` (current community standard, actively maintained).

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://192.168.1.145:8006/"
  api_token = var.proxmox_api_token   # format: "user@realm!tokenid=secret"
  insecure  = true                    # self-signed cert on evilbot
}
```

### 2.2 State backend
For now: local state file at `/root/infra/terraform.tfstate`.
Future: migrate to HTTP backend on evilbot or S3-compatible store on NAS.

### 2.3 Directory layout
```
/root/infra/
  main.tf
  variables.tf
  outputs.tf
  lxc-claudebot/
    main.tf        # LXC resource definition
    cloud-init.tf  # Post-provision setup (if used)
  terraform.tfvars # Not committed — holds token + secrets
  .gitignore       # Excludes tfstate, tfvars, .terraform/
```

### 2.4 LXC resource
Key parameters to mirror from vmid 300:
- `node_name = "evilbot"`
- `pool_id = "claudebots"`
- `unprivileged = true`
- CPU, memory, disk size
- Network bridge (`vmbr0`), static or DHCP IP
- SSH public key injected at provision time
- Start on boot

### 2.5 Variables
- `proxmox_api_token` (sensitive)
- `container_id` (or auto-assign)
- `hostname`
- `ip_address` (CIDR, e.g. `192.168.1.X/24`)
- `ssh_public_key`

---

## Phase 3: First Container Provisioned

1. `terraform init`
2. `terraform plan` — verify against read-only token first
3. `terraform apply` — switch to lxc-scoped token
4. SSH into new container and confirm baseline config matches claudebot

---

## Phase 4: Hardening & Reuse

- [ ] Extract LXC config into a reusable Terraform module
- [ ] Add `locals` for standard claudebot sizing (CPU/RAM/disk defaults)
- [ ] Document how to spin up a new sandbox: one `tfvars` file + `terraform apply`
- [ ] Consider: migrate state to evilbot or NAS for durability
- [ ] Consider: add Ansible or cloud-init step for post-provision package install (Node, Python, Claude Code CLI)

---

## Open Questions

- Does claudebot (vmid 300) have a clean snapshot/template we can clone from, or do we build from a stock Debian CT template?
- Should new containers get static IPs (requires updating DHCP/router config) or DHCP with hostnames?
- Who manages the `terraform.tfvars` secrets — store in `/root/.secrets/` or use a secrets manager?
- Should the Terraform state eventually live on evilbot or the NAS for resilience?
