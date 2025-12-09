#!/usr/bin/env bash
# kartik.sh - Minimal, robust Google Cloud Deploy bootstrap script (portable)
set -euo pipefail

### Configuration (adjust if needed)
CLUSTER_WAIT_TIMEOUT=1800    # seconds per cluster (30m)
ROLLOUT_WAIT_TIMEOUT=1800    # seconds for rollout to succeed (30m)
POLL_INTERVAL=5              # seconds between polls

### Portable inplace sed helper
inplace_sed() {
  local expr="$1" file="$2"
  # Use GNU sed if available, else macOS/BSD sed style
  if sed --version >/dev/null 2>&1; then
    sed -i "$expr" "$file"
  else
    sed -i '' "$expr" "$file"
  fi
}

### Preflight: required commands
REQUIRED_CMDS=(gcloud kubectl gsutil git skaffold envsubst sed awk sleep date)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf "Required command '%s' not found. Install it and retry.\n" "$cmd" >&2
    exit 1
  fi
done

### Spinner that accepts a PID
spinner() {
  local pid="${1:-}"
  local delay=0.12
  local spinstr='|/-\\'
  if [ -z "$pid" ]; then
    return 0
  fi
  printf " "
  while kill -0 "$pid" 2>/dev/null; do
    for i in $(seq 0 $((${#spinstr} - 1))); do
      printf "\b%c" "${spinstr:i:1}"
      sleep "$delay"
    done
  done
  printf "\b \n"
}

# Run a command in background and spinner it, returning the exit code
run_bg() {
  local cmd="$1"
  bash -c "$cmd" &
  local pid=$!
  spinner "$pid"
  wait "$pid"
  return $?
}

### Detect project / zone / region
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  read -rp "Enter GCP Project ID: " PROJECT_ID
  if [ -z "$PROJECT_ID" ]; then
    echo "Project ID is required. Exiting." >&2
    exit 1
  fi
fi
export PROJECT_ID

# Zone detection
ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null || true)
if [ -z "$ZONE" ]; then
  read -rp "Enter Zone (e.g., us-central1-a): " ZONE
  if [ -z "$ZONE" ]; then
    echo "Zone is required. Exiting." >&2
    exit 1
  fi
fi

# Region detection (derive from zone if possible)
REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null || true)
if [ -z "$REGION" ]; then
  REGION="${ZONE%-*}"
fi
if [ -z "$REGION" ]; then
  read -rp "Enter Region (e.g., us-central1): " REGION
  if [ -z "$REGION" ]; then
    echo "Region is required. Exiting." >&2
    exit 1
  fi
fi

export ZONE REGION

# Project number
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)
if [ -z "$PROJECT_NUMBER" ]; then
  echo "Unable to fetch project number for $PROJECT_ID. Ensure you have access and the project exists." >&2
  exit 1
fi
export PROJECT_NUMBER

printf "Using Project: %s  (Number: %s)\n" "$PROJECT_ID" "$PROJECT_NUMBER"
printf "Using Zone: %s  Region: %s\n" "$ZONE" "$REGION"

# Set gcloud defaults
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set compute/region "$REGION" >/dev/null || true
gcloud config set compute/zone "$ZONE" >/dev/null || true

### Enable required APIs
echo "Enabling required APIs..."
run_bg "gcloud services enable container.googleapis.com clouddeploy.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com" || {
  echo "Failed to enable required APIs." >&2
  exit 1
}

### Grant roles to default Compute Engine SA
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "Binding roles to service account $SA (requires Owner or equivalent)..."
run_bg "gcloud projects add-iam-policy-binding \"$PROJECT_ID\" --member=\"serviceAccount:${SA}\" --role=\"roles/clouddeploy.jobRunner\" --quiet" || {
  echo "Failed to bind clouddeploy.jobRunner role. Check permissions." >&2
  exit 1
}
run_bg "gcloud projects add-iam-policy-binding \"$PROJECT_ID\" --member=\"serviceAccount:${SA}\" --role=\"roles/container.developer\" --quiet" || {
  echo "Failed to bind container.developer role. Check permissions." >&2
  exit 1
}

### Create Artifact Registry (if missing)
if ! gcloud artifacts repositories describe cicd-challenge --location="$REGION" >/dev/null 2>&1; then
  echo "Creating Artifact Registry 'cicd-challenge' in $REGION..."
  run_bg "gcloud artifacts repositories create cicd-challenge --repository-format=docker --location=\"$REGION\" --description='Image registry for CI/CD' --quiet" || {
    echo "Failed to create artifact registry." >&2
    exit 1
  }
else
  echo "Artifact Registry 'cicd-challenge' exists."
fi

### Create GKE clusters and wait until RUNNING
create_cluster_and_wait() {
  local name="$1" timeout="$2" start now elapsed
  start=$(date +%s)
  echo "Ensuring cluster $name exists (zone: $ZONE)..."
  if gcloud container clusters describe "$name" --zone "$ZONE" >/dev/null 2>&1; then
    echo "Cluster $name already exists."
  else
    run_bg "gcloud container clusters create \"$name\" --zone=\"$ZONE\" --num-nodes=1 --quiet --async" || {
      echo "Failed to start creation of $name" >&2
      return 1
    }
  fi

  echo "Waiting for cluster $name to become RUNNING (timeout ${timeout}s)..."
  while :; do
    if gcloud container clusters describe "$name" --zone "$ZONE" --format="value(status)" 2>/dev/null | grep -q "RUNNING"; then
      echo "Cluster $name is RUNNING."
      return 0
    fi
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "Timeout waiting for $name (waited ${elapsed}s)." >&2
      return 2
    fi
    sleep "$POLL_INTERVAL"
  done
}

create_cluster_and_wait "cd-staging" "$CLUSTER_WAIT_TIMEOUT" || { echo "cd-staging failed"; exit 1; }
create_cluster_and_wait "cd-production" "$CLUSTER_WAIT_TIMEOUT" || { echo "cd-production failed"; exit 1; }

### Prepare repository and skaffold
WORKDIR="$HOME/cloud-deploy-tutorials"
if [ ! -d "$WORKDIR" ]; then
  echo "Cloning Google Cloud Deploy tutorials..."
  run_bg "git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git \"$WORKDIR\"" || { echo "Failed clone"; exit 1; }
fi
cd "$WORKDIR/tutorials/base" || { echo "Expected tutorials/base not found"; exit 1; }

if [ -f clouddeploy-config/skaffold.yaml.template ]; then
  echo "Generating web/skaffold.yaml..."
  envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml
  inplace_sed "s/{{project-id}}/${PROJECT_ID}/g" web/skaffold.yaml
fi

### Ensure Cloud Build bucket
BUCKET="${PROJECT_ID}_cloudbuild"
if ! gsutil ls "gs://${BUCKET}/" >/dev/null 2>&1; then
  echo "Creating Cloud Build bucket gs://${BUCKET}..."
  run_bg "gsutil mb -p \"$PROJECT_ID\" -l \"$REGION\" -b on \"gs://${BUCKET}/\"" || { echo "Bucket creation failed"; exit 1; }
else
  echo "Bucket gs://${BUCKET} already exists."
fi

### Build with Skaffold
cd web || { echo "web dir missing"; exit 1; }
echo "Running skaffold build..."
run_bg "skaffold build --interactive=false --default-repo \"$REGION-docker.pkg.dev/$PROJECT_ID/cicd-challenge\" --file-output artifacts.json" || { echo "Skaffold build failed"; exit 1; }
cd ..

### Delivery pipeline
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
run_bg "gcloud beta deploy apply --file=clouddeploy-config/delivery-pipeline.yaml" || { echo "Apply failed"; exit 1; }

### Kubectl contexts & namespace
for ctx in cd-staging cd-production; do
  echo "Getting credentials for $ctx..."
  run_bg "gcloud container clusters get-credentials \"$ctx\" --zone \"$ZONE\"" || { echo "Get credentials failed for $ctx"; exit 1; }
  kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${ctx}" "$ctx" >/dev/null 2>&1 || true
  if [ -f kubernetes-config/web-app-namespace.yaml ]; then
    kubectl --context "$ctx" apply -f kubernetes-config/web-app-namespace.yaml || { echo "Failed to apply namespace on $ctx"; exit 1; }
  fi
done

### Targets
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
    run_bg "gcloud beta deploy apply --file \"$target_file\"" || { echo "Failed apply for $target_file"; }
  fi
done

### Release and rollout
echo "Creating release web-app-001..."
run_bg "gcloud beta deploy releases create web-app-001 --delivery-pipeline web-app --build-artifacts web/artifacts.json --source web/" || echo "Release create may have partially failed"

echo "Waiting for rollout SUCCEEDED (timeout ${ROLLOUT_WAIT_TIMEOUT}s)..."
start_ts=$(date +%s)
while :; do
  status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --format="value(state)" 2>/dev/null | head -n1 || true)
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
run_bg "gcloud beta deploy releases promote --delivery-pipeline web-app --release web-app-001 --quiet" || echo "Promotion may require manual approval or failed"

PENDING_ROLLOUT=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --filter="state= PENDING_APPROVAL" --format="value(name)" 2>/dev/null | head -n1 || true)
if [ -n "$PENDING_ROLLOUT" ]; then
  echo "Attempting to approve pending rollout $PENDING_ROLLOUT..."
  run_bg "gcloud beta deploy rollouts approve \"$PENDING_ROLLOUT\" --delivery-pipeline web-app --release web-app-001 --quiet" || echo "Auto-approval failed or requires manual action"
fi

final_status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --format="value(state)" 2>/dev/null | head -n1 || true)
echo "Final rollout state: ${final_status:-UNKNOWN}"
echo "Script finished. Inspect resources in Cloud Console or with gcloud."
