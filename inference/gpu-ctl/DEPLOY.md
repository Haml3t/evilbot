# gpu-ctl — deploy on gpu-desktop (gpu-desktop, 192.168.0.12)

Privileged GPU lifecycle agent. The inference proxy (inferbot, runs as
`nobody`) can only reach HTTP endpoints, so it can unload Ollama/ComfyUI but can
NEVER start/stop vLLM (a systemd unit on this host) or tear the card down for
lockout. gpu-ctl owns those privileged bits.

Run everything below as root (or with sudo) ON gpu-desktop.

## 1. Install files

```bash
sudo mkdir -p /opt/gpu-ctl
# copy gpu-ctl.py and config.example.json from the repo into /opt/gpu-ctl/
sudo install -m 755 inference/gpu-ctl/gpu-ctl.py /opt/gpu-ctl/gpu-ctl.py
```

## 2. Config

```bash
sudo cp config.example.json /etc/gpu-ctl/config.json
sudo chmod 600 /etc/gpu-ctl/config.json
sudo $EDITOR /etc/gpu-ctl/config.json
```

Set:
- `token` -> `$(openssl rand -hex 32)` (the SAME value goes on inferbot as
  `GPU_CTL_TOKEN`).
- Confirm `vllm.unit` == `vllm-donnertune` and `api_key_file` ==
  `/etc/vllm-donnertune.env` (both correct per the donnertune deploy).
- Confirm the `services` stop commands match how ComfyUI/Ollama actually run
  here (Nomad jobs on this host — `nomad job stop -purge <name>`). Adjust names
  if the live jobs differ.

## 3. Shared secret (root-only env file, never in a repo)

```bash
sudo install -m 600 /dev/null /etc/gpu-ctl.env
sudo sh -c 'printf "GPU_CTL_TOKEN=%s\n" "$(openssl rand -hex 32)" > /etc/gpu-ctl.env'
```

Put the SAME token value in `/etc/gpu-ctl/config.json` `token` field, and on
inferbot's inference-proxy.service as `Environment=GPU_CTL_TOKEN=...`.

## 4. Install + start the service

```bash
sudo cp inference/gpu-ctl/gpu-ctl.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-ctl
systemctl status gpu-ctl --no-pager
```

## 5. Verify

```bash
# state (no auth on /health; /state needs the bearer token)
curl -s localhost:9840/health
curl -s localhost:9840/state -H "Authorization: Bearer $(cut -d= -f2 /etc/gpu-ctl.env)"

# stop donnertune (should return {"loaded": false})
curl -s -X POST localhost:9840/vllm/stop -H "Authorization: Bearer $(cut -d= -f2 /etc/gpu-ctl.env)"

# start donnertune + block until ready (~36s)
curl -s -X POST localhost:9840/vllm/start -H "Authorization: Bearer $(cut -d= -f2 /etc/gpu-ctl.env)"

# lockout (stop everything) / unlock
curl -s -X POST localhost:9840/lockout -H "Authorization: Bearer $(cut -d= -f2 /etc/gpu-ctl.env)"
curl -s -X POST localhost:9840/unlock  -H "Authorization: Bearer $(cut -d= -f2 /etc/gpu-ctl.env)"
```

## 6. On inferbot

Add `GPU_CTL_TOKEN` to `/etc/systemd/system/inference-proxy.service` (under
`[Service]`, `Environment=GPU_CTL_TOKEN=<same value>`), `daemon-reload`,
restart. Then the proxy's `/health`, `/state`, `/lockout`, `/unlock` and the
vLLM load-on-demand path all go through this agent, and the vLLM API key never
leaves gpu-desktop.

## Firewall

gpu-ctl binds 0.0.0.0:9840. It MUST be reachable by inferbot (192.168.0.223)
but NOT the internet — it can stop GPU services. On a flat LAN like this, the
shared-secret bearer token is the auth; do not expose 9840 publicly.

## Lockout semantics

- `POST /lockout` stops vLLM + every `services` entry, then writes
  `/run/gpu-ctl.lock`. The proxy also sets its own in-memory lock and stops
  auto-loading. Inbound queries queue (202) until unlock.
- The lock file is under `/run`, so a reboot clears it — lockout is an
  operator convenience (hand the card back for gaming/renders), not a security
  boundary, and handing the card back on reboot is the correct default.
- ComfyUI's ~2.4 GB CUDA context is NOT released by its `/free` — only stopping
  the service does. `lockout` stops the service, so it truly frees the card.
