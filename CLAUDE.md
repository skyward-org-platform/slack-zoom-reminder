# CLAUDE.md

Operational notes for the slack-zoom-reminder project.

## What this does

Daily Cloud Run job that posts a Slack reminder the day before each client Zoom meeting. Reads Google Calendar, matches event titles to clients in `clients.yaml`, posts one message per matched client to that client's Slack channel.

## Commands

```bash
# Local dry run against tomorrow's events
set -a && source .env && set +a
uv run python reminder.py --dry-run

# Local dry run against a specific date
uv run python reminder.py --dry-run --date 2026-05-06

# Manually execute the deployed Cloud Run job
gcloud run jobs execute slack-zoom-reminder --region=us-central1 --wait

# Read logs from the most recent execution
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="slack-zoom-reminder"' --limit=30 --format='value(textPayload)' --order=asc

# Manually fire the CI/CD trigger (or just `git push`)
gcloud builds triggers run slack-zoom-reminder-main --region=global --branch=main

# From-scratch reinstall (idempotent — also re-applies IAM)
./deploy.sh
```

## Architecture

- `reminder.py` — single-file script. Lists events in target day's window (00:00–24:00 in `America/New_York`), groups matched events by client, posts via `chat.postMessage`.
- `clients.yaml` — committed config-as-code. Each client has `name`, `match` (case-insensitive substring on event title; **first match wins**, blank `match` is skipped), and prod `slack_channel`.
- `deploy.sh` — one-shot bootstrap (Artifact Registry, Secret Manager, Cloud Run job, Cloud Scheduler, IAM).
- `cloudbuild.yaml` — runs on push to `main`: build → push image → `gcloud run jobs update`.
- Cloud Scheduler `slack-zoom-reminder-daily` fires the job at 8am `America/New_York` (DST-correct).

## Environment

`.env` (gitignored, local-only):

| Var | Purpose |
|---|---|
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to SA key JSON. **Unset on Cloud Run** — uses the runtime SA's ADC. |
| `SLACK_BOT_TOKEN` | Local dev only. In Cloud Run, comes from Secret Manager `slack-zoom-reminder-bot-token:latest`. |
| `SLACK_CHANNEL_ID_TEST` | Required when `ENV=test`. All matched messages route here. |
| `ENV` | `test` (everything → `SLACK_CHANNEL_ID_TEST`) or `prod` (per-client `slack_channel` from yaml). Cloud Run job has `ENV=prod`. |

## Operational gotchas

- **Bot must be invited to every client channel.** Missing membership = `channel_not_found` (logged, non-fatal — script continues to other clients). Adding clients to `clients.yaml` is half the work; the other half is `Add apps` per channel.
- **`clients.yaml` is committed.** Channel IDs aren't secrets. Adding a client = edit yaml, commit, push → trigger rebuilds and updates the job.
- **Rotating the Slack token:** `printf '%s' "$NEW_TOKEN" | gcloud secrets versions add slack-zoom-reminder-bot-token --data-file=-`. The job pins `:latest`, so the next execution picks it up — no redeploy needed.
- **Cloud Build trigger uses the Compute Engine default SA**, not the Cloud Build SA. `deploy.sh` grants both, but if you ever recreate the trigger and grants are missing, the build's `gcloud run jobs update` step fails with permission errors.
- **DST**: handled by Cloud Scheduler's `timeZone` field. The cron is `0 8 * * *` in `America/New_York` — don't convert to UTC manually.
- **Date window** is `00:00 → 24:00` of the *target* day (tomorrow, in ET), not a rolling 24h from "now."
- **OAuth scopes** required on the Slack app: `chat:write` only. Bot does not need `channels:read` (we don't list channels) or `chat:write.customize` (we don't override username).

## Deploy flow

- **First time / disaster recovery:** run `./deploy.sh` locally with `SLACK_BOT_TOKEN` exported. Creates everything from scratch.
- **Code changes:** `git push origin main` → Cloud Build trigger rebuilds and updates the job in ~1–2 min.
- **Verify a deploy succeeded:** `gcloud run jobs describe slack-zoom-reminder --region=us-central1 --format='value(spec.template.spec.template.spec.containers[0].image)'` should end in the new commit's short SHA.
