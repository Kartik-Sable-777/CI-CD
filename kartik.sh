#!/usr/bin/env bash
# kartik.sh - Final robust Google Cloud Deploy bootstrap & build script
# - Use on Linux/Cloud Shell/macOS (portable sed considered)
set -euo pipefail

### Config (adjust if needed)
CLUSTER_WAIT_TIMEOUT=1800    # seconds per cluster (30m)
ROLLOUT_WAIT_TIMEOUT=1800    # seconds for rollout to succeed (30m)
POLL_INTERVAL=5              # seconds between polls
SKAFFOLD_RETRIES=1           # how many times to retry skaffold build on transient failures

### Portable inplace sed helper (GNU / BSD / BusyBox)
inplace_sed() {
  local expr="$1" file="$2"
  if sed --version >/dev/null 2>&1 && sed --version 2>&1 | grep -qi 'gnu'; then
    sed -i "$expr" "$file"
    return $?
  fi
  if sed -i '' '1!d' "$file" >/dev/null 2>&1; then
    sed -i '' "$expr" "$file"
    return $?
  fi
  if sed -i "$expr" "$file" >/dev/null 2>&1; then
    return $?
  fi
  printf "inplace_sed: unable to run sed safely on this system\n" >&2
  return 1
}

### Preflight
REQUIRED_CMDS=(gcloud kubectl gsutil git skaffold envsubst sed awk sleep date bash)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf "Required command '%s' not found. Install it and retry.\n" "$cmd" >&2
    exit 1
  fi
done

