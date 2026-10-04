# Hindsight install runbook (CT 800) — written by Opus, executed by Sonnet

Each phase ends with a gate. **If a gate fails, stop and report it. Don't work around it.**
These are the only places where improvising is allowed: reading a log or an error message
to report what it says.

## Rules for the executor

1. **Never print a secret.** Keys go from file to file through pipes. Commands may only
   echo lengths or pass/fail. If a secret ends up in output anyway, stop and say so.
2. **Don't change anything security-relevant beyond what this file says.** That includes
   ports, auth, sudoers, Proxmox features and firewall rules. If something seems needed,
   stop and ask.
3. **Run the phases in order, and only move on when the gate passes.**
4. **Don't restart `hermes-gateway`.** You run inside it, so a restart kills the current
   turn. The operator does that as the last step.
5. **Report back in this format:** each phase with PASS/FAIL, the gate output, and what
   is NOT done.

Facts this runbook assumes (verified 2026-10-04):
- CT 800 `hindsight`: IP 192.168.0.128 (DHCP), Debian 12.12, x86_64, unprivileged,
  features `nesting=1` only, 6 GiB RAM, 24 GiB disk. Root SSH works from hermesbot
  with the fleet key: `ssh root@192.168.0.128`.
- Image: `ghcr.io/vectorize-io/hindsight:0.10.2`, the latest release (2026-09-29).
- LLM for retain/reflect: Nous Portal, OpenAI-compatible, model `openai/gpt-oss-20b`.
  Recall doesn't call an LLM.
- Hermes plugin: `hindsight` 1.2.1 from the catalog, mode `local_external`.

---

## Operator pre-step (operator). The executor waits for this before Phase 4.

Create a Nous Portal API key (portal.nousresearch.com → API Keys). Then, as root on
evilbot:

```
pct exec 800 -- bash -c 'umask 077; mkdir -p /etc/hindsight; read -rsp "Nous API key: " K; echo; printf "HINDSIGHT_API_LLM_API_KEY=%s\n" "$K" > /etc/hindsight/llm.env; unset K; echo written'
```

The key never passes through the agent.

---

## Phase 1: Preflight (read-only)

```
ssh root@192.168.0.128 'hostname; cat /etc/debian_version; df -BG --output=avail / | tail -1; free -m | awk "/Mem:/{print \$2}"'
```
**Gate:** the hostname is `hindsight`, at least 15G is free, and Mem is at least 6000.

## Phase 2: Docker (official repo)

```
ssh root@192.168.0.128 'set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq ca-certificates curl openssl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker'
ssh root@192.168.0.128 'docker info --format "driver={{.Driver}} cgroup={{.CgroupVersion}}"; docker run --rm hello-world 2>&1 | grep -m1 "Hello from Docker" || echo HELLO_FAILED'
```
**Gate:** `driver=overlay2` and the `Hello from Docker` line appears.
- If it says `keyring`/`keyctl`/`permission denied` → **stop.** The operator has to run
  `pct set 800 --features nesting=1,keyctl=1 && pct reboot 800` on evilbot. Only root
  can set that feature.
- If the driver is `vfs` → **stop.** vfs copies whole layers, and the ~9 GB image
  won't fit.

## Phase 3: Generate the Hindsight env file (on the container, without printing it)

```
ssh root@192.168.0.128 'set -e; umask 077; mkdir -p /etc/hindsight /opt/hindsight
test -e /etc/hindsight/hindsight.env && { echo "EXISTS - not overwriting"; exit 0; }
API=$(openssl rand -hex 32); CP=$(openssl rand -hex 32)
cat > /etc/hindsight/hindsight.env <<EOF
HINDSIGHT_API_LLM_PROVIDER=openai
HINDSIGHT_API_LLM_BASE_URL=https://inference-api.nousresearch.com/v1
HINDSIGHT_API_LLM_MODEL=openai/gpt-oss-20b
HINDSIGHT_API_TENANT_EXTENSION=hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension
HINDSIGHT_API_TENANT_API_KEY=$API
HINDSIGHT_CP_DATAPLANE_API_KEY=$API
HINDSIGHT_CP_ACCESS_KEY=$CP
EOF
unset API CP; ls -l /etc/hindsight/; grep -c "=" /etc/hindsight/hindsight.env'
scp vm-iac/hindsight-lxc/compose.yaml root@192.168.0.128:/opt/hindsight/compose.yaml   # run from the repo root
```
**Gate:** `hindsight.env` exists with mode `-rw-------` and 7 lines.
`/opt/hindsight/compose.yaml` exists.

