# slack-zoom-reminder

Posts a Slack reminder at 9am the day before each client's Zoom meeting.

## How it works

1. Reads one or more Google Calendars.
2. For each event happening on the target day (default: tomorrow), matches the event title against the client list.
3. Groups events by client and posts a single message to that client's Slack channel.

## Setup

### 1. Google Calendar (service account)

In a GCP project:
1. Enable the Google Calendar API.
2. Create a service account, download a JSON key, save as `service-account.json` in this folder.
3. Share each calendar that contains client meetings with the service account's email (Reader access is fine).

### 2. Slack bot

1. Create a Slack app at https://api.slack.com/apps.
2. Add bot scope `chat:write`.
3. Install to workspace, copy the bot token (`xoxb-...`).
4. Invite the bot to every client channel: `/invite @your-bot` in each channel.

### 3. Local config

```bash
cp .env.example .env          # then fill in values
cp clients.example.yaml clients.yaml   # then edit calendars + clients
```

Get each Slack channel ID from the channel's "About" panel (bottom of sidebar).

### 4. Install + run

```bash
uv sync
set -a && source .env && set +a
uv run python reminder.py --dry-run                    # tomorrow, prints only
uv run python reminder.py --dry-run --date 2026-05-15  # specific day
uv run python reminder.py                              # actually post
```

## Cron (later)

Once happy locally, deploy on a 9am daily schedule. GCP Cloud Scheduler → Cloud Run job is the simplest fit.
