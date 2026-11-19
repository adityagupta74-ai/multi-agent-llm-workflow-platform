#!/usr/bin/env bash
# Deploy the platform to Google Cloud:
#   Cloud Run (backend + frontend) · Cloud SQL for PostgreSQL 16 · Vertex AI Gemini
#   Cloud Storage volume for uploaded documents and the FAISS index · Secret Manager
#
# Usage:
#   export PROJECT_ID=my-gcp-project      # required
#   export REGION=us-central1             # optional
#   ./deploy/cloudrun/deploy.sh
#
# Idempotent: re-running skips resources that already exist and rolls out new images.
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to your GCP project id}"
REGION="${REGION:-us-central1}"
PREFIX="${PREFIX:-workflow}"
REPO="${PREFIX}-images"
SQL_INSTANCE="${PREFIX}-pg"
DB_NAME="workflow_db"
DB_USER="workflow"
BUCKET="${PROJECT_ID}-${PREFIX}-data"
SA_NAME="${PREFIX}-runtime"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
LLM_MODEL="${LLM_MODEL:-gemini-2.5-flash}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

gcloud config set project "$PROJECT_ID" >/dev/null

echo "==> Enabling APIs"
gcloud services enable run.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com aiplatform.googleapis.com storage.googleapis.com

echo "==> Artifact Registry"
gcloud artifacts repositories describe "$REPO" --location "$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REPO" --repository-format docker --location "$REGION"

echo "==> Runtime service account"
gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_NAME" --display-name "Workflow platform runtime"
for role in roles/cloudsql.client roles/aiplatform.user roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:${SA}" --role "$role" \
    --condition None >/dev/null
done

echo "==> Cloud SQL (PostgreSQL 16) — first creation takes ~10 minutes"
if ! gcloud sql instances describe "$SQL_INSTANCE" >/dev/null 2>&1; then
  gcloud sql instances create "$SQL_INSTANCE" --database-version POSTGRES_16 \
    --edition ENTERPRISE --tier db-f1-micro --region "$REGION" --storage-size 10
fi
gcloud sql databases describe "$DB_NAME" --instance "$SQL_INSTANCE" >/dev/null 2>&1 || \
  gcloud sql databases create "$DB_NAME" --instance "$SQL_INSTANCE"

if ! gcloud secrets describe "${PREFIX}-database-url" >/dev/null 2>&1; then
  DB_PASS="$(openssl rand -hex 24)"
  gcloud sql users create "$DB_USER" --instance "$SQL_INSTANCE" --password "$DB_PASS" 2>/dev/null || \
    gcloud sql users set-password "$DB_USER" --instance "$SQL_INSTANCE" --password "$DB_PASS"
  CONN="$(gcloud sql instances describe "$SQL_INSTANCE" --format 'value(connectionName)')"
  printf 'postgresql+asyncpg://%s:%s@/%s?host=/cloudsql/%s' "$DB_USER" "$DB_PASS" "$DB_NAME" "$CONN" | \
    gcloud secrets create "${PREFIX}-database-url" --data-file -
fi
CONN="$(gcloud sql instances describe "$SQL_INSTANCE" --format 'value(connectionName)')"

echo "==> Cloud Storage bucket for documents + FAISS index"
gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1 || \
  gcloud storage buckets create "gs://${BUCKET}" --location "$REGION" --uniform-bucket-level-access
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member "serviceAccount:${SA}" --role roles/storage.objectAdmin >/dev/null

TAG="$(date +%Y%m%d-%H%M%S)"

echo "==> Building backend image"
gcloud builds submit "$ROOT/backend" --tag "${REGISTRY}/backend:${TAG}"

echo "==> Deploying backend"
# max-instances=1: the FAISS index is a single file on the mounted bucket, so one
# writer keeps it consistent. Swap to Vertex AI Vector Search to scale out.
gcloud run deploy "${PREFIX}-backend" \
  --image "${REGISTRY}/backend:${TAG}" --region "$REGION" --service-account "$SA" \
  --port 8000 --cpu 1 --memory 2Gi --min-instances 0 --max-instances 1 --timeout 300 \
  --add-cloudsql-instances "$CONN" \
  --set-secrets "DATABASE_URL=${PREFIX}-database-url:latest" \
  --set-env-vars "APP_ENV=production,LLM_PROVIDER=vertex,LLM_MODEL=${LLM_MODEL},EMBEDDING_PROVIDER=vertex,EMBEDDING_MODEL=gemini-embedding-001,EMBEDDING_DIMENSION=768,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=${REGION},DOCUMENT_STORAGE_PATH=/app/data/documents,FAISS_INDEX_PATH=/app/data/faiss" \
  --add-volume "name=data,type=cloud-storage,bucket=${BUCKET}" \
  --add-volume-mount "volume=data,mount-path=/app/data" \
  --allow-unauthenticated
BACKEND_URL="$(gcloud run services describe "${PREFIX}-backend" --region "$REGION" --format 'value(status.url)')"

echo "==> Building frontend image"
gcloud builds submit "$ROOT/frontend" --tag "${REGISTRY}/frontend:${TAG}"

echo "==> Deploying frontend"
gcloud run deploy "${PREFIX}-frontend" \
  --image "${REGISTRY}/frontend:${TAG}" --region "$REGION" \
  --port 8080 --cpu 1 --memory 256Mi --min-instances 0 --max-instances 2 \
  --set-env-vars "BACKEND_URL=${BACKEND_URL}" \
  --allow-unauthenticated
FRONTEND_URL="$(gcloud run services describe "${PREFIX}-frontend" --region "$REGION" --format 'value(status.url)')"

cat <<EOF

Deployed.
  Frontend : ${FRONTEND_URL}
  API docs : ${BACKEND_URL}/docs
  Health   : ${BACKEND_URL}/api/v1/health/ready

Tear down with: PROJECT_ID=${PROJECT_ID} ./deploy/cloudrun/teardown.sh
EOF
