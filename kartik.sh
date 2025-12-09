#!/bin/bash

# Define basic format variables
RESET_FORMAT=$'\033[0m'
BOLD_TEXT=$'\033[1m'
COLOR_INFO=$'\033[0;94m'      # Blue
COLOR_SUCCESS=$'\033[0;92m'   # Green
COLOR_WARNING=$'\033[0;93m'   # Yellow
COLOR_ERROR=$'\033[0;91m'     # Red
COLOR_HIGHLIGHT=$'\033[0;97m' # White

# --- Utility Functions ---

# Spinner function for background tasks
spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [ %c ] " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

# Function to run a command and wait for spinner
run_task() {
    local task_description="$1"
    local command="$2"
    echo "${COLOR_INFO}${BOLD_TEXT}>>> ${task_description}${RESET_FORMAT}"
    (eval "$command") & spinner
    echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Completed: ${task_description}${RESET_FORMAT}"
}

# --- Initialization and Configuration ---

echo "${COLOR_INFO}${BOLD_TEXT}===================================${RESET_FORMAT}"
echo "${COLOR_INFO}${BOLD_TEXT}🚀 GCP CLOUD DEPLOY SCRIPT STARTING 🚀${RESET_FORMAT}"
echo "${COLOR_INFO}${BOLD_TEXT}===================================${RESET_FORMAT}"
echo

# 1. Detect or prompt for Zone
echo "${COLOR_INFO}🔍 Attempting to automatically detect the default Google Cloud Zone...${RESET_FORMAT}"
ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)

if [ -z "$ZONE" ]; then
    echo "${COLOR_WARNING}⚠️ Default zone not detected automatically.${RESET_FORMAT}"
    while true; do
        read -p "${COLOR_SUCCESS}${BOLD_TEXT}Please enter the Zone (e.g., us-central1-a): ${RESET_FORMAT}" ZONE_INPUT
        if [ -z "$ZONE_INPUT" ]; then
            echo "${COLOR_ERROR}Zone cannot be empty. Please try again. 🚫${RESET_FORMAT}"
        elif [[ "$ZONE_INPUT" =~ ^[a-z0-9]+-[a-z0-9]+-[a-z]$ ]]; then
            ZONE="$ZONE_INPUT"
            break
        else
            echo "${COLOR_ERROR}Invalid zone format. Expected format like 'us-central1-a'. Please try again. ❌${RESET_FORMAT}"
        fi
    done
fi
echo "${COLOR_SUCCESS}✅ Using Zone: ${COLOR_HIGHLIGHT}${BOLD_TEXT}$ZONE${RESET_FORMAT}"

# 2. Detect or derive Region
echo
echo "${COLOR_INFO}🌍 Attempting to automatically detect the default Google Cloud Region...${RESET_FORMAT}"
REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)

if [ -z "$REGION" ]; then
    echo "${COLOR_WARNING}⚠️ Default region not detected automatically.${RESET_FORMAT}"
    if [ -n "$ZONE" ]; then
        echo "${COLOR_WARNING}Deriving region from the previously set Zone '${ZONE}'.${RESET_FORMAT}"
        REGION="${ZONE%-*}"
    else
        echo "${COLOR_ERROR}Cannot derive Region as Zone is not set. Please provide the region manually. 👇${RESET_FORMAT}"
        while true; do
            read -p "${COLOR_SUCCESS}${BOLD_TEXT}Please enter the Region (e.g., us-central1): ${RESET_FORMAT}" REGION_INPUT
            if [ -z "$REGION_INPUT" ]; then
                echo "${COLOR_ERROR}Region cannot be empty. Please try again. 🚫${RESET_FORMAT}"
            elif [[ "$REGION_INPUT" =~ ^[a-z0-9]+-[a-z0-9]+$ ]]; then
                REGION="$REGION_INPUT"
                break
            else
                echo "${COLOR_ERROR}Invalid region format. Expected format like 'us-central1'. Please try again. ❌${RESET_FORMAT}"
            fi
        done
    fi
fi
echo "${COLOR_SUCCESS}✅ Using Region: ${COLOR_HIGHLIGHT}${BOLD_TEXT}$REGION${RESET_FORMAT}"
export REGION

# 3. Fetch Project details
echo
run_task "Fetching Google Cloud Project ID" "PROJECT_ID=\$(gcloud config get-value project) && export PROJECT_ID"
echo "${COLOR_SUCCESS}✅ Using Project ID: ${COLOR_HIGHLIGHT}${BOLD_TEXT}$PROJECT_ID${RESET_FORMAT}"

