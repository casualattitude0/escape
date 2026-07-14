#!/usr/bin/env bash
set -euo pipefail

# Deploys relay-server to Cloud Run. Room state lives entirely in memory (no DB),
# so --max-instances=1 pins everything to one instance (Cloud Run gives no
# cross-instance state sync, only best-effort session affinity). --timeout=3600
# is the max Cloud Run allows; a match running longer than that will need to
# reconnect (same room, same reclaim-by-token flow as any other drop).
#
# MIN_INSTANCES defaults to 0 (scale-to-zero): no cost while nobody is playing,
# at the price of a ~2-5s cold start for the first player to connect. This is
# safe here because the instance only scales to zero once every WebSocket has
# disconnected — i.e. when there are no live rooms left to lose anyway. Set
# MIN_INSTANCES=1 to keep it always warm (no cold start, but billed 24/7).
#
# Usage: PROJECT_ID=my-project REGION=asia-east1 ./deploy.sh
# (run from the relay-server/ directory)

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to your GCP project id}"
REGION="${REGION:-asia-east1}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
SERVICE_NAME="escape-relay"

gcloud run deploy "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --source . \
  --allow-unauthenticated \
  --min-instances="$MIN_INSTANCES" \
  --max-instances=1 \
  --timeout=3600 \
  --port=8080

URL="$(gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"
echo
echo "Deployed: $URL"
echo "Set RELAY_WS_URL in scripts/net/net.gd to: ${URL/https:/wss:}/connect"
