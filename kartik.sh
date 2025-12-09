#!/usr/bin/env bash
# kartik.sh - final fixed script for the Cloud Deploy tutorial flow
set -euo pipefail

# Config (change REGION/ZONE if you want)
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
AR_REPO="${AR_REPO:-cicd-challenge}"
WORKDIR="${HOME}/cloud-deploy-tutorials/tutorials/base"
SKAFFOLD_LOG="${HOME}/skaffold-debug.log"
SKAFFOLD_TIMEOUT=1800

# Ensure required CLIs present
for cmd in gcloud gsutil git skaffold envsubst sed kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found. Run in Cloud Shell or install it." >&2
    exit 1
  fi
done

# Ensure gcloud project set and export PROJECT_ID
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  echo "No gcloud project set. Run: gcloud config set project <PROJECT_ID>" >&2
  exit 1
fi
export PROJECT_ID
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)
echo "Using PROJECT_ID=${PROJECT_ID}, PROJECT_NUMBER=${PROJECT_NUMBER}, REGION=${REGION}, ZONE=${ZONE}"

# Enable APIs (best-effort)
echo "Enabling required APIs..."
gcloud services enable container.googleapis.com clouddeploy.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com --project "$PROJECT_ID" >/dev/null

# Ensure Artifact Registry exists
if ! gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Creating Artifact Registry '$AR_REPO' in $REGION..."
  gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" --description="CI/CD repo" --project "$PROJECT_ID" --quiet
else
  echo "Artifact Registry $AR_REPO already exists in $REGION."
fi

# Ensure Cloud Build bucket exists
CB_BUCKET="${PROJECT_ID}_cloudbuild"
if ! gsutil ls "gs://${CB_BUCKET}/" >/dev/null 2>&1; then
  echo "Creating Cloud Build bucket gs://${CB_BUCKET}..."
  gsutil mb -p "$PROJECT_ID" -l "$REGION" -b on "gs://${CB_BUCKET}/"
else
  echo "Cloud Build bucket gs://${CB_BUCKET} exists."
fi

# Prepare workspace and skaffold.yaml
if [ ! -d "$WORKDIR" ]; then
  echo "Cloning cloud-deploy-tutorials into $WORKDIR..."
  rm -rf "$HOME/cloud-deploy-tutorials" || true
  git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git "$HOME/cloud-deploy-tutorials"
fi
cd "$WORKDIR" || { echo "ERROR: expected $WORKDIR"; exit 1; }

TEMPLATE="clouddeploy-config/skaffold.yaml.template"
mkdir -p web
if [ -f "$TEMPLATE" ]; then
  echo "Generating web/skaffold.yaml from template..."
  envsubst < "$TEMPLATE" > web/skaffold.yaml
  sed -i "s/{{project-id}}/${PROJECT_ID}/g" web/skaffold.yaml || true
else
  echo "Template not found, creating fallback web/skaffold.yaml..."
  cat > web/skaffold.yaml <<EOF
apiVersion: skaffold/v2beta26
kind: Config
metadata:
  name: leeroy
build:
  artifacts:
  - image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/leeroy-web
    context: .
    docker:
      dockerfile: Dockerfile-web
  - image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/leeroy-app
    context: .
    docker:
      dockerfile: Dockerfile-app
deploy:
  kubectl:
    manifests:
      - k8s-*
EOF
fi

# Run skaffold build with explicit default repo and debug log
cd web || { echo "web dir missing"; exit 1; }
DEFAULT_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}"
echo "Running skaffold build -> default repo: ${DEFAULT_REPO}"
rm -f "$SKAFFOLD_LOG"
set +e
skaffold build --interactive=false --default-repo "${DEFAULT_REPO}" --file-output artifacts.json --verbosity=debug 2>&1 | tee "$SKAFFOLD_LOG"
SKAFFOLD_EXIT=${PIPESTATUS[0]}
set -e

if [ "$SKAFFOLD_EXIT" -eq 0 ]; then
  echo "Skaffold build succeeded. artifacts.json created."
