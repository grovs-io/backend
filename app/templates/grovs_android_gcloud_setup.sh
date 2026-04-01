#!/bin/bash
set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_step() {
    echo -e "${BLUE}➤  $1${NC}"
}

# --- Prerequisite checks ---
if ! command -v gcloud &>/dev/null; then
    print_error "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi
if ! command -v terraform &>/dev/null; then
    print_error "Terraform not found. Install: https://developer.hashicorp.com/terraform/install"
    exit 1
fi

# --- Authentication check ---
if [ -n "$CLOUD_SHELL" ]; then
    # Cloud Shell: user is already authenticated via their browser session.
    # Never call gcloud auth login here — it shows a confusing "already authenticated" prompt.
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    if [ -z "$ACTIVE_ACCOUNT" ]; then
        print_error "No active gcloud account in Cloud Shell."
        print_error "Try restarting your Cloud Shell session from https://shell.cloud.google.com"
        exit 1
    fi
    print_info "Authenticated as: $ACTIVE_ACCOUNT"
else
    # Local: check gcloud auth, then ensure Terraform has Application Default Credentials
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
        print_warning "No active gcloud account. Opening browser to log in..."
        gcloud auth login
        if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
            print_error "Authentication failed. Run: gcloud auth login"
            exit 1
        fi
    fi
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    print_info "Authenticated as: $ACTIVE_ACCOUNT"

    # Terraform uses Application Default Credentials (separate from gcloud auth)
    if ! gcloud auth application-default print-access-token &>/dev/null; then
        print_warning "Terraform requires Application Default Credentials. Setting up..."
        gcloud auth application-default login
    fi
fi

# --- Project selection ---
if [ -z "$1" ]; then
    # Interactive mode: list projects and let user pick
    print_info "Fetching your Google Cloud projects..."
    PROJECTS=$(gcloud projects list --format="value(projectId,name)" --sort-by=projectId 2>/dev/null) || true

    if [ -z "$PROJECTS" ]; then
        print_warning "No projects found for this account."
        echo ""
        read -rp "Enter a new project ID to create: " NEW_PROJECT_ID
        if [ -z "$NEW_PROJECT_ID" ]; then
            print_error "No project ID provided. Exiting."
            exit 1
        fi
        print_info "Creating project '$NEW_PROJECT_ID'..."
        gcloud projects create "$NEW_PROJECT_ID"
        PROJECT_ID="$NEW_PROJECT_ID"
    else
        echo ""
        echo -e "${BOLD}Available projects:${NC}"
        echo ""

        # Build arrays for display
        i=1
        declare -a PROJECT_IDS
        while IFS=$'\t' read -r pid pname; do
            if [ -n "$pname" ]; then
                printf "  ${CYAN}%3d${NC}) %s  ${YELLOW}(%s)${NC}\n" "$i" "$pid" "$pname"
            else
                printf "  ${CYAN}%3d${NC}) %s\n" "$i" "$pid"
            fi
            PROJECT_IDS[$i]="$pid"
            i=$((i + 1))
        done <<< "$PROJECTS"

        echo ""
        printf "  ${CYAN}  N${NC}) Create a new project\n"
        echo ""

        while true; do
            read -rp "Select a project [1-$((i - 1))] or N: " CHOICE
            if [[ "$CHOICE" =~ ^[Nn]$ ]]; then
                read -rp "Enter a new project ID to create: " NEW_PROJECT_ID
                if [ -z "$NEW_PROJECT_ID" ]; then
                    print_error "No project ID provided."
                    continue
                fi
                print_info "Creating project '$NEW_PROJECT_ID'..."
                gcloud projects create "$NEW_PROJECT_ID"
                PROJECT_ID="$NEW_PROJECT_ID"
                break
            elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -lt "$i" ]; then
                PROJECT_ID="${PROJECT_IDS[$CHOICE]}"
                break
            else
                print_error "Invalid choice. Please enter a number between 1 and $((i - 1)), or N."
            fi
        done
    fi
else
    # Argument mode: reject placeholders, use as-is
    if [ "$1" = "google_cloud_project_id" ] || [ "$1" = "<project-id>" ] || [ "$1" = "your-project-id" ]; then
        print_error "Invalid project ID: '$1'"
        echo "Please replace this with your actual Google Cloud project ID."
        echo "You can find it at: https://console.cloud.google.com/home/dashboard"
        echo ""
        echo "Example: ./grovs_android_gcloud_setup.sh my-app-477213"
        exit 1
    fi
    PROJECT_ID="$1"
fi

# Set project ID
export TF_VAR_project_id="$PROJECT_ID"
print_info "Setting project to: $TF_VAR_project_id"

# Resource names (constants)
SA_ACCOUNT_ID="grovs-play-api-service-account"
TOPIC_NAME="grovs-play-rtdn-topic"
SUBSCRIPTION_NAME="play-rtdn-subscription"
PUSH_ENDPOINT="{{PUSH_ENDPOINT}}"

