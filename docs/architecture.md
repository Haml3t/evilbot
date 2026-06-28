# System Architecture

This document describes the full architecture of the evilbot homelab: hardware, virtual machines, services, inference pipeline, and CD automation.

---

## Hardware

| Host | Role | GPU | VRAM | Notes |
|---|---|---|---|---|
| evilbot | Proxmox hypervisor | RTX 3070 | 8 GB | Runs all LXC/VM guests; 22 TB ZFS pool `tank` |
| gpu-desktop | Bare-metal desktop | RTX 3090 | 24 GB | User's workstation; runs inference services |

Both GPU hosts run:
- **ComfyUI** — image generation backend
- **Ollama** — LLM backend
- **image-api** — thin FastAPI wrapper that translates inference proxy requests into ComfyUI workflows
- **VRAM reporter** — lightweight HTTP server that exposes live `nvidia-smi` stats on port 9835

---

## VM / Container Topology

```mermaid
graph TD
    subgraph evilbot["evilbot (Proxmox host · 192.168.0.145)"]
        nas["evilbot-nas\nvmid 100 · 192.168.0.67\nQEMU VM\nNAS + torrent client\n/tank via virtiofs"]
        telegram["evilbot-telegram\nvmid 200 · 192.168.0.238\nQEMU VM\nTelegram bot process"]
        claudebot["claudebot\nvmid 300 · 192.168.0.222\nLXC (unprivileged)\nAI dev workspace"]
        jellyfin["jellyfin\nvmid 400 · 192.168.0.196\nLXC (unprivileged)\nJellyfin media server"]
        inferbot["inferbot\nvmid 500 · 192.168.0.223\nLXC (unprivileged)\nInference routing proxy"]
        opsbot["opsbot\nvmid 600 · 192.168.0.224\nLXC (unprivileged)\nGitHub Actions runner"]
    end

    gpudesktop["gpu-desktop\n192.168.0.12\nbare-metal desktop"]

    tank[("ZFS tank\n22 TB")]
    nas --- tank
    jellyfin -. "/media bind-mount" .-> tank
```

---

## Service Architecture

```mermaid
graph LR
    user(["Telegram user"])

    subgraph evilbot_telegram["evilbot-telegram VM"]
        bot["evilbot.py\nTelegram bot\nPython · python-telegram-bot"]
    end

    subgraph inferbot_lxc["inferbot LXC"]
        proxy["inference proxy\nFastAPI · main.py\n:8000"]
    end

    subgraph evilbot_host["evilbot host"]
        imageapi_e["image-api\nFastAPI · :5005"]
        comfyui_e["ComfyUI\n:8288"]
        ollama_e["Ollama\n:11434"]
        vram_e["VRAM reporter\n:9835"]
    end

    subgraph gpu_desktop["gpu-desktop"]
        imageapi_s["image-api\nFastAPI · :5005"]
        comfyui_s["ComfyUI\n:8188"]
        ollama_s["Ollama\n:11434"]
        vram_s["VRAM reporter\n:9835"]
    end

    user -- "/imagine\n/chat\n/imagegen" --> bot
    bot -- "POST /image\nPOST /v1/chat/completions\nGET /jobs/:id\nGET /output/:file" --> proxy

    proxy -- "GET /vram" --> vram_e
    proxy -- "GET /vram" --> vram_s
    proxy -- "POST /image" --> imageapi_e
    proxy -- "POST /image" --> imageapi_s
    proxy -- "POST /v1/chat/completions" --> ollama_e
    proxy -- "POST /v1/chat/completions" --> ollama_s

    imageapi_e -- "POST /prompt\nGET /history\nGET /view" --> comfyui_e
    imageapi_s -- "POST /prompt\nGET /history\nGET /view" --> comfyui_s
```

---

## Inference Routing — VRAM-Aware Scheduler

The inference proxy is the central brain. Every request goes through a two-pass node selection algorithm before a job is dispatched.

```mermaid
flowchart TD
    A["Incoming request\n/image or /v1/chat/completions"] --> B["Look up model in models.yaml\n(vram_mb, eligible nodes, backend_model)"]

    B --> C["Query VRAM reporter on each\neligible node simultaneously"]

    C --> D{"Pass 1: any node\nhas enough free VRAM?"}
    D -- "yes" --> E["Pick best node\n(idle first, then preferred order from models.yaml)"]
    D -- "no" --> F{"Pass 2: any idle node\ncould free enough if unloaded?"}

    F -- "yes" --> G["Unload idle Ollama models\n(keep_alive=0) and/or\nComfyUI checkpoint\n(POST /free)"]
    G --> H["Wait 2s for driver\nto release VRAM"]
    H --> I{"VRAM now sufficient?"}
    I -- "yes" --> E
    I -- "no" --> J

    F -- "no" --> J{"Streaming LLM?"}

    J -- "yes" --> K["Return HTTP 503"]
    J -- "no" --> L["Enqueue job\nReturn 202 + job_id"]

    E --> M["Dispatch to backend\nmark node active"]
    M --> N["Run job\n(image gen or LLM)"]
    N --> O["Mark node idle\nPost-free ComfyUI VRAM"]
    O --> P["Return result or\nupdate job record"]

    L --> Q["_queue_worker polls\nevery 15s for VRAM"]
    Q --> C
```

