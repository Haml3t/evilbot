import asyncio
from dotenv import load_dotenv
import html
import logging
import httpx
import io
import os
import random
import re
import sqlite3
from datetime import datetime
from pathlib import Path

from telegram import Update, BotCommand
from telegram.ext import Application, CommandHandler, ContextTypes

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO
)
logger = logging.getLogger(__name__)

load_dotenv()

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
if not TOKEN:
    raise ValueError("No TELEGRAM_BOT_TOKEN found in environment.")

# Inference proxy base URL. Both /image and /v1/chat/completions live here.
IMAGEGEN_URL = os.environ.get("IMAGEGEN_URL", "")
LLM_URL = os.environ.get("LLM_URL", IMAGEGEN_URL)  # defaults to same host as image proxy

JOB_POLL_INTERVAL = int(os.getenv("JOB_POLL_INTERVAL", "10"))   # seconds between job status polls
JOB_POLL_MAX_WAIT = int(os.getenv("JOB_POLL_MAX_WAIT", "600"))  # seconds before giving up

# ---------------------------------------------------------------------------
# SQLite — song titles
# ---------------------------------------------------------------------------

conn = sqlite3.connect("evilbot.db", check_same_thread=False)
cursor = conn.cursor()
cursor.execute("""
    CREATE TABLE IF NOT EXISTS songtitles (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        song_title TEXT NOT NULL,
        username   TEXT NOT NULL,
        timestamp  DATETIME NOT NULL
    )
""")
conn.commit()


def chunk_lines(lines: list[str], max_chars: int = 4000) -> list[str]:
    chunks, current, count = [], [], 0
    for line in lines:
        if count + len(line) + 1 > max_chars:
            chunks.append("\n".join(current))
            current, count = [line], len(line) + 1
        else:
            current.append(line)
            count += len(line) + 1
    if current:
        chunks.append("\n".join(current))
    return chunks


async def addsongtitle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not context.args:
        await update.message.reply_text("Usage: /addsongtitle Song Title")
        return
    song_title = " ".join(context.args)
    username = update.effective_user.username or update.effective_user.first_name
    cursor.execute(
        "INSERT INTO songtitles (song_title, username, timestamp) VALUES (?, ?, ?)",
        (song_title, username, datetime.now()),
    )
    conn.commit()
    await update.message.reply_text(f"Added song title: {song_title}")


