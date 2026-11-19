# Deploying to Google Cloud (Cloud Run + Cloud SQL + Vertex AI)

```
                ┌────────────────────┐        ┌───────────────────────────┐
 browser ──────▶│ workflow-frontend  │──/api─▶│ workflow-backend          │
                │ Cloud Run (nginx)  │        │ Cloud Run (FastAPI)       │
                └────────────────────┘        │  ├─ Cloud SQL (Postgres16)│ via unix socket
                                              │  ├─ GCS volume /app/data  │ documents + FAISS
                                              │  ├─ Secret Manager        │ DATABASE_URL
                                              │  └─ Vertex AI Gemini      │ chat + embeddings (ADC)
                                              └───────────────────────────┘
```

## Prerequisites
- `gcloud` CLI, logged in (`gcloud auth login`), with billing enabled on the project
- Owner or Editor role on the project

## Deploy
```bash
export PROJECT_ID=your-project-id
export REGION=us-central1          # optional
./deploy/cloudrun/deploy.sh
```
The first run takes about 15 minutes, mostly creating the Cloud SQL instance. Later runs only rebuild and roll out new images.

## What it creates
| Resource | Name | Notes |
|---|---|---|
| Artifact Registry | `workflow-images` | Backend and frontend images built by Cloud Build |
| Service account | `workflow-runtime` | `cloudsql.client`, `aiplatform.user`, `secretmanager.secretAccessor`, plus object admin on the data bucket |
| Cloud SQL | `workflow-pg` | PostgreSQL 16, `db-f1-micro`. Migrations run automatically on startup |
| Secret | `workflow-database-url` | Generated password, never printed |
| GCS bucket | `<project>-workflow-data` | Mounted at `/app/data` with Cloud Run volume mounts |
| Cloud Run | `workflow-backend`, `workflow-frontend` | Scale to zero. The backend is capped at 1 instance (single FAISS writer) |

## Notes
- Gemini models on Vertex AI are called through the `global` endpoint (`VERTEX_LOCATION`, default `global`). Cloud Run, Cloud SQL and the bucket stay in `REGION`.
- The sample dataset (`data/sample/*.csv`) is copied into the bucket, because the backend image only contains `backend/`.

## Cost
Cloud Run scales to zero when idle. The main fixed cost is the `db-f1-micro` Cloud SQL instance (a few USD per month). Run `./deploy/cloudrun/teardown.sh` when you're done.

## Locking it down
Both services are deployed with `--allow-unauthenticated` so the demo is public. For private use, remove that flag and put the services behind IAP, or call them with an identity token.