### VRAM Waker

A background task (`_vram_waker`) runs independently of the per-job retry loop. Every 15 seconds, if any jobs are queued, it scans all nodes that are not actively serving a request and proactively unloads any idle Ollama models and ComfyUI checkpoints. This handles cross-service blocking — for example, a completed LLM job leaving a model loaded in VRAM, blocking a queued image generation job on the same node.

---

## Model Catalog

Defined in `inference/proxy/models.yaml`. The proxy reads this at startup; editing and restarting the proxy is all that's needed to add or remove models.

| Model name | Type | VRAM (MB) | Eligible nodes | Backend |
|---|---|---|---|---|
| `sd-1.5` | imagegen | 4,000 | evilbot, gpu-desktop | ComfyUI checkpoint |
| `sdxl-base` | imagegen | 7,000 | evilbot, gpu-desktop | ComfyUI checkpoint |
| `sdxl-refiner` | imagegen | 7,000 | evilbot, gpu-desktop | ComfyUI checkpoint |
| `flux-schnell` | imagegen | 20,000 | gpu-desktop only | ComfyUI checkpoint (fp8) |
| `flux-dev` | imagegen | 22,000 | gpu-desktop only | ComfyUI checkpoint (fp8) |
| `llama-3-8b` | llm | 5,500 | evilbot, gpu-desktop | Ollama |
| `mistral-7b` | llm | 5,000 | evilbot, gpu-desktop | Ollama |
| `qwen-32b` | llm | 19,000 | gpu-desktop only | Ollama |
| `qwen-32b-think` | llm | 19,000 | gpu-desktop only | Ollama (with `think: true`) |

Node candidate order in models.yaml determines preference: small models list evilbot first so the RTX 3070 handles light workloads and leaves the RTX 3090 free for large-only models.

---

## Telegram Bot — Command Reference

```mermaid
graph LR
    subgraph commands["Bot commands"]
        imagine["/imagine [model] prompt\nAlias: /imagegen\nModels: sd sdxl refiner flux flux-dev"]
        chat["/chat [model] message\nModels: small llama mistral\nlarge qwen think qwen-think"]
        songs["/addsongtitle\n/showsongtitles\n/randomsongtitle"]
    end

    imagine -- "POST /image → proxy" --> proxy
    chat -- "POST /v1/chat/completions → proxy\npolled async for queued jobs" --> proxy
    proxy["Inference proxy\n192.168.0.223:8000"]
```

**Chain-of-thought (think mode):** When the bot receives a response containing a `<think>...</think>` block from Qwen 2.5's reasoning mode, it wraps the reasoning in a Telegram `<tg-spoiler>` tag (tap-to-reveal) and shows the final answer plaintext below.

**Async job polling:** Image generation requests return a `job_id` immediately. The bot sends a "Queued…" status message, then polls `GET /jobs/{job_id}` every 10 seconds. When the job transitions to `running` it edits the status message to "Generating…"; when `done` it fetches the image from `GET /output/{filename}` and replies with a photo.

---

## CD Pipeline

```mermaid
sequenceDiagram
    participant dev as Developer (claudebot)
    participant gh as GitHub
    participant opsbot as opsbot LXC<br/>(GH Actions runner)
    participant inferbot as inferbot LXC
    participant telegram as evilbot-telegram VM
    participant gpu as gpu-desktop

    dev->>gh: git push (main branch)
    gh->>opsbot: trigger deploy.yml workflow
    opsbot->>opsbot: git diff HEAD~1 HEAD<br/>detect changed paths

    alt inference/proxy/** changed
        opsbot->>inferbot: scp main.py models.yaml
        opsbot->>inferbot: systemctl restart inference-proxy
    end

    alt telegram-bot/** changed
        opsbot->>telegram: scp evilbot.py (via ProxyJump evilbot)
        opsbot->>telegram: systemctl restart evilbot
    end

    alt inference/image-api/** changed
        opsbot->>gpu: scp main.py (via ProxyJump evilbot)
        opsbot->>gpu: docker compose restart image-api
    end
```

