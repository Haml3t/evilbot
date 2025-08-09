from dotenv import load_dotenv
import logging
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes
import sqlite3
from datetime import datetime
import random

# Set up logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO
)
logger = logging.getLogger(__name__)

# Explicitly load .env from the telegram-bot directory
env_path = Path(__file__).resolve().parent / ".env"
load_dotenv()

import os
from telegram.ext import Application, CommandHandler, ContextTypes

TOKEN = os.environ.get('TELEGRAM_BOT_TOKEN')
if not TOKEN:
    raise ValueError("No Telegram API token found in environment variables.")

# Connect to (or create) the SQLite database
conn = sqlite3.connect('evilbot.db', check_same_thread=False)
cursor = conn.cursor()

# Create the table for song titles if it doesn't exist
cursor.execute('''
    CREATE TABLE IF NOT EXISTS songtitles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        song_title TEXT NOT NULL,
        username TEXT NOT NULL,
        timestamp DATETIME NOT NULL
    )
''')
conn.commit()

async def addsongtitle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not context.args:
        await update.message.reply_text('Usage: /addsongtitle Song Title')
        return
    song_title = ' '.join(context.args)
    username = update.effective_user.username or update.effective_user.first_name
    timestamp = datetime.now()
    cursor.execute(
        "INSERT INTO songtitles (song_title, username, timestamp) VALUES (?, ?, ?)",
        (song_title, username, timestamp)
    )
    conn.commit()
    await update.message.reply_text(f'Added song title: {song_title}')

async def showsongtitles(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cursor.execute("SELECT song_title, username, timestamp FROM songtitles")
    rows = cursor.fetchall()
    if not rows:
        await update.message.reply_text("No song titles have been added yet.")
        return
    #message = "\n".join([f"{song} (by {user} on {time})" for song, user, time in rows])
    message = "\n".join([f"{song}" for song, user, time in rows])
    await update.message.reply_text(message)

async def randomsongtitle(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cursor.execute("SELECT song_title, username, timestamp FROM songtitles")
    rows = cursor.fetchall()
    if not rows:
        await update.message.reply_text("No song titles available.")
        return
    song, user, time = random.choice(rows)
    #message = f"Random Song Title: {song} (submitted by {user} on {time})"
    message = f"Random Song Title: {song}"

    await update.message.reply_text(message)

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    help_text = (
        "Available commands:\n"
        "/addsongtitle <song title> - Adds a new song title to the list.\n"
        "/showsongtitles - Displays all submitted song titles.\n"
        "/randomsongtitle - Shows a random song title suggestion.\n"
        "/hello - hi.\n"
        "/help - Displays this help message."
    )
    await update.message.reply_text(help_text)

async def hello(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    # Respond with the smiling purple devil emoji
    await update.message.reply_text("😈")

def main():
    # Build the application using the new Application builder pattern
    application = Application.builder().token(TOKEN).build()

    # Add command handlers
    application.add_handler(CommandHandler("addsongtitle", addsongtitle))
    application.add_handler(CommandHandler("showsongtitles", showsongtitles))
    application.add_handler(CommandHandler("randomsongtitle", randomsongtitle))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("hello", hello))

    # Start the bot using the new async run_polling() method
    application.run_polling()

if __name__ == '__main__':
    main()
