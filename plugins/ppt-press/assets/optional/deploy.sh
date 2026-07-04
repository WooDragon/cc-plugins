#!/usr/bin/env bash
# deploy.sh -- local build + upload to Amplify
# usage: bash scripts/deploy.sh
# credentials: .env (AWS_PROFILE / AWS_REGION)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
APP_ID="${PPT_AMPLIFY_APP_ID:?请设置环境变量 PPT_AMPLIFY_APP_ID 或在 .env 中配置}"

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

PROFILE="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-ap-southeast-1}"

echo "=== build ==="
cd "$REPO_ROOT"
npm run build
BUILD_DIR="$REPO_ROOT/dist"

ZIP_FILE="$REPO_ROOT/_deploy.zip"
rm -f "$ZIP_FILE"
(cd "$BUILD_DIR" && zip -qr "$ZIP_FILE" .)
echo "zip: $(du -sh "$ZIP_FILE" | cut -f1)"

echo "=== cancel any stuck pending jobs ==="
PENDING=$(aws amplify list-jobs --app-id "$APP_ID" --branch-name main \
  --region "$REGION" --profile "$PROFILE" \
  --query 'jobSummaries[?status==`PENDING`].jobId' --output text 2>/dev/null || true)
for jid in $PENDING; do
  aws amplify stop-job --app-id "$APP_ID" --branch-name main \
    --job-id "$jid" --region "$REGION" --profile "$PROFILE" > /dev/null 2>&1 || true
  echo "cancelled pending job $jid"
done

echo "=== create deployment slot ==="
DEPLOY_JSON=$(aws amplify create-deployment \
  --app-id "$APP_ID" --branch-name main \
  --region "$REGION" --profile "$PROFILE" \
  --output json)
JOB_ID=$(echo "$DEPLOY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")
ZIP_URL=$(echo "$DEPLOY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['zipUploadUrl'])")
echo "jobId: $JOB_ID"

echo "=== upload ==="
curl -s -w "HTTP %{http_code}\n" -T "$ZIP_FILE" "$ZIP_URL"

echo "=== start deployment ==="
aws amplify start-deployment \
  --app-id "$APP_ID" --branch-name main \
  --job-id "$JOB_ID" \
  --region "$REGION" --profile "$PROFILE" > /dev/null

latest_status() {
  aws amplify list-jobs --app-id "$APP_ID" --branch-name main \
    --region "$REGION" --profile "$PROFILE" \
    --query 'jobSummaries[0].status' --output text 2>/dev/null | awk 'NF{print; exit}'
}

echo "=== waiting... ==="
until [[ "$(latest_status)" =~ ^(SUCCEED|FAILED|CANCELLED)$ ]]; do
  sleep 5
done

STATUS=$(latest_status)
rm -f "$ZIP_FILE"

if [ "$STATUS" = "SUCCEED" ]; then
  SITE_URL="${PPT_SITE_URL:-https://main.${APP_ID}.amplifyapp.com}"
  echo "deploy OK: $SITE_URL"
else
  echo "deploy FAILED: $STATUS" >&2
  exit 1
fi