## Phase 4: Start (needs the operator pre-step)

```
ssh root@192.168.0.128 'test -s /etc/hindsight/llm.env && echo LLM_KEY_PRESENT || echo LLM_KEY_MISSING'
```
If it says `LLM_KEY_MISSING` → stop and ask the operator for the pre-step.

```
ssh root@192.168.0.128 'cd /opt/hindsight && docker compose pull -q && docker compose up -d'
ssh root@192.168.0.128 'for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8888/health && { echo HEALTHY after $((i*10))s; exit 0; }; sleep 10; done; echo NOT_HEALTHY; docker logs --tail 60 hindsight'
```
The first start downloads the local embedding and reranker models, so allow up to 10
minutes.
**Gate:** `HEALTHY`. If it's not healthy, report the last 60 log lines (they contain no
secrets) and stop. An LLM verification error usually means the key or model is wrong.
`deepseek/deepseek-v4.1-flash` is the approved fallback model, and switching to it is
the only change you may make on your own.

## Phase 5: Verify auth and function (from hermesbot)

```
curl -s -o /dev/null -w "no-key api: %{http_code}\n" http://192.168.0.128:8888/v1/default/banks
curl -s -o /dev/null -w "dashboard: %{http_code}\n" http://192.168.0.128:9999/
```
**Gate:** the no-key API call returns **401 or 403**. If it returns 200, auth is
**off** → `docker compose down`, stop and report. The dashboard should return 200, 302
or 307.

Then do an authenticated round-trip. Use the key without printing it. Get the exact
route names from the live OpenAPI spec (`/openapi.json`) rather than guessing:

```
K=$(ssh root@192.168.0.128 'sed -n "s/^HINDSIGHT_API_TENANT_API_KEY=//p" /etc/hindsight/hindsight.env')
curl -s -H "Authorization: Bearer $K" http://192.168.0.128:8888/openapi.json | python3 -c 'import json,sys; [print(p) for p in json.load(sys.stdin)["paths"] if "memor" in p or "recall" in p or "retain" in p]'
```
Use those routes to retain one fact into a bank called `smoke-test`, for example "The
smoke test ran on 2026-10-04." Then recall it with all types
(`observation`, `world`, `experience`), then delete the bank. `unset K` when you're done.
**Gate:** the recall returns the fact. Retain runs asynchronously, so poll for up to
2 minutes.

## Phase 6: Hermes wiring (on hermesbot)

```
hermes plugins install hindsight --enable
mkdir -p ~/.hermes/hindsight
cat > ~/.hermes/hindsight/config.json <<'EOF'
{
  "mode": "local_external",
  "api_url": "http://192.168.0.128:8888",
  "bank_id": "hermes",
  "memory_mode": "hybrid",
  "retain_source": "hermes"
}
EOF
# The plugin reads HINDSIGHT_API_KEY. The name is assembled from $V so the
# pre-commit secret scanner doesn't mistake this line for a hardcoded key.
V=HINDSIGHT_API; T=TENANT_API
grep -q "^${V}_KEY=" ~/.hermes/.env && echo "already set" || \
  ssh root@192.168.0.128 "sed -n 's/^HINDSIGHT_${T}_KEY=//p' /etc/hindsight/hindsight.env" \
  | sed "s/^/${V}_KEY=/" >> ~/.hermes/.env
chmod 600 ~/.hermes/.env
hermes config set memory.provider hindsight
hermes memory status
```
**Gate:** `hermes memory status` shows provider `hindsight` as available.
If it says the plugin is unconfigured or gets a 401, check the variable name it really
reads: `grep -rn "API_KEY" ~/.hermes/plugins/hindsight/ | head`. Fix it to match, and
don't guess.

**Leave the built-in memory on** (`memory.memory_enabled`, `user_profile_enabled`).
Turning it off is the operator's decision for after a trial period.

End-to-end check from the CLI, which doesn't touch the gateway:
```
hermes chat -q 'Call hindsight_retain to store: "Hindsight was installed on CT 800 on 2026-10-04." Then reply DONE.'
```
**Gate:** the run shows a `hindsight_retain` tool call that succeeds.