**Path-based gating:** The `changes` job diffs `HEAD~1..HEAD` and outputs boolean flags (`proxy`, `bot`, `image_api`). Each deploy job is conditional on its flag — a commit touching only `telegram-bot/` skips the proxy and image-api deploys entirely.

**opsbot SSH topology:** opsbot holds a single SSH keypair. Its `~/.ssh/config` defines:
- `inferbot` — direct (same LAN)
- `evilbot-telegram` — via `ProxyJump evilbot` (evilbot is the jump host)
- `gpu-desktop` — via `ProxyJump evilbot`

opsbot has no SSH access beyond these deploy targets. It holds no Proxmox API tokens and no Telegram bot credentials.

---

## Infrastructure as Code

All containers and VMs are provisioned via Terraform using the `bpg/proxmox` provider (~0.73). Each service has its own directory under `vm-iac/`.

```mermaid
graph TD
    tf["Terraform\nbpg/proxmox provider"]

    tf --> pve["Proxmox API\n192.168.0.145:8006"]

    pve --> claudebot_lxc["claudebot LXC\nvmid 300"]
    pve --> inferbot_lxc["inferbot LXC\nvmid 500"]
    pve --> opsbot_lxc["opsbot LXC\nvmid 600"]
    pve --> jellyfin_lxc["jellyfin LXC\nvmid 400"]
    pve --> telegram_vm["evilbot-telegram VM\nvmid 200"]

    note["Each vm-iac/ directory contains:\nmain.tf — resource definition\nvariables.tf — input vars\nterraform.tfvars.example — safe-to-commit template\nterraform.tfvars — gitignored, holds real API token"]
```

---

## Data Flow — Image Generation (end to end)

```mermaid
sequenceDiagram
    participant user as Telegram user
    participant bot as evilbot.py<br/>(evilbot-telegram)
    participant proxy as inference proxy<br/>(inferbot :8000)
    participant vram as VRAM reporter<br/>(GPU node :9835)
    participant imageapi as image-api<br/>(GPU node :5005)
    participant comfyui as ComfyUI<br/>(GPU node :8188/:8288)

    user->>bot: /imagine flux a glowing forest
    bot->>proxy: POST /image {model: flux-schnell, prompt: ...}
    proxy->>vram: GET /vram (all eligible nodes)
    vram-->>proxy: {memory_free_mb: 21000}

    alt VRAM sufficient
        proxy-->>bot: {images: ["api_123.png"]}
        bot-->>user: 🖼 photo reply
    else VRAM insufficient
        proxy-->>bot: {job_id: "abc-123", status: queued}
        bot-->>user: ⏳ Queued (position 1)

        loop every 10s
            bot->>proxy: GET /jobs/abc-123
            proxy-->>bot: {status: queued}
        end

        Note over proxy: _vram_waker unloads idle Ollama<br/>_queue_worker retries pick_node
        proxy->>imageapi: POST /image {ckpt_name: flux1-schnell-fp8.safetensors, ...}
        imageapi->>comfyui: POST /prompt (ComfyUI workflow JSON)
        comfyui-->>imageapi: {prompt_id: "xyz"}

        loop poll history
            imageapi->>comfyui: GET /history/xyz
        end

        comfyui-->>imageapi: {outputs: {images: [{filename: "api_123.png"}]}}
        imageapi->>comfyui: GET /view?filename=api_123.png
        comfyui-->>imageapi: image bytes
        imageapi-->>proxy: {images: ["api_123.png"]}
        proxy->>comfyui: POST /free (unload checkpoint)

        bot->>proxy: GET /jobs/abc-123
        proxy-->>bot: {status: done, result: {images: ["api_123.png"]}}
        bot->>proxy: GET /output/api_123.png
        proxy->>imageapi: GET /output/api_123.png
        imageapi-->>proxy: image bytes
        proxy-->>bot: image bytes
        bot-->>user: 🖼 photo reply
    end
```

---

## Security Posture

| Boundary | Policy |
|---|---|
| inferbot → GPU nodes | HTTP only to inference ports (ComfyUI, Ollama, image-api, VRAM reporter). No SSH keys. No Proxmox API access. |
| opsbot → deploy targets | SSH keypair scoped to inferbot, evilbot-telegram, gpu-desktop, and evilbot as jump host only. No Proxmox API tokens. |
| claudebot | AI workspace only — no production daemons, no CI runners, no deploy automation. |
| Public repo | LAN IPs and SSH public keys are safe to commit. All secrets live in gitignored `*.tfvars` / `.env` files; `*.example` templates are committed instead. |
| evilbot Proxmox API tokens | Minimum scope per operation (read-only vs. container management). Never combine `Sys.PowerMgmt + Datastore.Allocate + VM.Config.Disk` in one token. |
