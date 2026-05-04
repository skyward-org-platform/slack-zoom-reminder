#!/usr/bin/env bash
# Deploy slack-zoom-reminder to Cloud Run Jobs + Cloud Scheduler.
# Idempotent: re-run after changes to push a new image and update the job.

set -euo pipefail

PROJECT_ID="data-hub-468216"
REGION="us-central1"
JOB_NAME="slack-zoom-reminder"
SCHEDULER_NAME="slack-zoom-reminder-daily"
REPO_NAME="slack-zoom-reminder"
SECRET_NAME="slack-zoom-reminder-bot-token"
SERVICE_ACCOUNT="slack-zoom-alerts@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/reminder:latest"

# 9am Eastern, every day. Cloud Scheduler handles DST via timeZone.
CRON_SCHEDULE="0 9 * * *"
CRON_TZ="America/New_York"

echo ">>> Project: $PROJECT_ID  Region: $REGION"
gcloud config set project "$PROJECT_ID" --quiet

echo ">>> Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com \
  calendar-json.googleapis.com \
  --quiet

echo ">>> Ensuring Artifact Registry repo exists"
gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --description="slack-zoom-reminder container images"

echo ">>> Ensuring Slack token secret exists"
if ! gcloud secrets describe "$SECRET_NAME" >/dev/null 2>&1; then
  if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
    echo "ERROR: secret '$SECRET_NAME' not found and SLACK_BOT_TOKEN is unset."
    echo "       Run: source .env && set -a && ./deploy.sh"
    exit 1
  fi
  gcloud secrets create "$SECRET_NAME" --replication-policy=automatic
  printf '%s' "$SLACK_BOT_TOKEN" | gcloud secrets versions add "$SECRET_NAME" --data-file=-
fi

echo ">>> Granting runtime SA access to the secret"
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet >/dev/null

echo ">>> Building image with Cloud Build"
gcloud builds submit --tag "$IMAGE" .

echo ">>> Creating or updating Cloud Run Job"
COMMON_ARGS=(
  --image="$IMAGE"
  --region="$REGION"
  --service-account="$SERVICE_ACCOUNT"
  --max-retries=1
  --task-timeout=300s
  --set-env-vars="ENV=prod"
  --set-secrets="SLACK_BOT_TOKEN=${SECRET_NAME}:latest"
)
if gcloud run jobs describe "$JOB_NAME" --region="$REGION" >/dev/null 2>&1; then
  gcloud run jobs update "$JOB_NAME" "${COMMON_ARGS[@]}"
else
  gcloud run jobs create "$JOB_NAME" "${COMMON_ARGS[@]}"
fi

echo ">>> Creating or updating Cloud Scheduler trigger"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
JOB_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_NUMBER}/jobs/${JOB_NAME}:run"

SCHED_ARGS=(
  --location="$REGION"
  --schedule="$CRON_SCHEDULE"
  --time-zone="$CRON_TZ"
  --uri="$JOB_URI"
  --http-method=POST
  --oauth-service-account-email="$SERVICE_ACCOUNT"
)
if gcloud scheduler jobs describe "$SCHEDULER_NAME" --location="$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$SCHEDULER_NAME" "${SCHED_ARGS[@]}"
else
  gcloud scheduler jobs create http "$SCHEDULER_NAME" "${SCHED_ARGS[@]}"
fi

echo ">>> Granting scheduler SA permission to invoke the job"
gcloud run jobs add-iam-policy-binding "$JOB_NAME" \
  --region="$REGION" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

echo ">>> Granting Cloud Build SA permission to update the job (for CI/CD trigger)"
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/run.developer" \
  --condition=None --quiet >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT" \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --quiet >/dev/null

echo ""
echo ">>> Done."
echo "    Test now:   gcloud run jobs execute $JOB_NAME --region=$REGION --wait"
echo "    Schedule:   $CRON_SCHEDULE ($CRON_TZ)"
echo "    Logs:       gcloud beta run jobs executions list --job=$JOB_NAME --region=$REGION"