run_task "Fetching Google Cloud Project Number" "PROJECT_NUMBER=\$(gcloud projects describe \$PROJECT_ID --format='value(projectNumber)') && export PROJECT_NUMBER"
echo "${COLOR_SUCCESS}✅ Using Project Number: ${COLOR_HIGHLIGHT}${BOLD_TEXT}$PROJECT_NUMBER${RESET_FORMAT}"

# 4. Set default gcloud configurations
run_task "Setting default compute region for gcloud commands" "gcloud config set compute/region \$REGION"
run_task "Setting default deploy region for gcloud commands" "gcloud config set deploy/region \$REGION"

# 5. Enable necessary Google Cloud services
run_task "Enabling necessary Google Cloud services (container, clouddeploy, artifactregistry, cloudbuild)" "gcloud services enable container.googleapis.com clouddeploy.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com"

# 6. Pause for API initialization
echo
echo "${COLOR_SUCCESS}${BOLD_TEXT}⏳ Pausing to allow services to initialize fully (20s)...${RESET_FORMAT}"
sleep 20
echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Services initialization pause complete.${RESET_FORMAT}"

# --- IAM Setup ---

echo
run_task "Granting 'Cloud Deploy Job Runner' role to the Compute Engine default service account" "gcloud projects add-iam-policy-binding \$PROJECT_ID --member=serviceAccount:\$(gcloud projects describe \$PROJECT_ID --format=\"value(projectNumber)\")-compute@developer.gserviceaccount.com --role=\"roles/clouddeploy.jobRunner\""
run_task "Granting 'Container Developer' role to the Compute Engine default service account" "gcloud projects add-iam-policy-binding \$PROJECT_ID --member=serviceAccount:\$(gcloud projects describe \$PROJECT_ID --format=\"value(projectNumber)\")-compute@developer.gserviceaccount.com --role=\"roles/container.developer\""

# --- Infrastructure Creation ---

echo
run_task "Creating Artifact Registry repository 'cicd-challenge' for Docker images" "gcloud artifacts repositories create cicd-challenge --description=\"Image registry for web app\" --repository-format=docker --location=\$REGION"

echo
run_task "Creating GKE cluster 'cd-staging' in zone ${ZONE} (asynchronously)" "gcloud container clusters create cd-staging --node-locations=\$ZONE --num-nodes=1 --async"
run_task "Creating GKE cluster 'cd-production' in zone ${ZONE} (asynchronously)" "gcloud container clusters create cd-production --node-locations=\$ZONE --num-nodes=1 --async"

# --- Code and Build Setup ---

echo
run_task "Navigating to home directory" "cd ~/"
run_task "Cloning 'cloud-deploy-tutorials' repository" "git clone https://github.com/GoogleCloudPlatform/cloud-deploy-tutorials.git"
run_task "Changing directory to 'cloud-deploy-tutorials'" "cd cloud-deploy-tutorials"
run_task "Checking out a specific commit (c3cae80)" "git checkout c3cae80 --quiet"
run_task "Changing directory to 'tutorials/base'" "cd tutorials/base"

echo
run_task "Generating Skaffold configuration (skaffold.yaml) from template" "envsubst < clouddeploy-config/skaffold.yaml.template > web/skaffold.yaml"
run_task "Updating Skaffold configuration with Project ID" "sed -i \"s/{{project-id}}/\$PROJECT_ID/g\" web/skaffold.yaml"

echo
echo "${COLOR_INFO}☁️ Checking for Cloud Storage bucket gs://${PROJECT_ID}_cloudbuild/ and creating if it doesn't exist...${RESET_FORMAT}"
if ! gsutil ls "gs://${PROJECT_ID}_cloudbuild/" &>/dev/null; then
    run_task "Creating bucket gs://${PROJECT_ID}_cloudbuild/ in region ${REGION}" "gsutil mb -p \"\${PROJECT_ID}\" -l \"\${REGION}\" -b on \"gs://\${PROJECT_ID}_cloudbuild/\""
    sleep 5
fi

run_task "Changing directory to 'web'" "cd web"
echo "${COLOR_INFO}🏗️ Building application using Skaffold and outputting artifacts to 'artifacts.json' for initial release...${RESET_FORMAT}"
echo "${COLOR_WARNING}  Repository: ${COLOR_HIGHLIGHT}${REGION}-docker.pkg.dev/$PROJECT_ID/cicd-challenge${RESET_FORMAT}"
(skaffold build --interactive=false --default-repo $REGION-docker.pkg.dev/$PROJECT_ID/cicd-challenge --file-output artifacts.json) & spinner
echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Build completed. Artifacts saved to artifacts.json.${RESET_FORMAT}"
run_task "Navigating back to the parent directory" "cd .."

# --- Cloud Deploy Pipeline Setup ---