async def showsongtitles(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cursor.execute("SELECT song_title, username, timestamp FROM songtitles")
    rows = cursor.fetchall()
    if not rows:
        return await update.message.reply_text("No song titles have been added yet.")
    lines = [f"{song} (by {user} on {time})" for song, user, time in rows]
    for chunk in chunk_lines(lines):
        await update.message.reply_text(chunk)


async def randomsongtitle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cursor.execute("SELECT song_title, username, timestamp FROM songtitles")
    rows = cursor.fetchall()
    if not rows:
        return await update.message.reply_text("No song titles available.")
    song, *_ = random.choice(rows)
    await update.message.reply_text(f"Random Song Title: {song}")


def _format_with_think(text: str) -> tuple[str, str | None]:
    """Wrap <think> block in a Telegram spoiler; return (text, parse_mode)."""
    m = re.search(r'<think>(.*?)</think>', text, re.DOTALL)
    if not m:
        return text[:4096], None
    think_raw = m.group(1).strip()
    answer = text[m.end():].strip()
    MAX_THINK = 1200
    think_display = html.escape(think_raw[:MAX_THINK])
    if len(think_raw) > MAX_THINK:
        think_display += f" …({len(think_raw) - MAX_THINK} more chars)"
    spoiler = f"<tg-spoiler>💭 {think_display}</tg-spoiler>"
    answer_esc = html.escape(answer)
    combined = f"{spoiler}\n\n{answer_esc}"
    if len(combined) > 4096:
        trim = 4096 - len(spoiler) - 6
        combined = f"{spoiler}\n\n{html.escape(answer[:trim])}…"
    return combined, "HTML"


# ---------------------------------------------------------------------------
# Image generation
# ---------------------------------------------------------------------------

IMAGEGEN_ALIASES: dict[str, str] = {
    "sd":      "sd-1.5",
    "sdxl":    "sdxl-base",
    "refiner": "sdxl-refiner",
    "flux":    "flux-schnell",
}
DEFAULT_IMAGEGEN_MODEL = "sd-1.5"

LLM_ALIASES: dict[str, str] = {
    "small":       "llama-3-8b",
    "llama":       "llama-3-8b",
    "mistral":     "mistral-7b",
    "large":       "qwen-32b",
    "qwen":        "qwen-32b",
    "think":       "qwen-32b-think",
    "qwen-think":  "qwen-32b-think",
}
DEFAULT_LLM_MODEL = "llama-3-8b"


def _parse_model_and_prompt(
    args: list[str], aliases: dict[str, str], default: str
) -> tuple[str, str]:
    """
    Extract an optional leading model keyword from command args.
      /imagegen flux a purple cat  → ("flux-schnell", "a purple cat")
      /imagegen a purple cat       → ("sd-1.5", "a purple cat")
    """
    if args and args[0].lower() in aliases:
        return aliases[args[0].lower()], " ".join(args[1:]).strip()
    return default, " ".join(args).strip()


async def _fetch_and_send_image(
    client: httpx.AsyncClient,
    update: Update,
    filename: str,
    proxy_base: str,
    caption: str,
) -> None:
    img = await client.get(f"{proxy_base}/output/{filename}", timeout=30.0)
    img.raise_for_status()
    bio = io.BytesIO(img.content)
    bio.name = filename
    bio.seek(0)
    await update.message.reply_photo(
        photo=bio,
        reply_to_message_id=update.message.message_id,
        caption=caption,
    )


async def _poll_image_job(
    update: Update,
    job_id: str,
    model: str,
    prompt: str,
    status_msg,  # telegram Message object to edit/delete
) -> None:
    """Background task: poll proxy until image job completes, then send the image."""
    max_polls = JOB_POLL_MAX_WAIT // JOB_POLL_INTERVAL
    seen_running = False

    async with httpx.AsyncClient(timeout=30.0) as client:
        for _ in range(max_polls):
            await asyncio.sleep(JOB_POLL_INTERVAL)

            try:
                r = await client.get(f"{IMAGEGEN_URL}/jobs/{job_id}")
            except httpx.HTTPError as e:
                logger.warning("poll error for job %s: %s", job_id, e)
                continue

            if not r.is_success:
                continue

            data = r.json()
            status = data.get("status")

            if status == "running" and not seen_running:
                seen_running = True
                try:
                    await status_msg.edit_text("⚙️ Generating now…")
                except Exception:
                    pass

            elif status == "done":
                result = data.get("result", {})
                images = result.get("images") or []
                if not images:
                    await status_msg.edit_text("❌ Job completed but no images were returned.")
                    return
                filename = os.path.basename(str(images[0]))
                try:
                    await _fetch_and_send_image(
                        client, update, filename, IMAGEGEN_URL,
                        f"{prompt[:900]} [{model}]",
                    )
                    try:
                        await status_msg.delete()
                    except Exception:
                        pass
                except httpx.HTTPError as e:
                    await status_msg.edit_text(f"❌ Image generated but couldn't fetch it: {e}")
                return

            elif status == "failed":
                error = data.get("error", "unknown error")
                await status_msg.edit_text(f"❌ Generation failed: {error[:200]}")
                return

        await status_msg.edit_text(
            f"⏰ Timed out waiting for GPU after {JOB_POLL_MAX_WAIT // 60} minutes."
        )


async def imagegen(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    model, prompt = _parse_model_and_prompt(
        context.args or [], IMAGEGEN_ALIASES, DEFAULT_IMAGEGEN_MODEL
    )
    if not prompt:
        aliases = ", ".join(IMAGEGEN_ALIASES.keys())
        await update.message.reply_text(
            f"Usage: /imagegen [model] <prompt>\n"
            f"Models: {aliases} (default: sd)\n"
            f"Example: /imagegen flux a neon city at night"
        )
        return

    if not IMAGEGEN_URL:
        await update.message.reply_text("Image generation not configured (IMAGEGEN_URL not set).")
        return

    await update.message.reply_text(f"Generating… [{model}]")

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
            r = await client.post(
                f"{IMAGEGEN_URL}/image",
                json={"prompt": prompt, "width": 1024, "height": 1024, "model": model},
            )

            if r.status_code == 202:
                data = r.json()
                job_id = data["job_id"]
                position = data.get("position", 1)
                status_msg = await update.message.reply_text(
                    f"⏳ Queued (position {position}) — I'll send the image when the GPU has room."
                )
                asyncio.create_task(_poll_image_job(update, job_id, model, prompt, status_msg))
                return

            r.raise_for_status()
            data = r.json()

            images = data.get("images") or []
            if not images:
                await update.message.reply_text(f"No images returned (prompt_id={data.get('prompt_id')})")
                return

            filename = os.path.basename(str(images[0]))
            await _fetch_and_send_image(client, update, filename, IMAGEGEN_URL, f"{prompt[:900]} [{model}]")

    except httpx.HTTPStatusError as e:
        await update.message.reply_text(
            f"imagegen failed ({e.response.status_code}): {e.response.text[:200]}"
        )
    except httpx.HTTPError as e:
        await update.message.reply_text(f"imagegen failed: {e}")


# ---------------------------------------------------------------------------
# LLM chat
# ---------------------------------------------------------------------------

async def _poll_llm_job(
    update: Update,
    job_id: str,
    model: str,
    status_msg,
) -> None:
    """Background task: poll proxy until LLM job completes, then send the reply."""
    max_polls = JOB_POLL_MAX_WAIT // JOB_POLL_INTERVAL
    seen_running = False

    async with httpx.AsyncClient(timeout=30.0) as client:
        for _ in range(max_polls):
            await asyncio.sleep(JOB_POLL_INTERVAL)

            try:
                r = await client.get(f"{LLM_URL}/jobs/{job_id}")
            except httpx.HTTPError as e:
                logger.warning("poll error for llm job %s: %s", job_id, e)
                continue

            if not r.is_success:
                continue

            data = r.json()
            status = data.get("status")

            if status == "running" and not seen_running:
                seen_running = True
                try:
                    await status_msg.edit_text(f"⚙️ Thinking… [{model}]")
                except Exception:
                    pass

            elif status == "done":
                result = data.get("result", {})
                try:
                    reply_text = result["choices"][0]["message"]["content"]
                except (KeyError, IndexError):
                    reply_text = str(result)
                formatted, parse_mode = _format_with_think(reply_text)
                await update.message.reply_text(formatted, parse_mode=parse_mode)
                try:
                    await status_msg.delete()
                except Exception:
                    pass
                return

            elif status == "failed":
                error = data.get("error", "unknown error")
                await status_msg.edit_text(f"❌ LLM failed: {error[:200]}")
                return

        await status_msg.edit_text(
            f"⏰ Timed out waiting for GPU after {JOB_POLL_MAX_WAIT // 60} minutes."
        )


async def chat(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not LLM_URL:
        await update.message.reply_text("LLM not configured (LLM_URL not set).")
        return

    model, prompt = _parse_model_and_prompt(
        context.args or [], LLM_ALIASES, DEFAULT_LLM_MODEL
    )
    if not prompt:
        aliases = ", ".join(LLM_ALIASES.keys())
        await update.message.reply_text(
            f"Usage: /chat [model] <message>\n"
            f"Models: {aliases} (default: small = Llama 3 8B)\n"
            f"Example: /chat large explain quantum entanglement simply"
        )
        return

    await update.message.reply_text(f"Thinking… [{model}]")

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
            r = await client.post(
                f"{LLM_URL}/v1/chat/completions",
                json={
                    "model": model,
                    "messages": [{"role": "user", "content": prompt}],
                    "stream": False,
                },
            )

            if r.status_code == 202:
                data = r.json()
                job_id = data["job_id"]
                position = data.get("position", 1)
                status_msg = await update.message.reply_text(
                    f"⏳ Queued (position {position}) — I'll reply when the GPU has room."
                )
                asyncio.create_task(_poll_llm_job(update, job_id, model, status_msg))
                return

            r.raise_for_status()
            reply = r.json()["choices"][0]["message"]["content"]

        formatted, parse_mode = _format_with_think(reply)
        await update.message.reply_text(formatted, parse_mode=parse_mode)

    except httpx.HTTPStatusError as e:
        await update.message.reply_text(
            f"chat failed ({e.response.status_code}): {e.response.text[:200]}"
        )
    except httpx.HTTPError as e:
        await update.message.reply_text(f"chat failed: {e}")


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(
        "Commands:\n"
        "/imagegen [model] <prompt> — generate an image\n"
        "  models: sd (default), sdxl, refiner, flux\n"
        "/chat [model] <message> — ask an LLM\n"
        "  models: small (default), mistral, large\n"
        "/addsongtitle <title> — add a song title suggestion\n"
        "/showsongtitles — list all song titles\n"
        "/randomsongtitle — random song title\n"
        "/hello — 😈\n"
        "/help — this message"
    )


async def hello(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text("😈")


# ---------------------------------------------------------------------------
# Bot setup
# ---------------------------------------------------------------------------

async def set_bot_commands(app: Application) -> None:
    await app.bot.set_my_commands([
        BotCommand("imagegen",       "Generate an image — /imagegen [model] <prompt>"),
        BotCommand("chat",           "Chat with an LLM — /chat [model] <message>"),
        BotCommand("addsongtitle",   "Add a new song title suggestion"),
        BotCommand("showsongtitles", "List all submitted song titles"),
        BotCommand("randomsongtitle","Show a random song title suggestion"),
        BotCommand("hello",          "😈"),
        BotCommand("help",           "Show help"),
    ])


def main():
    application = (
        Application.builder()
        .token(TOKEN)
        .post_init(set_bot_commands)
        .build()
    )

    application.add_handler(CommandHandler("imagegen",       imagegen))
    application.add_handler(CommandHandler("chat",           chat))
    application.add_handler(CommandHandler("addsongtitle",   addsongtitle))
    application.add_handler(CommandHandler("showsongtitles", showsongtitles))
    application.add_handler(CommandHandler("randomsongtitle",randomsongtitle))
    application.add_handler(CommandHandler("help",           help_command))
    application.add_handler(CommandHandler("hello",          hello))

    application.run_polling()


if __name__ == "__main__":
    main()
