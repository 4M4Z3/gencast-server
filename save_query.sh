#!/bin/bash

# Exit on error
set -e

# Service account file
SERVICE_ACCOUNT_FILE="service_acct.json"

# Check if service account file exists
if [ ! -f "$SERVICE_ACCOUNT_FILE" ]; then
    echo "Error: Service account file $SERVICE_ACCOUNT_FILE not found"
    echo "Please ensure the service account JSON file is in the current directory"
    exit 1
fi

# Activate service account
echo "Activating service account..."
gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_FILE" || {
    echo "Error: Failed to activate service account"
    exit 1
}

# Set the project
PROJECT="ultra-task-456813-d5"
echo "Setting project to $PROJECT..."
gcloud config set project "$PROJECT" || {
    echo "Error: Failed to set project"
    exit 1
}

# Print current account and project
echo "Current account:"
gcloud auth list --filter=status:ACTIVE --format="value(account)"
echo "Current project:"
gcloud config get-value project

# Use current date if no argument is provided
if [ -z "$1" ]; then
  DATE="2025-06-03"  # Default to 2025-06-03
  echo "No date provided. Using default date: $DATE"
else
  DATE="$1"
fi

# Variables - using date format that works on both macOS and Ubuntu
TABLE_NAME=$(date -j -f "%Y-%m-%d" "$DATE" "+%m_%d_%Y" 2>/dev/null || date -d "$DATE" "+%m_%d_%Y")
FOLDER_NAME=$(date -j -f "%Y-%m-%d" "$DATE" "+%m-%d-%Y" 2>/dev/null || date -d "$DATE" "+%m-%d-%Y")
DATASET="gencast_export_data"
BUCKET="gencast-export-bucket"

# If forecast files already exist, just re-run merge
if [ -d "$FOLDER_NAME" ] && ls "$FOLDER_NAME"/*.csv 1> /dev/null 2>&1; then
    echo "✅ Forecast files for $DATE already exist in $FOLDER_NAME. Reprocessing with merge..."
    ./merge
    exit 0
fi

# Check if data already exists
if [ -d "$FOLDER_NAME" ] && [ -f "master_$FOLDER_NAME.csv" ]; then
    echo "✅ Data for $DATE already exists:"
    echo "   - Directory: $FOLDER_NAME"
    echo "   - Master file: master_$FOLDER_NAME.csv"
    echo "Skipping download and processing..."
    exit 0
fi

# Cost estimate
echo -e "\nCost per run:"
echo "Estimated ~17.39 GB scanned on BigQuery"
echo "Cost per TB scanned = \$5"
echo "17.39 GB * (1 TB / 1000 GB) * \$5 = ~\$0.08695\n"

# Check if Google Cloud SDK is installed
if ! command -v gcloud &> /dev/null; then
    echo "Error: Google Cloud SDK is not installed"
    echo "Please install it using:"
    echo "sudo apt-get update && sudo apt-get install google-cloud-sdk"
    exit 1
fi

# Check if user has necessary permissions
echo "Checking BigQuery permissions..."
if ! bq query --nouse_legacy_sql "SELECT 1" 2>&1; then
    echo "Error: Missing BigQuery permissions"
    echo "Please ensure the service account has the following roles:"
    echo "- BigQuery Data Editor"
    echo "- BigQuery Job User"
    echo "- BigQuery User"
    echo "Visit: https://console.cloud.google.com/iam-admin/iam?project=$PROJECT"
    echo "to verify the service account roles"
    exit 1
fi

# Check if user has storage permissions
echo "Checking Storage permissions..."
if ! gsutil ls "gs://$BUCKET" 2>&1; then
    echo "Error: No access to bucket gs://$BUCKET"
    echo "Please ensure the service account has the following roles:"
    echo "- Storage Object Admin"
    echo "Visit: https://console.cloud.google.com/iam-admin/iam?project=$PROJECT"
    echo "to verify the service account roles"
    exit 1
fi

echo "→ Running query and saving to: $TABLE_NAME..."

bq query \
  --nouse_legacy_sql \
  --destination_table="$PROJECT:$DATASET.$TABLE_NAME" \
  --replace \
  --use_cache=false \
  "
  SELECT
    f.time AS forecast_time,
    ST_Y(t.geography) AS latitude,
    ST_X(t.geography) AS longitude,
    e.2m_temperature AS temp_2m
  FROM
    \`$PROJECT.weathernext_gen_forecasts.126478713_1_0\` AS t,
    UNNEST(t.forecast) AS f,
    UNNEST(f.ensemble) AS e
  WHERE
    t.init_time = TIMESTAMP(\"$DATE\")
    AND e.ensemble_member = '5'
  ORDER BY forecast_time, latitude, longitude
  "

echo "→ Exporting table to GCS: gs://$BUCKET/$FOLDER_NAME/"
bq extract \
  --destination_format=CSV \
  "$PROJECT:$DATASET.$TABLE_NAME" \
  "gs://$BUCKET/$FOLDER_NAME/$TABLE_NAME-*.csv"

echo "→ Deleting BigQuery table: $DATASET.$TABLE_NAME"
bq rm -f -t "$PROJECT:$DATASET.$TABLE_NAME"

echo "→ Creating local directory: $FOLDER_NAME"
mkdir -p "$FOLDER_NAME" || { echo "Error: Failed to create directory $FOLDER_NAME"; exit 1; }

echo "→ Downloading from GCS to ./$FOLDER_NAME/"
gsutil -m cp "gs://$BUCKET/$FOLDER_NAME/*" "$FOLDER_NAME/" || { echo "Error: Failed to download files"; exit 1; }

echo "→ Deleting GCS folder: gs://$BUCKET/$FOLDER_NAME/"
gsutil -m rm -r "gs://$BUCKET/$FOLDER_NAME/" || { echo "Warning: Failed to delete GCS folder"; }

echo "Download complete, processing into population-weighted CSV."

./merge
