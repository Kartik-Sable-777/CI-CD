#!/bin/bash
set -euo pipefail

# -----------------------------
# BASIC SETUP
# -----------------------------
echo "🔧 Initializing environment..."

PROJECT_ID=$(gcloud config get-value project)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  echo "❌ ERROR: No gcloud project is set. Run: gcloud config set project <PROJECT_ID>"
  exit 1
fi

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
REGION="us-central1"
ZONE="us-central1-a"
AR_REPO="cicd-challenge"
CB_BUCKET="${PROJECT_ID}_cloudbuild"

echo "PROJECT_ID: $PROJECT_ID"
echo "PROJECT_NUMBER: $PROJECT_NUMBER"
echo "REGION: $REGION"
echo "ZONE: $ZONE"


# -----------------------------
# ENABLE REQUIRED SERVICES
# -----------------------------
echo "⚙️ Enabling required Google Cloud services..."

gcloud services enable \
  container.googleapis.com \
  clouddeploy.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com


# -----------------------------
# CREATE ARTIFACT REGISTRY
# -----------------------------
echo "📦 Checking Artifact Registry..."

if ! gcloud artifacts repositories describe "$AR_REPO" \
  --location="$REGION" >/dev/null 2>&1; then

  echo "📦 Creating Artifact Registry: $AR_REPO"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="CI/CD challenge repo"
else
  echo "✔️ Artifact Registry exists."
fi


# -----------------------------
# CHECK / CREATE CLOUD BUILD BUCKET
# -----------------------------
echo "🪣 Checking Cloud Build bucket gs://$CB_BUCKET/..."

if ! gsutil ls "gs://$CB_BUCKET/" >/dev/null 2>&1; then
  echo "🪣 Creating Cloud Build bucket..."
  gsutil mb -p "$PROJECT_ID" -l "$REGION" -b on "gs://$CB_BUCKET/"
else
  echo "✔️ Cloud Build bucket exists."
fi


# -----------------------------
# CLONE LAB REPO
# -----------------------------
echo "📥 Cloning cloud-deploy-tutorials repository..."

cd ~/
rm -rf cloud-deploy-tutorials
git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git

cd cloud-deploy-tutorials/tutorials/base


# -----------------------------
# GENERATE SKAFFOLD FILE
# -----------------------------
echo "📝 Generating skaffold.yaml..."

envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml
sed -i "s/{{project-id}}/$PROJECT_ID/g" web/skaffold.yaml


# -----------------------------
# BUILD WITH SKAFFOLD
# -----------------------------
echo "🏗️ Running skaffold build..."

cd web

skaffold build \
  --interactive=false \
  --default-repo "$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO" \
  --file-output artifacts.json


# -----------------------------
# SETUP DELIVERY PIPELINE
# -----------------------------
echo "🚀 Setting up Cloud Deploy pipeline..."

cd ..

cp clouddeploy-config/delivery-pipeline.yaml.template clouddeploy-config/delivery-pipeline.yaml
sed -i "s/targetId: staging/targetId: cd-staging/" clouddeploy-config/delivery-pipeline.yaml
sed -i "s/targetId: prod/targetId: cd-production/" clouddeploy-config/delivery-pipeline.yaml
sed -i "/targetId: test/d" clouddeploy-config/delivery-pipeline.yaml

gcloud deploy apply --file=clouddeploy-config/delivery-pipeline.yaml --region=$REGION


# -----------------------------
# CREATE CLUSTERS
# -----------------------------
echo "☸️ Creating GKE clusters..."

gcloud container clusters create cd-staging --zone=$ZONE --num-nodes=1 --async
gcloud container clusters create cd-production --zone=$ZONE --num-nodes=1 --async

echo "Waiting for clusters to be ready... (may take 5–7 minutes)"

for CLUSTER in cd-staging cd-production; do
  echo "🔎 Checking $CLUSTER..."
  while true; do
    STATUS=$(gcloud container clusters describe "$CLUSTER" --zone=$ZONE --format="value(status)" || echo "CREATING")
    if [[ "$STATUS" == "RUNNING" ]]; then
      echo "✔️ $CLUSTER is running."
      break
    fi
    echo "⏳ $CLUSTER status: $STATUS ... retrying in 15 sec"
    sleep 15
  done
done


# -----------------------------
# CONFIGURE KUBECTL CONTEXT
# -----------------------------
echo "🔧 Configuring kubectl contexts..."

for CTX in cd-staging cd-production; do
  gcloud container clusters get-credentials "$CTX" --zone=$ZONE
  kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${CTX}" "$CTX"
  kubectl --context "$CTX" apply -f kubernetes-config/web-app-namespace.yaml
done


# -----------------------------
# APPLY TARGETS
# -----------------------------
echo "🎯 Applying Cloud Deploy targets..."

for TARGET in cd-staging cd-production; do
  envsubst < clouddeploy-config/target-${TARGET/ cd-/}.yaml.template > clouddeploy-config/target-$TARGET.yaml
  sed -i "s/staging/cd-staging/g" clouddeploy-config/target-$TARGET.yaml
  sed -i "s/prod/cd-production/g" clouddeploy-config/target-$TARGET.yaml
  gcloud deploy apply --file clouddeploy-config/target-$TARGET.yaml --region=$REGION
done


# -----------------------------
# CREATE RELEASE
# -----------------------------
echo "🚀 Creating release web-app-001..."

gcloud deploy releases create web-app-001 \
  --delivery-pipeline web-app \
  --build-artifacts web/artifacts.json \
  --source web/ \
  --region=$REGION


echo "🎉 CI/CD Pipeline deployed successfully!"