### Spinner
spinner() {
  local pid="${1:-}"
  local delay=0.12
  local spinstr='|/-\\'
  [ -z "$pid" ] && return 0
  printf " "
  while kill -0 "$pid" 2>/dev/null; do
    for i in $(seq 0 $((${#spinstr} - 1))); do
      printf "\b%c" "${spinstr:i:1}"
      sleep "$delay"
    done
  done
  printf "\b \n"
}

run_bg() {
  local cmd="$1"
  bash -c "$cmd" &
  local pid=$!
  spinner "$pid"
  wait "$pid"
  return $?
}

### Helper: print and run (synchronous)
run_cmd() {
  local desc="$1" cmd="$2"
  printf "==> %s\n" "$desc"
  if ! bash -c "$cmd"; then
    printf "Command failed: %s\n" "$cmd" >&2
    return 1
  fi
  return 0
}

### Detect project/zone/region
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  read -rp "Enter GCP Project ID: " PROJECT_ID
  [ -z "$PROJECT_ID" ] && { echo "Project ID required."; exit 1; }
fi
export PROJECT_ID

ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null || true)
if [ -z "$ZONE" ]; then
  read -rp "Enter Zone (e.g., us-central1-a): " ZONE
  [ -z "$ZONE" ] && { echo "Zone required."; exit 1; }
fi

REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null || true)
if [ -z "$REGION" ]; then
  REGION="${ZONE%-*}"
fi
if [ -z "$REGION" ]; then
  read -rp "Enter Region (e.g., us-central1): " REGION
  [ -z "$REGION" ] && { echo "Region required."; exit 1; }
fi
export ZONE REGION

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)
if [ -z "$PROJECT_NUMBER" ]; then
  echo "Unable to fetch project number for $PROJECT_ID. Ensure you have access and the project exists." >&2
  exit 1
fi
export PROJECT_NUMBER

printf "Using Project: %s (Number: %s)\nUsing Zone: %s  Region: %s\n" "$PROJECT_ID" "$PROJECT_NUMBER" "$ZONE" "$REGION"

# set defaults
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set compute/region "$REGION" >/dev/null || true
gcloud config set compute/zone "$ZONE" >/dev/null || true

### Ensure required APIs enabled
echo "Ensuring required APIs are enabled..."
run_bg "gcloud services enable container.googleapis.com clouddeploy.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com --project \"$PROJECT_ID\"" || { echo "Enable APIs failed"; exit 1; }

### Grant roles to SA (best-effort; requires Owner)
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "Granting roles to Cloud Build service account and Compute default service account (requires Owner/equivalent)..."
# Cloud Build SA storage admin to push sources (needed in some setups)
run_bg "gcloud projects add-iam-policy-binding \"$PROJECT_ID\" --member=\"serviceAccount:${CLOUDBUILD_SA}\" --role=\"roles/storage.admin\" --quiet" || echo "Warning: Could not bind storage.admin to Cloud Build SA"
# Compute default SA roles needed
run_bg "gcloud projects add-iam-policy-binding \"$PROJECT_ID\" --member=\"serviceAccount:${COMPUTE_SA}\" --role=\"roles/clouddeploy.jobRunner\" --quiet" || echo "Warning: could not bind clouddeploy.jobRunner to compute SA"
run_bg "gcloud projects add-iam-policy-binding \"$PROJECT_ID\" --member=\"serviceAccount:${COMPUTE_SA}\" --role=\"roles/container.developer\" --quiet" || echo "Warning: could not bind container.developer to compute SA"

### Artifact Registry - ensure exists in REGION
AR_NAME="cicd-challenge"
if ! gcloud artifacts repositories describe "$AR_NAME" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Creating Artifact Registry '$AR_NAME' in region $REGION..."
  run_bg "gcloud artifacts repositories create \"$AR_NAME\" --repository-format=docker --location=\"$REGION\" --description='Image registry for CI/CD' --project=\"$PROJECT_ID\" --quiet" || { echo "Failed to create Artifact Registry"; exit 1; }
else
  echo "Artifact Registry '$AR_NAME' already exists in $REGION."
fi

### Create GKE clusters (async) and wait
create_cluster_and_wait() {
  local name="$1" timeout="$2" start now elapsed
  start=$(date +%s)
  if gcloud container clusters describe "$name" --zone "$ZONE" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Cluster $name already exists."
  else
    echo "Creating cluster $name (zone $ZONE) async..."
    run_bg "gcloud container clusters create \"$name\" --zone=\"$ZONE\" --num-nodes=1 --project=\"$PROJECT_ID\" --quiet --async" || { echo "Failed to initiate cluster creation for $name"; return 1; }
  fi
  echo "Waiting for cluster $name to become RUNNING..."
  while :; do
    if gcloud container clusters describe "$name" --zone "$ZONE" --format="value(status)" --project "$PROJECT_ID" 2>/dev/null | grep -q "RUNNING"; then
      echo "Cluster $name is RUNNING."
      return 0
    fi
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timed out waiting for cluster $name (waited ${elapsed}s)." >&2
      return 2
    fi
    sleep "$POLL_INTERVAL"
  done
}

create_cluster_and_wait "cd-staging" "$CLUSTER_WAIT_TIMEOUT" || { echo "cd-staging failed"; exit 1; }
create_cluster_and_wait "cd-production" "$CLUSTER_WAIT_TIMEOUT" || { echo "cd-production failed"; exit 1; }

### Repo: clone tutorials if missing and prepare skaffold
WORKDIR="$HOME/cloud-deploy-tutorials"
if [ ! -d "$WORKDIR" ]; then
  echo "Cloning cloud-deploy-tutorials..."
  run_bg "git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git \"$WORKDIR\"" || { echo "Clone failed"; exit 1; }
fi
cd "$WORKDIR/tutorials/base" || { echo "Expected path $WORKDIR/tutorials/base not found"; exit 1; }

# Generate skaffold.yaml if template exists
if [ -f clouddeploy-config/skaffold.yaml.template ]; then
  echo "Generating web/skaffold.yaml from template..."
  envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml
  # ensure project id substituted
  inplace_sed "s/{{project-id}}/${PROJECT_ID}/g" web/skaffold.yaml || true
fi

### Ensure Cloud Build bucket exists
BUCKET="${PROJECT_ID}_cloudbuild"
if ! gsutil ls "gs://${BUCKET}/" >/dev/null 2>&1; then
  echo "Creating Cloud Build bucket gs://${BUCKET} in region ${REGION}..."
  run_bg "gsutil mb -p \"$PROJECT_ID\" -l \"$REGION\" -b on \"gs://${BUCKET}/\"" || { echo "Bucket creation failed"; exit 1; }
else
  echo "Bucket gs://${BUCKET} exists."
fi

### Build with skaffold (with retry and detailed failure handling)
cd web || { echo "web directory missing"; exit 1; }

SKAFFOLD_DEFAULT_REPO="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_NAME"
echo "Using Skaffold default repo: $SKAFFOLD_DEFAULT_REPO"

attempt=0
build_failed=0
while [ $attempt -le $SKAFFOLD_RETRIES ]; do
  attempt=$((attempt+1))
  echo "Skaffold build attempt #$attempt..."
  # Run skaffold and capture output; if it fails, try to extract build id(s)
  if skaffold build --interactive=false --default-repo "$SKAFFOLD_DEFAULT_REPO" --file-output artifacts.json; then
    echo "Skaffold build succeeded."
    build_failed=0
    break
  else
    echo "Skaffold build failed on attempt #$attempt."
    build_failed=1
    # try to find last failing Cloud Build id(s)
    echo "Listing recent Cloud Build entries to provide diagnostics..."
    gcloud builds list --project "$PROJECT_ID" --limit=5 --sort-by=~create_time || true
    # exit loop or retry depending on setting
    if [ $attempt -le $SKAFFOLD_RETRIES ]; then
      echo "Retrying skaffold build after a short sleep..."
      sleep 5
    fi
  fi
done

if [ "$build_failed" -ne 0 ]; then
  echo "Skaffold build failed after $attempt attempt(s)."
  echo "To inspect the failing Cloud Build, run:"
  echo "  gcloud builds list --project $PROJECT_ID --limit=10 --sort-by=~create_time"
  echo "  gcloud builds describe <BUILD_ID> --project $PROJECT_ID"
  exit 1
fi
cd ..

### Prepare delivery pipeline and targets
if [ -f clouddeploy-config/delivery-pipeline.yaml.template ]; then
  cp clouddeploy-config/delivery-pipeline.yaml.template clouddeploy-config/delivery-pipeline.yaml
  inplace_sed "s/targetId: staging/targetId: cd-staging/" clouddeploy-config/delivery-pipeline.yaml || true
  inplace_sed "s/targetId: prod/targetId: cd-production/" clouddeploy-config/delivery-pipeline.yaml || true
  inplace_sed "/targetId: test/d" clouddeploy-config/delivery-pipeline.yaml || true
else
  echo "Missing delivery pipeline template" >&2
  exit 1
fi

gcloud config set deploy/region "$REGION" >/dev/null || true
echo "Applying delivery pipeline..."
run_bg "gcloud beta deploy apply --file=clouddeploy-config/delivery-pipeline.yaml --project \"$PROJECT_ID\"" || { echo "gcloud deploy apply failed"; exit 1; }

### Configure kubectl contexts & apply namespaces
for ctx in cd-staging cd-production; do
  echo "Getting credentials for $ctx..."
  run_bg "gcloud container clusters get-credentials \"$ctx\" --zone \"$ZONE\" --project \"$PROJECT_ID\"" || { echo "Get credentials failed for $ctx"; exit 1; }
  kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${ctx}" "$ctx" >/dev/null 2>&1 || true
  if [ -f kubernetes-config/web-app-namespace.yaml ]; then
    kubectl --context "$ctx" apply -f kubernetes-config/web-app-namespace.yaml || { echo "Failed to apply namespace on $ctx"; exit 1; }
  fi
done

### Apply Cloud Deploy targets (if templates exist)
if [ -f clouddeploy-config/target-staging.yaml.template ]; then
  envsubst < clouddeploy-config/target-staging.yaml.template > clouddeploy-config/target-cd-staging.yaml || true
  envsubst < clouddeploy-config/target-prod.yaml.template > clouddeploy-config/target-cd-production.yaml || true
  inplace_sed "s/staging/cd-staging/" clouddeploy-config/target-cd-staging.yaml || true
  inplace_sed "s/prod/cd-production/" clouddeploy-config/target-cd-production.yaml || true
fi

for ctx in cd-staging cd-production; do
  target_file="clouddeploy-config/target-${ctx}.yaml"
  if [ -f "$target_file" ]; then
    echo "Applying target $target_file..."
    run_bg "gcloud beta deploy apply --file \"$target_file\" --project \"$PROJECT_ID\"" || echo "Warning: apply failed for $target_file"
  fi
done

### Create release and monitor rollout (best-effort)
echo "Creating release web-app-001..."
run_bg "gcloud beta deploy releases create web-app-001 --delivery-pipeline web-app --build-artifacts web/artifacts.json --source web/ --project \"$PROJECT_ID\"" || echo "Warning: release creation may have failed or partially succeeded"

echo "Waiting for rollout to reach SUCCEEDED (timeout ${ROLLOUT_WAIT_TIMEOUT}s)..."
start_ts=$(date +%s)
while :; do
  status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --project "$PROJECT_ID" --format="value(state)" 2>/dev/null | head -n1 || true)
  now_ts=$(date +%s)
  elapsed=$((now_ts - start_ts))
  if [ "$status" = "SUCCEEDED" ]; then
    echo "Rollout SUCCEEDED"
    break
  fi
  if [ "$elapsed" -ge "$ROLLOUT_WAIT_TIMEOUT" ]; then
    echo "Timeout waiting for rollout (waited ${elapsed}s)." >&2
    break
  fi
  sleep "$POLL_INTERVAL"
done

echo "Attempting to promote release (best-effort)..."
run_bg "gcloud beta deploy releases promote --delivery-pipeline web-app --release web-app-001 --project \"$PROJECT_ID\" --quiet" || echo "Promotion may have failed or requires manual approval"

PENDING_ROLLOUT=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --project "$PROJECT_ID" --filter="state= PENDING_APPROVAL" --format="value(name)" 2>/dev/null | head -n1 || true)
if [ -n "$PENDING_ROLLOUT" ]; then
  echo "Found pending approval rollout $PENDING_ROLLOUT — attempting to auto-approve..."
  run_bg "gcloud beta deploy rollouts approve \"$PENDING_ROLLOUT\" --delivery-pipeline web-app --release web-app-001 --project \"$PROJECT_ID\" --quiet" || echo "Auto-approval failed; manual approval may be required in Cloud Console"
fi

final_status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --project "$PROJECT_ID" --format="value(state)" 2>/dev/null | head -n1 || true)
echo "Final rollout state: ${final_status:-UNKNOWN}"
echo "Done. Inspect resources in Cloud Console or with gcloud commands (eg. gcloud builds list / gcloud container clusters list)"