echo
run_task "Copying delivery pipeline template" "cp clouddeploy-config/delivery-pipeline.yaml.template clouddeploy-config/delivery-pipeline.yaml"
run_task "Modifying delivery pipeline: staging target to 'cd-staging'" "sed -i \"s/targetId: staging/targetId: cd-staging/\" clouddeploy-config/delivery-pipeline.yaml"
run_task "Modifying delivery pipeline: production target to 'cd-production'" "sed -i \"s/targetId: prod/targetId: cd-production/\" clouddeploy-config/delivery-pipeline.yaml"
run_task "Modifying delivery pipeline: removing 'test' target" "sed -i \"/targetId: test/d\" clouddeploy-config/delivery-pipeline.yaml"
run_task "Applying the delivery pipeline configuration" "gcloud beta deploy apply --file=clouddeploy-config/delivery-pipeline.yaml"

# --- GKE Cluster Waiting and Configuration ---

CLUSTERS=("cd-staging" "cd-production")
echo
echo "${COLOR_INFO}🔄 Checking status of GKE clusters: ${COLOR_HIGHLIGHT}${CLUSTERS[*]}${RESET_FORMAT}${COLOR_INFO}...${RESET_FORMAT}"
for cluster in "${CLUSTERS[@]}"; do
    status=$(gcloud container clusters describe "$cluster" --format="value(status)" 2>/dev/null)
    while [ "$status" != "RUNNING" ]; do
        echo "${COLOR_WARNING}⏳ Cluster ${BOLD_TEXT}$cluster${RESET_FORMAT}${COLOR_WARNING} is currently ${BOLD_TEXT}$status${RESET_FORMAT}${COLOR_WARNING}. Waiting for 'RUNNING'...${RESET_FORMAT}"
        for i in $(seq 10 -1 1); do
            echo -ne "${COLOR_WARNING}  Waiting... ${BOLD_TEXT}$i${RESET_FORMAT}${COLOR_WARNING} seconds remaining. \r${RESET_FORMAT}"
            sleep 1
        done
        echo -ne "\033[K"
        status=$(gcloud container clusters describe "$cluster" --format="value(status)" 2>/dev/null)
    done
    echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Cluster ${COLOR_HIGHLIGHT}$cluster${RESET_FORMAT}${COLOR_SUCCESS}${BOLD_TEXT} is now RUNNING!${RESET_FORMAT}"
done

CONTEXTS=("cd-staging" "cd-production")
echo
for CONTEXT in ${CONTEXTS[@]}
do
    run_task "Getting credentials for cluster ${CONTEXT}" "gcloud container clusters get-credentials ${CONTEXT} --region ${REGION}"
    run_task "Renaming kubectl context for ${CONTEXT}" "kubectl config rename-context gke_\${PROJECT_ID}_\${REGION}_${CONTEXT} ${CONTEXT}"
    run_task "Applying Kubernetes namespace configuration to context ${CONTEXT}" "kubectl --context ${CONTEXT} apply -f kubernetes-config/web-app-namespace.yaml"
done

# --- Cloud Deploy Target Configuration ---

echo
run_task "Generating Cloud Deploy target configuration for 'cd-staging'" "envsubst < clouddeploy-config/target-staging.yaml.template > clouddeploy-config/target-cd-staging.yaml"
run_task "Generating Cloud Deploy target configuration for 'cd-production'" "envsubst < clouddeploy-config/target-prod.yaml.template > clouddeploy-config/target-cd-production.yaml"
run_task "Updating target configuration name for 'cd-staging'" "sed -i \"s/staging/cd-staging/\" clouddeploy-config/target-cd-staging.yaml"
run_task "Updating target configuration name for 'cd-production'" "sed -i \"s/prod/cd-production/\" clouddeploy-config/target-cd-production.yaml"
run_task "Applying Cloud Deploy target configuration for 'cd-staging'" "gcloud beta deploy apply --file clouddeploy-config/target-cd-staging.yaml"
run_task "Applying Cloud Deploy target configuration for 'cd-production'" "gcloud beta deploy apply --file clouddeploy-config/target-cd-production.yaml"

# --- Release 1: Staging -> Production (with Approval) ---

echo
run_task "Creating first release 'web-app-001' for delivery pipeline 'web-app'" "gcloud beta deploy releases create web-app-001 --delivery-pipeline web-app --build-artifacts web/artifacts.json --source web/"

