#!/usr/bin/env bash
# Delete everything deploy.sh created (stops all billing for this project's resources).
set -euo pipefail
: "${PROJECT_ID:?Set PROJECT_ID}"
REGION="${REGION:-us-central1}"
PREFIX="${PREFIX:-workflow}"

read -r -p "Delete Cloud Run services, Cloud SQL instance, bucket and secrets in ${PROJECT_ID}? [y/N] " ok
[[ "$ok" == "y" ]] || exit 1

gcloud run services delete "${PREFIX}-frontend" --region "$REGION" --quiet || true
gcloud run services delete "${PREFIX}-backend" --region "$REGION" --quiet || true
gcloud sql instances delete "${PREFIX}-pg" --quiet || true
gcloud secrets delete "${PREFIX}-database-url" --quiet || true
gcloud storage rm -r "gs://${PROJECT_ID}-${PREFIX}-data" --quiet || true
gcloud artifacts repositories delete "${PREFIX}-images" --location "$REGION" --quiet || true
