#!/usr/bin/env bash
set -euo pipefail

# Deploys relay-server to Cloud Run as a single always-on instance. Room state
# lives entirely in memory (no DB) — --min-instances=1 --max-instances=1 pins
# everything to one instance, since Cloud Run gives no cross-instance state
# sync and only best-effort session affinity. --timeout=3600 is the max Cloud
# Run allows; a match running longer than that will need to reconnect (same
# room, same reclaim-by-token flow as any other drop).
#
# Usage: PROJECT_ID=my-project REGION=us-central1 ./deploy.sh
# (run from the relay-server/ directory)

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to your GCP project id}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="escape-relay"

gcloud run deploy "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --source . \
  --allow-unauthenticated \
  --min-instances=1 \
  --max-instances=1 \
  --timeout=3600 \
  --port=8080

URL="$(gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"
echo
echo "Deployed: $URL"
echo "Set RELAY_WS_URL in scripts/net/net.gd to: ${URL/https:/wss:}/connect"