echo
echo "${COLOR_INFO}⏳ Monitoring initial rollout for 'web-app-001' to staging...${RESET_FORMAT}"
while true; do
    status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --format="value(state)" 2>/dev/null | head -n 1)
    if [ "$status" == "SUCCEEDED" ]; then
        echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Rollout to staging for 'web-app-001' SUCCEEDED!${RESET_FORMAT}"
        break
    fi
    echo "${COLOR_WARNING}${BOLD_TEXT}  Current rollout status: ${COLOR_HIGHLIGHT}$status${RESET_FORMAT}${COLOR_WARNING}. Waiting...${RESET_FORMAT}"
    sleep 10
done

echo
run_task "Promoting release 'web-app-001' to the next stage (production)" "gcloud beta deploy releases promote --delivery-pipeline web-app --release web-app-001 --quiet"

echo
echo "${COLOR_INFO}⏳ Waiting for production rollout to reach 'PENDING_APPROVAL' state...${RESET_FORMAT}"
while true; do
    # Note: Rollouts list displays rollouts in reverse chronological order, so head -n 1 should give the latest one
    status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --format="value(state)" 2>/dev/null | head -n 1)
    if [ "$status" == "PENDING_APPROVAL" ]; then
        echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Rollout for 'web-app-001' is now PENDING_APPROVAL for production!${RESET_FORMAT}"
        break
    fi
    echo "${COLOR_WARNING}${BOLD_TEXT}  Current rollout status: ${COLOR_HIGHLIGHT}$status${RESET_FORMAT}${COLOR_WARNING}. Waiting...${RESET_FORMAT}"
    sleep 10
done

echo
# The rollout ID for the first promotion is typically 'web-app-001-to-cd-production-0001'
run_task "Approving rollout 'web-app-001-to-cd-production-0001' for production" "gcloud beta deploy rollouts approve web-app-001-to-cd-production-0001 --delivery-pipeline web-app --release web-app-001 --quiet"

echo
echo "${COLOR_INFO}⏳ Monitoring production rollout for 'web-app-001'...${RESET_FORMAT}"
while true; do
    status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-001 --format="value(state)" 2>/dev/null | head -n 1)
    if [ "$status" == "SUCCEEDED" ]; then
        echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Production rollout for 'web-app-001' SUCCEEDED! 🎉${RESET_FORMAT}"
        break
    fi
    echo "${COLOR_WARNING}${BOLD_TEXT}  Current rollout status: ${COLOR_HIGHLIGHT}$status${RESET_FORMAT}${COLOR_WARNING}. Waiting...${RESET_FORMAT}"
    sleep 10
done

# --- Release 2: Staging Deployment and Rollback ---

echo
run_task "Changing directory back to 'web'" "cd web"
echo "${COLOR_INFO}🏗️ Building application again (Release 2) using Skaffold for a new release...${RESET_FORMAT}"
(skaffold build --interactive=false --default-repo $REGION-docker.pkg.dev/$PROJECT_ID/cicd-challenge --file-output artifacts.json) & spinner
echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Build for Release 2 completed.${RESET_FORMAT}"
run_task "Navigating back to the parent directory" "cd .."

echo
run_task "Creating second release 'web-app-002' for delivery pipeline 'web-app'" "gcloud beta deploy releases create web-app-002 --delivery-pipeline web-app --build-artifacts web/artifacts.json --source web/"

echo
echo "${COLOR_INFO}⏳ Monitoring rollout for 'web-app-002' to staging...${RESET_FORMAT}"
while true; do
    status=$(gcloud beta deploy rollouts list --delivery-pipeline web-app --release web-app-002 --format="value(state)" 2>/dev/null | head -n 1)
    if [ "$status" == "SUCCEEDED" ]; then
        echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Rollout to staging for 'web-app-002' SUCCEEDED!${RESET_FORMAT}"
        break
    fi
    echo "${COLOR_WARNING}${BOLD_TEXT}  Current rollout status: ${COLOR_HIGHLIGHT}$status${RESET_FORMAT}${COLOR_WARNING}. Waiting...${RESET_FORMAT}"
    sleep 10
done

echo
run_task "Rolling back target 'cd-staging' to the previous successful release" "gcloud deploy targets rollback cd-staging --delivery-pipeline=web-app --quiet"
echo "${COLOR_SUCCESS}${BOLD_TEXT}✅ Rollback command initiated for 'cd-staging'.${RESET_FORMAT}"

# --- Finalization ---

echo
echo "${COLOR_SUCCESS}${BOLD_TEXT}╔════════════════════════════════════════════════════════╗${RESET_FORMAT}"
echo "${COLOR_SUCCESS}${BOLD_TEXT}  GCP Cloud Deploy Automation Script Execution Complete!  ${RESET_FORMAT}"
echo "${COLOR_SUCCESS}${BOLD_TEXT}╚════════════════════════════════════════════════════════╝${RESET_FORMAT}"
echo