# Create working directory
WORK_DIR="./grovs"
print_info "Creating working directory: $WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Configure gcloud
print_info "Configuring gcloud..."
gcloud config set project $TF_VAR_project_id

# Enable all required APIs via gcloud (waits for propagation, unlike Terraform)
print_info "Enabling required Google Cloud APIs (this may take a minute)..."
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com \
    pubsub.googleapis.com \
    androidpublisher.googleapis.com \
    --project="$TF_VAR_project_id"

print_info "Retrieving project number..."
PROJECT_NUMBER=$(gcloud projects describe $TF_VAR_project_id --format='value(projectNumber)')
export TF_VAR_project_number=$PROJECT_NUMBER
print_info "Project number: $PROJECT_NUMBER"

# Derived values
SA_EMAIL="${SA_ACCOUNT_ID}@${TF_VAR_project_id}.iam.gserviceaccount.com"

# Create Terraform configuration
print_info "Creating Terraform configuration..."
cat > grovs_android_publish_generated.tf <<'EOF'
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "project_number" {
  description = "GCP Project Number"
  type        = string
}

provider "google" {
  project = var.project_id
  region  = "us-central1"
}

# Enable required APIs
resource "google_project_service" "androidpublisher" {
  project            = var.project_id
  service            = "androidpublisher.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "pubsub" {
  project            = var.project_id
  service            = "pubsub.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

# Create service account
resource "google_service_account" "play_api" {
  project      = var.project_id
  account_id   = "grovs-play-api-service-account"
  display_name = "Service Account for Google Play API Integration"

  depends_on = [google_project_service.iam]
}

# Generate a key
resource "google_service_account_key" "play_api_key" {
  service_account_id = google_service_account.play_api.name
}

# Grant the Pub/Sub service agent permission to create OIDC tokens
# Required for push subscriptions with OIDC authentication
resource "google_project_iam_member" "pubsub_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  depends_on = [google_project_service.iam, google_project_service.pubsub, google_project_service.cloudresourcemanager]
}

# Create Pub/Sub topic
resource "google_pubsub_topic" "play_notifications" {
  project = var.project_id
  name    = "grovs-play-rtdn-topic"

  depends_on = [google_project_service.pubsub]
}

# Grant Google Play's system account permission to publish to the topic
resource "google_pubsub_topic_iam_member" "play_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.play_notifications.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:google-play-developer-notifications@system.gserviceaccount.com"
}

# Create subscription that pushes to your endpoint
resource "google_pubsub_subscription" "play_subscription" {
  project                    = var.project_id
  name                       = "play-rtdn-subscription"
  topic                      = google_pubsub_topic.play_notifications.name
  message_retention_duration = "604800s"

  push_config {
    push_endpoint = "{{PUSH_ENDPOINT}}"
    oidc_token {
      service_account_email = google_service_account.play_api.email
      audience              = "{{PUSH_ENDPOINT}}"
    }
  }

  depends_on = [google_project_iam_member.pubsub_token_creator]
}

# Grant your service account subscriber permissions
resource "google_pubsub_subscription_iam_member" "subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.play_subscription.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.play_api.email}"
}

output "service_account_email" {
  value       = google_service_account.play_api.email
  description = "Service account email for Google Play API integration"
}

output "project_id" {
  value       = var.project_id
  description = "GCP Project ID where resources were created"
}

output "service_account_private_key_json" {
  value       = base64decode(google_service_account_key.play_api_key.private_key)
  sensitive   = true
  description = "Service account private key in JSON format (base64 decoded)"
}

output "pubsub_topic_name" {
  value       = google_pubsub_topic.play_notifications.name
  description = "Pub/Sub topic name for Google Play notifications"
}

output "pubsub_topic_full_name" {
  value       = "projects/${var.project_id}/topics/${google_pubsub_topic.play_notifications.name}"
  description = "Full Pub/Sub topic name for Google Play Console"
}
EOF

# Initialize Terraform
print_info "Initializing Terraform..."
terraform init

# Import existing resources into Terraform state (handles re-runs gracefully)
print_info "Checking for existing resources to import..."

import_resource() {
    local resource_name=$1
    local resource_id=$2
    # Always clear stale state first (handles project switches gracefully)
    terraform state rm "$resource_name" &>/dev/null || true
    # Try to import from the current project
    if terraform import "$resource_name" "$resource_id" &>/dev/null; then
        echo "  Imported: $resource_name"
    else
        echo "  Will create: $resource_name"
    fi
}

