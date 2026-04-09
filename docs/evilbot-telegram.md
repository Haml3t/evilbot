> This file is part of a public repo. No secrets are stored here — `TELEGRAM_BOT_TOKEN`
> and other credentials live in `/opt/evilbot/.env` on the VM (never committed).
> See `CLAUDE.md` § "Security & Secret Hygiene".

# evilbot-telegram

**VM:** QEMU vmid 200 | Ubuntu 24.04 LTS | 192.168.1.239  
**Access:** `ssh -J root@<proxmox-host> root@192.168.1.239`  
**Role:** Telegram bot + image generation frontend

---

## Services

### evilbot (Telegram bot)

Service: `evilbot.service`  
Source: `/opt/evilbot/evilbot.py`  
Runtime: Python venv at `/opt/evilbot/venv/`, `python-telegram-bot` v22.5  
User: `evilbot`  
Config: `/opt/evilbot/.env` — holds `TELEGRAM_BOT_TOKEN` and `IMAGEGEN_URL` (never commit this file)

### Tailscale

Running (`tailscaled.service`). Used to reach the image generation backend (ComfyUI) at a Tailscale IP.

---

## Bot Commands

| Command | Description |
|---|---|
| `/addsongtitle <title>` | Saves a song title suggestion to the SQLite DB |
| `/showsongtitles` | Lists all saved song titles (paginated at 4000 chars) |
| `/randomsongtitle` | Returns a random title from the DB |
| `/imagegen <prompt>` | Generates a 1024×1024 image via the image gen backend |
| `/hello` | Replies 😈 |
| `/help` | Shows command list |

---

## Data

`/opt/evilbot/evilbot.db` — SQLite database  
Schema: `songtitles(id, song_title, username, timestamp)`

---

## Image Generation

`/imagegen` POSTs to `IMAGEGEN_URL/image` (a ComfyUI HTTP wrapper running on a separate machine, reachable over Tailscale). On success, fetches the output image and sends it back to the Telegram chat.

Request payload:
```json
{ "prompt": "...", "width": 1024, "height": 1024 }
```

Response: `{ "images": ["<filename>"], "prompt_id": "..." }`  
Image retrieved from: `IMAGEGEN_URL/output/<filename>`

Timeout: 300s (image generation can be slow).

---

## Project Layout

```
/opt/evilbot/
  evilbot.py        # Main bot — all handlers in one file
  requirements.txt  # Pinned dependencies
  evilbot.db        # SQLite data (not committed)
  .env              # Secrets — NEVER commit (TELEGRAM_BOT_TOKEN, IMAGEGEN_URL)
  venv/             # Python virtualenv
```

---

## Deployment Notes

- No Docker on this VM (docker not installed; `evilbot.service` runs the process directly)
- No guest agent installed — use disk-mount method via Proxmox host if locked out (see access notes in CLAUDE.md)
- Restart bot after code changes: `systemctl restart evilbot`
- Logs: `journalctl -u evilbot -f`

---

## Dependencies

```
python-telegram-bot==22.5
httpx==0.28.1
python-dotenv==1.2.1
```
(see `/opt/evilbot/requirements.txt` for full pinned list)
