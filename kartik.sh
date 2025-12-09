#!/bin/bash
set -euo pipefail

# Minimal, cleaned Google Cloud deployment setup script
# - Removed branding, YouTube links and promotional text
# - Kept only essential prompts and actions

# Spinner (optional visual feedback)
spinner() {
  local pid=$!
  local delay=0.1
  local spinstr='|/-\\'
  while ps -p "$pid" > /dev/null 2>&1; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# Detect project
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  read -rp "Enter GCP Project ID: " PROJECT_ID
  if [ -z "$PROJECT_ID" ]; then
    echo "Project ID is required. Exiting."
    exit 1
  fi
fi
export PROJECT_ID

# Detect zone
ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null || true)
if [ -z "$ZONE" ]; then
  read -rp "Enter Zone (e.g., us-central1-a): " ZONE
  if [[ ! "$ZONE" =~ ^[a-z0-9]+-[a-z0-9]+-[a-z]$ ]]; then
    echo "Invalid zone format. Expected e.g. us-central1-a. Exiting."
    exit 1
  fi
fi

# Derive region from zone if possible
REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null || true)
if [ -z "$REGION" ]; then
  REGION="${ZONE%-*}"
fi

if [ -z "$REGION" ]; then
  read -rp "Enter Region (e.g., us-central1): " REGION
  if [[ ! "$REGION" =~ ^[a-z0-9]+-[a-z0-9]+$ ]]; then
    echo "Invalid region format. Expected e.g. us-central1. Exiting."
    exit 1
  fi
fi
export REGION

# Project number
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
export PROJECT_NUMBER

# Set defaults
gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null || true

# Enable required APIs
gcloud services enable \
  container.googleapis.com \
  clouddeploy.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com >/dev/null &
spinner

# Grant roles to the default Compute Engine service account
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/clouddeploy.jobRunner" >/dev/null &
spinner

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/container.developer" >/dev/null &
spinner

# Create Artifact Registry (docker)
if ! gcloud artifacts repositories describe cicd-challenge --location="$REGION" >/dev/null 2>&1; then
  gcloud artifacts repositories create cicd-challenge \
    --repository-format=docker \
    --location="$REGION" \
    --description="Image registry for tutorial web app" >/dev/null &
  spinner
fi

# Create GKE clusters (async)
gcloud container clusters create cd-staging --zone="$ZONE" --num-nodes=1 --async >/dev/null &
spinner
gcloud container clusters create cd-production --zone="$ZONE" --num-nodes=1 --async >/dev/null &
spinner

# Clone repository and prepare config
cd ~
if [ ! -d cloud-deploy-tutorials ]; then
  git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git >/dev/null &
  spinner
fi
cd cloud-deploy-tutorials/tutorials/base

# Generate skaffold with project substitution
if [ -f clouddeploy-config/skaffold.yaml.template ]; then
  envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml
  sed -i "s/{{project-id}}/${PROJECT_ID}/g" web/skaffold.yaml || true
fi

# Ensure Cloud Build bucket exists
BUCKET="${PROJECT_ID}_cloudbuild"
if ! gsutil ls "gs://${BUCKET}/" >/dev/null 2>&1; then
  gsutil mb -p "$PROJECT_ID" -l "$REGION" -b on "gs://${BUCKET}/"
fi

# Build artifacts using skaffold
cd web
skaffold build --interactive=false \
  --default-repo "$REGION-docker.pkg.dev/$PROJECT_ID/cicd-challenge" \
  --file-output artifacts.json >/dev/null &
spinner
cd ..

# Prepare and apply delivery pipeline
cp clouddeploy-config/delivery-pipeline.yaml.template clouddeploy-config/delivery-pipeline.yaml
sed -i "s/targetId: staging/targetId: cd-staging/" clouddeploy-config/delivery-pipeline.yaml || true
sed -i "s/targetId: prod/targetId: cd-production/" clouddeploy-config/delivery-pipeline.yaml || true
sed -i "/targetId: test/d" clouddeploy-config/delivery-pipeline.yaml || true

gcloud config set deploy/region "$REGION" >/dev/null
gcloud beta deploy apply --file=clouddeploy-config/delivery-pipeline.yaml >/dev/null &
spinner

# Describe pipeline
gcloud beta deploy delivery-pipelines describe web-app --format="value(name)" >/dev/null &
spinner

# Wait for clusters to be RUNNING
CLUSTERS=("cd-production" "cd-staging")
for cluster in "${CLUSTERS[@]}"; do
  status=$(gcloud container clusters describe "$cluster" --zone "$ZONE" --format="value(status)" 2>/dev/null || true)
  while [ "$status" != "RUNNING" ]; do
    sleep 5
    status=$(gcloud container clusters describe "$cluster" --zone "$ZONE" --format="value(status)" 2>/dev/null || true)
  done
  echo "Cluster $cluster is RUNNING"
done

# Configure kubectl contexts
for ctx in cd-staging cd-production; do
  gcloud container clusters get-credentials "$ctx" --zone "$ZONE" >/dev/null &
  spinner
  kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${ctx}" "$ctx" >/dev/null 2>&1 || true
done

# Apply namespaces
for ctx in cd-staging cd-production; do
  kubectl --context "$ctx" apply -f kubernetes-config/web-app-namespace.yaml >/dev/null &
  spinner
done

# Generate and apply Cloud Deploy targets
envsubst < clouddeploy-config/target-staging.yaml.template > clouddeploy-config/target-cd-staging.yaml || true
envsubst < clouddeploy-config/target-prod.yaml.template > clouddeploy-config/target-cd-production.yaml || true
sed -i "s/staging/cd-staging/" clouddeploy-config/target-cd-staging.yaml || true
sed -i "s/prod/cd-production/" clouddeploy-config/target-cd-production.yaml || true

for ctx in cd-staging cd-production; do
  gcloud beta deploy apply --file clouddeploy-config/target-${ctx}.yaml >/dev/null &
  spinner
done

# Create release
gcloud beta deploy releases create web-app-001 \
  --delivery-pipeline web-app \
  --build-artifacts web/artifacts.json \
  --source web/ >/dev/null &
spinner

# Monitor rollout until SUCCEEDED (polling)
while true; do
  status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --format="value(state)" | head -n1 || true)
  if [ "$status" = "SUCCEEDED" ]; then
    echo "Rollout SUCCEEDED"
    break
  fi
  sleep 10
done

# Promote to next stage
gcloud beta deploy releases promote --delivery-pipeline web-app --release web-app-001 --quiet >/dev/null &
spinner

# Approve and monitor production rollout
# Note: Adjust rollout name if your environment uses a different rollout id
# Attempt to find the pending approval rollout automatically
PENDING_ROLLOUT=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --filter="state= PENDING_APPROVAL" --format="value(name)" | head -n1 || true)
if [ -n "$PENDING_ROLLOUT" ]; then
  gcloud beta deploy rollouts approve "$PENDING_ROLLOUT" --delivery-pipeline web-app --release web-app-001 --quiet >/dev/null &
  spinner
fi

# Final message
echo "Script completed. Check GCP Console or use gcloud to inspect resources."