import_resource "google_project_service.androidpublisher" "${TF_VAR_project_id}/androidpublisher.googleapis.com"
import_resource "google_project_service.iam" "${TF_VAR_project_id}/iam.googleapis.com"
import_resource "google_project_service.pubsub" "${TF_VAR_project_id}/pubsub.googleapis.com"
import_resource "google_project_service.cloudresourcemanager" "${TF_VAR_project_id}/cloudresourcemanager.googleapis.com"
import_resource "google_service_account.play_api" "projects/${TF_VAR_project_id}/serviceAccounts/${SA_EMAIL}"
import_resource "google_pubsub_topic.play_notifications" "projects/${TF_VAR_project_id}/topics/${TOPIC_NAME}"
import_resource "google_pubsub_subscription.play_subscription" "projects/${TF_VAR_project_id}/subscriptions/${SUBSCRIPTION_NAME}"
import_resource "google_project_iam_member.pubsub_token_creator" "${TF_VAR_project_id} roles/iam.serviceAccountTokenCreator serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
import_resource "google_pubsub_topic_iam_member.play_publisher" "${TF_VAR_project_id}/${TOPIC_NAME} roles/pubsub.publisher serviceAccount:google-play-developer-notifications@system.gserviceaccount.com"
import_resource "google_pubsub_subscription_iam_member.subscriber" "${TF_VAR_project_id}/${SUBSCRIPTION_NAME} roles/pubsub.subscriber serviceAccount:${SA_EMAIL}"

# Run Terraform apply
print_info "Running Terraform apply..."
terraform apply -auto-approve

# Save private key
print_info "Saving private key to play-api-key.json..."
terraform output -raw service_account_private_key_json > play-api-key.json

# Download file if in Cloud Shell
if [ -n "$CLOUD_SHELL" ]; then
    print_info "Downloading key file from Cloud Shell..."
    cloudshell download play-api-key.json

    print_warning "Please download the file when prompted by your browser."
    read -p "Press ENTER after you've downloaded the file (or press Ctrl+C to cancel)..."

    print_warning "Deleting key from Cloud Shell for security..."
    rm play-api-key.json
else
    print_info "Key saved to ./grovs/play-api-key.json"
    print_warning "Remember to secure this file - it contains sensitive credentials!"
fi

SA_OUTPUT=$(terraform output -raw service_account_email)
TOPIC_OUTPUT=$(terraform output -raw pubsub_topic_full_name)
PROJECT_OUTPUT=$(terraform output -raw project_id)

echo ""
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║         Google Cloud Account Setup for Grovs Complete           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Summary
print_info "Summary:"
echo "  Project:         $PROJECT_OUTPUT"
echo "  Service Account: $SA_OUTPUT"
echo "  Pub/Sub Topic:   $TOPIC_OUTPUT"
echo ""

# Display next steps
print_step "STEP 1: Upload the service account key to Grovs"
echo ""
echo "   Go to: Grovs Dashboard > Developer > Android Setup"
echo "   Section: Google Play Real-Time Developer Notifications"
echo "   Action: Upload the play-api-key.json file"
echo ""
print_step "STEP 2: Invite the service account to Google Play Console"
echo ""
echo "   Go to: Google Play Console > Users and permissions"
echo "   Click 'Invite new users' and enter this email:"
echo ""
echo -e "     ${CYAN}${BOLD}$SA_OUTPUT${NC}"
echo ""
echo -e "   ${BOLD}Grant these permissions (all 3 are required for revenue):${NC}"
echo ""
echo -e "     ${GREEN}✓${NC} View app information and download bulk reports (read-only)"
echo -e "     ${GREEN}✓${NC} View financial data, orders, and cancellation survey responses"
echo -e "     ${GREEN}✓${NC} Manage orders and subscriptions"
echo ""
echo "   Click 'Invite user' and confirm."
echo -e "   ${YELLOW}Note: permissions can take up to 24h to propagate.${NC}"
echo ""
print_step "STEP 3: Enable Real-Time Developer Notifications"
echo ""
echo "   Go to: Google Play Console > [Your App] > Monetization setup"
echo "         > Google Play Billing > Real-time developer notifications"
echo ""
echo -e "   Set topic to: ${CYAN}${BOLD}$TOPIC_OUTPUT${NC}"
echo ""
echo -e "   ${BOLD}Enable the following notification types:${NC}"
echo ""
echo -e "     ${GREEN}✓${NC} Subscription notifications          ${BOLD}(required)${NC}"
echo -e "     ${GREEN}✓${NC} Voided purchase notifications        ${BOLD}(required)${NC}"
echo -e "     ${GREEN}✓${NC} All one-time product notifications   ${YELLOW}(if you sell one-time products)${NC}"
echo ""
echo "   Send a test notification to verify the connection."
echo ""
print_step "STEP 4: Enable Revenue Collection in Grovs"
echo ""
echo "   Enable 'Revenue Collection' in Grovs Dashboard for your instance."
echo "   Without this, webhooks are received but not processed."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BOLD}Troubleshooting:${NC}"
echo ""
echo "  Revenue not showing?"
echo "    - Missing 'View financial data' permission = no price/revenue data"
echo "    - Missing 'Manage orders' permission = purchases auto-refund after 3 days"
echo "    - Revenue Collection not enabled in Grovs = webhooks ignored"
echo "    - Permissions can take up to 24h to propagate"
echo ""
echo "  This script is safe to re-run. Existing resources are imported"
echo "  and updated. A new service account key is generated each time."
echo ""