else
  echo "Skaffold build FAILED (exit $SKAFFOLD_EXIT). Showing diagnostics..."
  echo "---- last 200 lines of skaffold debug log ----"
  tail -n 200 "$SKAFFOLD_LOG" || true
  echo "----------------------------------------------"

  # Attempt to find FAILED/CANCELLED Cloud Build and show describe+logs
  FAILED_ID=$(gcloud builds list --project "$PROJECT_ID" --limit=20 --filter="status:FAILURE OR status:CANCELLED" --sort-by=~create_time --format="value(id)" | head -n1 || true)
  if [ -n "$FAILED_ID" ]; then
    echo "Found recent failed/cancelled build id: $FAILED_ID"
    echo "=== gcloud builds describe $FAILED_ID ==="
    gcloud builds describe "$FAILED_ID" --project "$PROJECT_ID" || true
    echo "=== tail of build logs ==="
    gcloud builds log "$FAILED_ID" --project "$PROJECT_ID" --stream || true
  else
    echo "No recent FAILED/CANCELLED builds found. Inspect $SKAFFOLD_LOG for details."
  fi

  # Best-effort IAM fixes if logs indicate permission issues
  if grep -E "PERMISSION_DENIED|403|403 Forbidden|Requested entity was not found|artifactregistry" "$SKAFFOLD_LOG" >/dev/null 2>&1; then
    echo "Detected permission/404 text in skaffold log — applying best-effort IAM bindings for Cloud Build SA..."
    CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${CB_SA}" --role="roles/artifactregistry.writer" --quiet || echo "Could not bind artifactregistry.writer"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${CB_SA}" --role="roles/storage.admin" --quiet || echo "Could not bind storage.admin"
    echo "If IAM was updated, re-run this script or the skaffold command."
  fi

  exit 2
fi

# Continue: prepare delivery pipeline and targets, create clusters, apply targets, create release
cd "$WORKDIR" || exit 1

# delivery pipeline
cp clouddeploy-config/delivery-pipeline.yaml.template clouddeploy-config/delivery-pipeline.yaml
sed -i "s/targetId: staging/targetId: cd-staging/" clouddeploy-config/delivery-pipeline.yaml || true
sed -i "s/targetId: prod/targetId: cd-production/" clouddeploy-config/delivery-pipeline.yaml || true
sed -i "/targetId: test/d" clouddeploy-config/delivery-pipeline.yaml || true

gcloud config set deploy/region "$REGION" >/dev/null || true
echo "Applying delivery pipeline..."
gcloud beta deploy apply --file=clouddeploy-config/delivery-pipeline.yaml --project "$PROJECT_ID" || echo "Warning: apply may have partial results"

# Create clusters async & wait minimally
echo "Creating GKE clusters (async)..."
gcloud container clusters create cd-staging --zone="$ZONE" --num-nodes=1 --project "$PROJECT_ID" --quiet --async || true
gcloud container clusters create cd-production --zone="$ZONE" --num-nodes=1 --project "$PROJECT_ID" --quiet --async || true

# Wait for clusters to be RUNNING (with timeout)
SECONDS_WAIT=0
TIMEOUT=1200
while true; do
  READY_COUNT=0
  for C in cd-staging cd-production; do
    STATUS=$(gcloud container clusters describe "$C" --zone="$ZONE" --project "$PROJECT_ID" --format="value(status)" 2>/dev/null || echo "UNKNOWN")
    if [ "$STATUS" = "RUNNING" ]; then READY_COUNT=$((READY_COUNT+1)); fi
  done
  if [ "$READY_COUNT" -eq 2 ]; then break; fi
  if [ "$SECONDS_WAIT" -ge "$TIMEOUT" ]; then
    echo "Timeout waiting for clusters. Proceeding — you may need to wait longer manually." ; break
  fi
  sleep 10
  SECONDS_WAIT=$((SECONDS_WAIT+10))
done

# Configure kubectl contexts and namespaces
for CTX in cd-staging cd-production; do
  gcloud container clusters get-credentials "$CTX" --zone="$ZONE" --project "$PROJECT_ID" || true
  kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${CTX}" "$CTX" >/dev/null 2>&1 || true
  if [ -f kubernetes-config/web-app-namespace.yaml ]; then
    kubectl --context "$CTX" apply -f kubernetes-config/web-app-namespace.yaml || true
  fi
done

# Targets (generate/apply)
if [ -f clouddeploy-config/target-staging.yaml.template ]; then
  envsubst < clouddeploy-config/target-staging.yaml.template > clouddeploy-config/target-cd-staging.yaml || true
  envsubst < clouddeploy-config/target-prod.yaml.template > clouddeploy-config/target-cd-production.yaml || true
  sed -i "s/staging/cd-staging/" clouddeploy-config/target-cd-staging.yaml || true
  sed -i "s/prod/cd-production/" clouddeploy-config/target-cd-production.yaml || true
fi

for T in cd-staging cd-production; do
  TF="clouddeploy-config/target-${T}.yaml"
  if [ -f "$TF" ]; then
    gcloud beta deploy apply --file "$TF" --project "$PROJECT_ID" || true
  fi
done

# Release
echo "Creating release web-app-001..."
gcloud beta deploy releases create web-app-001 --delivery-pipeline web-app --build-artifacts web/artifacts.json --source web/ --project "$PROJECT_ID" || echo "Release creation may have partial/queued status"

echo "Done. Inspect: gcloud builds list, gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001"