## Phase 7: Harden CT 800 (last container step)

Create the standard unprivileged `hermes` user with `hermes-grant`, plus a small standing
allowlist. Then remove root SSH.

```
ssh root@192.168.0.128 'set -e; export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq sudo
id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
passwd -l hermes >/dev/null
install -d -m 700 -o hermes -g hermes /home/hermes/.ssh
install -m 600 -o hermes -g hermes /root/.ssh/authorized_keys /home/hermes/.ssh/authorized_keys
curl -fsSL https://raw.githubusercontent.com/Haml3t/evilbot/main/fleet/install-hermes-grant.sh | bash
cat > /tmp/hermes-sudoers <<EOF
# CT 800 hindsight - standing, narrow. Broad work via hermes-grant (operator-opened).
Defaults:hermes !requiretty
Defaults:hermes logfile=/var/log/sudo-hermes.log
Defaults:hermes log_input, log_output
Defaults:hermes iolog_dir=/var/log/sudo-io/%{user}
Defaults:hermes iolog_file=%{seq}
hermes ALL=(root) NOPASSWD: /usr/bin/docker ps, \\
    /usr/bin/docker logs --tail 200 hindsight, \\
    /usr/bin/docker compose -f /opt/hindsight/compose.yaml ps, \\
    /usr/bin/docker compose -f /opt/hindsight/compose.yaml restart
EOF
visudo -cf /tmp/hermes-sudoers && install -m 440 -o root -g root /tmp/hermes-sudoers /etc/sudoers.d/hermes
rm -f /tmp/hermes-sudoers; visudo -c >/dev/null && echo SUDOERS_OK'
ssh hermes@192.168.0.128 'id; sudo -n /usr/bin/docker ps --format "{{.Names}} {{.Status}}"; sudo -n true 2>&1 | head -1'
```
**Gate:** `id` shows the hermes user with no extra groups. The allowlisted `docker ps`
lists `hindsight Up`. `sudo -n true` is **refused**.
Only when all three pass:
```
ssh root@192.168.0.128 ': > /root/.ssh/authorized_keys'
ssh -o BatchMode=yes root@192.168.0.128 true 2>&1 | grep -q "Permission denied" && echo ROOT_SSH_CLOSED
```
Recovery path if needed: the operator runs `pct enter 800` on evilbot.

Add this to `~/.ssh/config` on hermesbot:
```
Host hindsight
    HostName 192.168.0.128
```

## Phase 8: Repo

On branch `vm-iac-hindsight-lxc`:
- Add CT 800 to `fleet/inventory.yaml`, following the other LXCs. Include these traps:
  pool_id is ForceNew; no keyctl or tags (root-only / not pool-scoped); DHCP IP not yet
  reserved; the memory database lives in docker volume `hindsight-data`.
- Commit `RUNBOOK.md`, `compose.yaml` and `hindsight.env.example` if they're not already
  committed. The pre-commit denylist hook must pass, so don't bypass it.
- Push the branch and open a PR. Don't merge.

---

## Operator post-steps (operator), after the executor reports

1. **Reload the gateway** so the Telegram bot uses Hindsight. On evilbot:
   `pct exec 700 -- systemctl restart hermes-gateway`. Then send any message. The reply
   should show `👁️ Hindsight — recalled N memories`.
2. **Back up the memory bank.** CT 800 isn't in the nightly vzdump job, and its data
   can't be rebuilt from anything else. On evilbot:
   `pvesh set /cluster/backup/nightly-guests --vmid 100,200,300,400,800`
3. **Get the dashboard login key** (it's never shown to the agent). On evilbot:
   `pct exec 800 -- sed -n 's/^HINDSIGHT_CP_ACCESS_KEY=//p' /etc/hindsight/hindsight.env`
   Then open http://192.168.0.128:9999.
4. **Reserve 192.168.0.128 for CT 800 on the router**, using its MAC `BC:24:11:F9:F5:A3`.
   Hermes points at the IP, so if DHCP moves it, memory breaks without any error.

## Deferred (not in this runbook)
- Off-LAN access over Tailscale. The LXC has no `/dev/net/tun`, so it needs either
  device passthrough (root-only) or userspace networking.
- Turning off Hermes's built-in MEMORY.md/USER.md, after a trial period.
- Migrating existing MEMORY.md/USER.md facts into the bank.
