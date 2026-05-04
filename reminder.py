"""Send Slack reminders for tomorrow's client Zoom meetings."""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import yaml
from google.auth import default as default_credentials
from google.oauth2 import service_account
from googleapiclient.discovery import build
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]


def load_config(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def get_calendar_service(credentials_path: Path | None):
    if credentials_path:
        creds = service_account.Credentials.from_service_account_file(
            str(credentials_path), scopes=SCOPES
        )
    else:
        creds, _ = default_credentials(scopes=SCOPES)
    return build("calendar", "v3", credentials=creds, cache_discovery=False)


def list_events_for_day(
    service, calendar_ids: list[str], day: datetime, tz: ZoneInfo
) -> list[dict]:
    start = datetime.combine(day.date(), time.min, tzinfo=tz)
    end = start + timedelta(days=1)
    all_events = []
    for cal_id in calendar_ids:
        resp = (
            service.events()
            .list(
                calendarId=cal_id,
                timeMin=start.isoformat(),
                timeMax=end.isoformat(),
                singleEvents=True,
                orderBy="startTime",
            )
            .execute()
        )
        all_events.extend(resp.get("items", []))
    return all_events


def match_client(event: dict, clients: list[dict]) -> dict | None:
    title = (event.get("summary") or "").lower()
    for client in clients:
        match = (client.get("match") or "").strip()
        if match and match.lower() in title:
            return client
    return None


def format_event_time(event: dict, tz: ZoneInfo) -> str:
    start = event["start"].get("dateTime") or event["start"].get("date")
    if "T" not in start:
        return "all day"
    dt = datetime.fromisoformat(start).astimezone(tz)
    return dt.strftime("%-I:%M %p")


def build_message(client_name: str, events: list[dict], tz: ZoneInfo) -> str:
    times = [format_event_time(ev, tz) for ev in events]
    if len(times) == 1:
        time_str = f"{times[0]} EST"
    elif len(times) == 2:
        time_str = f"{times[0]} and {times[1]} EST"
    else:
        time_str = ", ".join(times[:-1]) + f", and {times[-1]} EST"
    return (
        f"<!here> we have our weekly meeting tomorrow for {client_name} "
        f"at {time_str}, please be sure to update all your tasks "
        f"that relate to the client today."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send Slack reminders for tomorrow's Zoom meetings."
    )
    parser.add_argument("--config", default="clients.yaml", help="Path to clients config YAML")
    parser.add_argument("--date", help="Override target date (YYYY-MM-DD); default = tomorrow")
    parser.add_argument("--dry-run", action="store_true", help="Print messages without posting")
    args = parser.parse_args()

    config = load_config(Path(args.config))
    tz = ZoneInfo(config.get("timezone", "America/New_York"))
    calendar_ids = config["calendar_ids"]
    clients = config["clients"]

    env = os.environ.get("ENV", "prod").lower()
    if env not in ("test", "prod"):
        print(f"ENV must be 'test' or 'prod', got {env!r}", file=sys.stderr)
        return 2
    test_channel = os.environ.get("SLACK_CHANNEL_ID_TEST")
    if env == "test" and not test_channel:
        print("ENV=test requires SLACK_CHANNEL_ID_TEST", file=sys.stderr)
        return 2
    print(f"Running in ENV={env}" + (f" → {test_channel}" if env == "test" else ""))

    if args.date:
        target = datetime.fromisoformat(args.date).replace(tzinfo=tz)
    else:
        target = datetime.now(tz) + timedelta(days=1)

    print(
        f"Looking up events for {target.date().isoformat()} "
        f"across {len(calendar_ids)} calendar(s)..."
    )

    creds_env = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    creds_path = Path(creds_env) if creds_env else None
    cal_service = get_calendar_service(creds_path)
    events = list_events_for_day(cal_service, calendar_ids, target, tz)
    print(f"Found {len(events)} event(s).")

    by_client: dict[str, dict] = {}
    for ev in events:
        client = match_client(ev, clients)
        if not client:
            print(f"  [skip] no client match: {ev.get('summary')!r}")
            continue
        key = client["name"]
        by_client.setdefault(key, {"client": client, "events": []})["events"].append(ev)

    if not by_client:
        print("No client meetings tomorrow. Nothing to send.")
        return 0

    slack = WebClient(token=os.environ["SLACK_BOT_TOKEN"]) if not args.dry_run else None

    for entry in by_client.values():
        client = entry["client"]
        msg = build_message(client["name"], entry["events"], tz)
        channel = test_channel if env == "test" else client["slack_channel"]
        print(f"\n--- {client['name']} → {channel} ---\n{msg}")
        if args.dry_run:
            continue
        try:
            slack.chat_postMessage(
                channel=channel,
                text=msg,
                username="Skyward Alerts",
            )
            print("  [sent]")
        except SlackApiError as e:
            print(f"  [error] {e.response['error']}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
