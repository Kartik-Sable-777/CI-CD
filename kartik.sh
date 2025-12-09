#!/usr/bin/env bash
# kartik-final.sh - final helper to generate skaffold.yaml and run skaffold with robust diagnostics
set -euo pipefail

# Config
REGION="${REGION:-us-central1}"
AR_NAME="${AR_NAME:-cicd-challenge}"
WORKDIR="${HOME}/cloud-deploy-tutorials/tutorials/base"
SKAFFOLD_LOG="skaffold-debug.log"

# Preflight: required commands
REQUIRED=(gcloud gsutil git skaffold envsubst sed awk date sleep)
for c in "${REQUIRED[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Required command '$c' not found. Install it before running this script." >&2
    exit 1
  fi
done

# Ensure gcloud project set and export PROJECT_ID
GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$GCLOUD_PROJECT" ] || [ "$GCLOUD_PROJECT" = "(unset)" ]; then
  echo "gcloud project is not set. Run 'gcloud config set project <PROJECT_ID>' and retry." >&2
  exit 1
fi
export PROJECT_ID="$GCLOUD_PROJECT"
echo "Using PROJECT_ID=${PROJECT_ID}"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)
if [ -z "$PROJECT_NUMBER" ]; then
  echo "Unable to get project number for $PROJECT_ID" >&2
  exit 1
fi

# Ensure Artifact Registry exists (create if missing)
if ! gcloud artifacts repositories describe "$AR_NAME" --location="$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Creating Artifact Registry repository '$AR_NAME' in $REGION..."
  gcloud artifacts repositories create "$AR_NAME" \
    --repository-format=docker --location="$REGION" \
    --description="Image registry for tutorial web app" --project "$PROJECT_ID" --quiet
else
  echo "Artifact Registry '$AR_NAME' exists in $REGION."
fi

# Ensure Cloud Build bucket exists
BUCKET="${PROJECT_ID}_cloudbuild"
if ! gsutil ls "gs://${BUCKET}/" >/dev/null 2>&1; then
  echo "Creating Cloud Build bucket: gs://${BUCKET}..."
  gsutil mb -p "$PROJECT_ID" -l "$REGION" -b on "gs://${BUCKET}/"
else
  echo "Cloud Build bucket gs://${BUCKET} exists."
fi

# Prepare web/skaffold.yaml: generate from template if present, otherwise create minimal fallback
cd "$WORKDIR" || { echo "Expected workspace $WORKDIR not found"; exit 1; }

TEMPLATE="clouddeploy-config/skaffold.yaml.template"
WEB_DIR="web"
mkdir -p "$WEB_DIR"

if [ -f "$TEMPLATE" ]; then
  echo "Generating $WEB_DIR/skaffold.yaml from template..."
  # Use envsubst to substitute {{project-id}} pattern if present
  # create a copy, then replace placeholder
  envsubst < "$TEMPLATE" > "$WEB_DIR/skaffold.yaml"
  # fallback: replace literal {{project-id}} if envsubst didn't
  sed -i "s/{{project-id}}/${PROJECT_ID}/g" "$WEB_DIR/skaffold.yaml" || true
else
  echo "Template $TEMPLATE not found. Writing minimal skaffold.yaml fallback..."
  cat > "$WEB_DIR/skaffold.yaml" <<EOF
apiVersion: skaffold/v2beta26
kind: Config
metadata:
  name: leeroy
build:
  artifacts:
  - image: ${AR_NAME}/leeroy-web
    context: .
    docker:
      dockerfile: Dockerfile-web
  - image: ${AR_NAME}/leeroy-app
    context: .
    docker:
      dockerfile: Dockerfile-app
  local: {}
deploy:
  kubectl:
    manifests:
      - k8s-*
EOF
fi

# show generated skaffold.yaml header
echo "---- web/skaffold.yaml (head) ----"
sed -n '1,60p' "$WEB_DIR/skaffold.yaml" || true
echo "----------------------------------"

# Run skaffold build with explicit default-repo and capture debug log
cd "$WEB_DIR" || { echo "web dir missing (expected $WORKDIR/$WEB_DIR)"; exit 1; }

DEFAULT_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_NAME}"
echo "Running: skaffold build --default-repo ${DEFAULT_REPO} ..."
rm -f "$SKAFFOLD_LOG"
set +e
skaffold build --interactive=false --default-repo "${DEFAULT_REPO}" --file-output artifacts.json --verbosity=debug 2>&1 | tee "$SKAFFOLD_LOG"
SKAFFOLD_EXIT=${PIPESTATUS[0]}
set -e

if [ $SKAFFOLD_EXIT -eq 0 ]; then
  echo "Skaffold build succeeded."
  echo "Artifacts written to: $(pwd)/artifacts.json"
  exit 0
fi

echo "Skaffold build FAILED (exit code $SKAFFOLD_EXIT). Collecting diagnostics..."

# Show last 200 lines of skaffold debug log
echo "---- Last 200 lines of $SKAFFOLD_LOG ----"
tail -n 200 "$SKAFFOLD_LOG" || true
echo "------------------------------------------"

# List recent Cloud Build runs for this project to find failures
echo "Listing recent Cloud Build runs (project: $PROJECT_ID):"
gcloud builds list --project "$PROJECT_ID" --limit=10 --sort-by=~create_time --format="table(id,status,createTime,images)" || true

# Try to locate a recent FAILED or CANCELLED build and show details + logs
FAILED_ID=$(gcloud builds list --project "$PROJECT_ID" --limit=20 --sort-by=~create_time --filter="status:FAILURE OR status:CANCELLED" --format="value(id)" | head -n1 || true)
if [ -n "$FAILED_ID" ]; then
  echo "Found failed/cancelled build: $FAILED_ID"
  echo "gcloud builds describe $FAILED_ID --project $PROJECT_ID"
  gcloud builds describe "$FAILED_ID" --project "$PROJECT_ID" || true
  echo "Streaming build logs:"
  gcloud builds log "$FAILED_ID" --project "$PROJECT_ID" --stream || true
else
  echo "No recent FAILED or CANCELLED builds found. Review $SKAFFOLD_LOG for details."
fi

# Check common permission issues in log: search for PERMISSION_DENIED or 403 or 404 signs
if grep -E "PERMISSION_DENIED|403|404|Requested entity was not found|artifactregistry" "$SKAFFOLD_LOG" >/dev/null 2>&1; then
  echo "Detected permissions / not-found related messages in skaffold log. Attempting best-effort IAM fixes (requires Owner privileges)."
  # Allow Cloud Build SA to write to AR and Storage (best-effort)
  CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
  echo "Granting roles: artifactregistry.writer and storage.admin to ${CB_SA} (best-effort)..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${CB_SA}" --role="roles/artifactregistry.writer" --quiet || echo "Could not bind artifactregistry.writer"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${CB_SA}" --role="roles/storage.admin" --quiet || echo "Could not bind storage.admin"
  echo "If IAM changes were applied, re-run this script or re-run the skaffold command."
fi

echo "Diagnostics complete. If you want, paste the failed build id or the last 200 lines of $SKAFFOLD_LOG and I will pinpoint the line and exact fix."
exit 2
