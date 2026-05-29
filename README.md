# 💪 Muscle Bot — Telegram Workout Tracker

An Elixir-powered Telegram bot that logs, edits, and queries workout logs directly inside a Google Sheets spreadsheet.

---

## 🚀 Key Features

* **Interactive Logging (`/input`)**
  * **Persistent Username Mapping**: Automatically maps Telegram usernames to spreadsheet names. Custom mappings are persisted locally in `username_mappings.json` so you only have to specify who you are once.
  * **Smart Paginated Exercise Selection**: Generates an inline keyboard listing existing exercises in the sheet, sorted by most recent usage. Supports `➕ New exercise` for custom text input.
  * **📋 Copy Last Day's Workout**: With a single tap, copies all of your exercises from your most recent workout day to today, showing a review confirmation before batch-appending them.
  * **Direct Logging**: Directly appends to the sheet upon entering the load, omitting redundant confirmation steps for rapid entry.

* **Surgical Entry Editing (`/edit`)**
  * Displays the user's last 10 entries using their mapped username.
  * Allows clicking an entry and choosing exactly which column field (`date`, `name`, `exercise`, `reps`, `sets`, `load`) to update.

* **Optimized Mobile Querying (`/query`)**
  * Filter history by: `📅 Today`, `📆 Last 7 days`, `🏋️ By exercise`, or `📋 Last 20 entries`.
  * Mobile-optimized format: Grouped by date and user name, displaying a clean list of entries.
  * Automatically omits the `bw` (bodyweight) suffix if the load column is empty, maintaining a compact layout.
  * Lists entries for all users to enable collaborative tracking.

* **Robust and No-Noise Conversational Design**
  * Silently ignores any out-of-context text messages to avoid chat clutter (does not reply with error/help messages unless you actively trigger a flow or request `/help`).
  * Full support for `/cancel` at any stage of active conversational menus.

---

## 🛠️ Setup Instructions

### 1. Google Cloud Service Account Setup
1. Go to the [Google Cloud Console](https://console.cloud.google.com/).
2. Enable the **Google Sheets API** for your project.
3. Create a **Service Account** under **IAM & Admin > Service Accounts**.
4. Create a new key for that Service Account in **JSON** format, download it, and place it in this directory as `service_account.json`.
5. Open your target Google Spreadsheet and click **Share** at the top right. Add the service account email (from your `service_account.json`) as an **Editor**.

### 2. Telegram Bot Setup
1. Contact `@BotFather` on Telegram.
2. Run `/newbot` and follow the prompts to obtain a **Bot Token**.

### 3. Environment Configuration
Create or update `env.sh` in the directory:
```bash
export TELEGRAM_BOT_TOKEN="your-telegram-bot-token"
export GOOGLE_SPREADSHEET_ID="your-spreadsheet-id-from-url"
export GOOGLE_SHEET_NAME="Log"
export GOOGLE_SERVICE_ACCOUNT_JSON="./service_account.json"
```

---

## 🏃 Running the Bot

To start the bot, run the helper script:
```bash
chmod +x run.sh
./run.sh
```

---

## 📂 Project Architecture

* **`muscle_bot.exs`**: The core application. Uses `Mix.install` to load Elixir dependencies (`req`, `jason`, `jose`) in a single self-contained script. Handles token authorization, Telegram long polling, state management via a local ETS table, and Google Sheets updates.
* **`username_mappings.json`**: Formed dynamically. Persists mappings between Telegram usernames (lowercase) and sheet names.
* **`run.sh`**: Helper shell script that exports environment variables and starts the Elixir bot.
