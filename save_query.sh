#!/bin/bash

# Source environment variables from .env file
if [ -f .env ]; then
  source .env
else
  echo "Warning: .env file not found. Make sure SUPABASE_CONN and TABLE_NAME are set."
fi

# Exit on error
set -e

# Function to handle data upload
upload_data() {
    local upload_file=$1
    local upload_id=$2
    local batch_size=10000  # Process 10,000 rows at a time
    
    if [ ! -f "$upload_file" ]; then
        echo "Error: Upload file $upload_file not found"
        if [ -n "$upload_id" ]; then
            psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'failure', error_message = 'Upload file not found', updated_at = CURRENT_TIMESTAMP WHERE id = $upload_id;"
        fi
        return 1
    fi

    # Delete any points from failed uploads for this date
    echo "Cleaning up any points from previous failed uploads..."
    if ! psql "$SUPABASE_CONN" -c "DELETE FROM points p USING uploads u WHERE u.forecast_date = DATE('$DATE') AND u.status = 'failure' AND p.forecast_time >= DATE('$DATE');" ; then
        echo "Warning: Failed to clean up points from previous failed uploads"
    fi

    # Get min and max dates from the upload file, including dates in the JSON forecasts
    echo "Determining forecast date range..."
    MIN_DATE=$(awk -F',' '
        NR>1 {
            # Check the forecast_time column
            if (!min_date || $1 < min_date) min_date = $1
            
            # Extract dates from JSON forecasts
            json = $5
            while (match(json, /"t":"[^"]+"/)) {
                date = substr(json, RSTART+5, RLENGTH-6)
                gsub(/ UTC$/, "", date)  # Remove UTC suffix
                if (!min_date || date < min_date) min_date = date
                json = substr(json, RSTART+RLENGTH)
            }
        }
        END {
            print min_date
        }
    ' "$upload_file")
    
    MAX_DATE=$(awk -F',' '
        NR>1 {
            # Check the forecast_time column
            if (!max_date || $1 > max_date) max_date = $1
            
            # Extract dates from JSON forecasts
            json = $5
            while (match(json, /"t":"[^"]+"/)) {
                date = substr(json, RSTART+5, RLENGTH-6)
                gsub(/ UTC$/, "", date)  # Remove UTC suffix
                if (!max_date || date > max_date) max_date = date
                json = substr(json, RSTART+RLENGTH)
            }
        }
        END {
            print max_date
        }
    ' "$upload_file")
    
    echo "Found date range: $MIN_DATE to $MAX_DATE"

    # Delete existing data for the forecast date range
    echo "Deleting existing data for forecast date range..."
    if ! psql "$SUPABASE_CONN" -c "DELETE FROM points WHERE forecast_time >= DATE '${MIN_DATE}' AND forecast_time <= DATE '${MAX_DATE}';" ; then
        echo "Error: Failed to delete existing data"
        if [ -n "$upload_id" ]; then
            psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'failure', error_message = 'Failed to delete existing data', updated_at = CURRENT_TIMESTAMP WHERE id = $upload_id;"
        fi
        return 1
    fi

    echo "Uploading $upload_file in batches of $batch_size rows..."
    
    # Get total number of lines (excluding header)
    total_lines=$(wc -l < "$upload_file")
    total_lines=$((total_lines - 1))  # Subtract header
    total_batches=$(( (total_lines + batch_size - 1) / batch_size ))
    
    # Create temporary directory for batches
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Split file into batches (preserving header)
    head -n 1 "$upload_file" > "$temp_dir/header"
    tail -n +2 "$upload_file" | split -l "$batch_size" - "$temp_dir/batch_"
    
    # Process each batch
    for batch_file in "$temp_dir"/batch_*; do
        # Add header to batch
        cat "$temp_dir/header" "$batch_file" > "$batch_file.with_header"
        
        echo "Uploading batch $(basename "$batch_file")..."
        if ! psql "$SUPABASE_CONN" -c "SET statement_timeout = '600000';" -c "\copy points(forecast_time,latitude,longitude,population,forecasts) FROM '$batch_file.with_header' WITH (FORMAT csv, HEADER true);" ; then
            echo "Upload failed for batch $(basename "$batch_file")"
            if [ -n "$upload_id" ]; then
                psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'failure', error_message = 'Upload failed on batch $(basename "$batch_file")', updated_at = CURRENT_TIMESTAMP WHERE id = $upload_id;"
            fi
            return 1
        fi
    done
    
    echo "All batches uploaded successfully"
    if [ -n "$upload_id" ]; then
        psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'success', updated_at = CURRENT_TIMESTAMP WHERE id = $upload_id;"
    fi
    return 0
}

# Function to transform data into JSONB format
transform_data() {
    local input_file=$1
    local output_file=$2
    
    if [ ! -f "$input_file" ]; then
        echo "Error: Input file $input_file not found"
        return 1
    fi
    
    echo "Transforming data into JSONB format..."
    awk -F',' '
        BEGIN {
            OFS=",";
            print "forecast_time,latitude,longitude,population,forecasts"
        }
        NR > 1 {
            key = $2 "," $3 "," $4
            if (!(key in base_data)) {
                timestamp = $1
                gsub(/ UTC$/, "", timestamp)
                base_data[key] = timestamp "," $2 "," $3 "," $4
                forecasts[key] = "["
            }
            if (forecasts[key] != "[") {
                forecasts[key] = forecasts[key] ","
            }
            # Handle null/empty values
            temp_2m = ($5 == "" ? "null" : $5)
            temp_2m_stddev = ($6 == "" ? "null" : $6)
            
            forecasts[key] = forecasts[key] "{\"t\":\"" $1 "\",\"v\":" temp_2m ",\"s\":" temp_2m_stddev "}"
        }
        END {
            for (key in base_data) {
                jsonb = "{\"forecasts\":" forecasts[key] "]}"
                gsub(/\"/, "\"\"", jsonb)
                print base_data[key] ",\"" jsonb "\""
            }
        }
    ' "$input_file" > "$output_file"
    
    if [ $? -eq 0 ]; then
        echo "Ready for upload: $output_file"
        return 0
    else
        echo "Error: Failed to transform data"
        return 1
    fi
}

# Use current date if no argument is provided
if [ -z "$1" ]; then
  DATE=$(date +"%Y-%m-%d")  # Default to today's date
  echo "No date provided. Using current date: $DATE"
else
  DATE="$1"
fi

# Variables - using date format that works on both macOS and Ubuntu
TABLE_NAME=$(date -j -f "%Y-%m-%d" "$DATE" "+%m_%d_%Y" 2>/dev/null || date -d "$DATE" "+%m_%d_%Y")
FOLDER_NAME=$(date -j -f "%Y-%m-%d" "$DATE" "+%m-%d-%Y" 2>/dev/null || date -d "$DATE" "+%m-%d-%Y")
DATASET="gencast_export_data"
BUCKET="gencast-export-bucket"

# Check for ready_for_upload.csv first
UPLOAD_FILE="ready_for_upload.csv"
if [ -f "$UPLOAD_FILE" ]; then
    echo "✅ Ready for upload file already exists: $UPLOAD_FILE"
    # Count unique points and create upload record
    POINTS_COUNT=$(awk -F',' 'NR>1 {print $2 "," $3 "," $4} END {print "Total unique points: " NR-1}' "$UPLOAD_FILE" | sort -u | wc -l)
    echo "Creating upload record..."
    UPLOAD_ID=$(psql "$SUPABASE_CONN" -t -A -c "INSERT INTO uploads (forecast_date, points_count, status) VALUES ('$DATE', $POINTS_COUNT, 'in_progress') RETURNING id;" | head -n 1 | tr -d '[:space:]')

    if [ -z "$UPLOAD_ID" ]; then
        echo "Error: Failed to create upload record"
        exit 1
    fi

    # Upload existing file
    if upload_data "$UPLOAD_FILE" "$UPLOAD_ID"; then
        echo "✅ Upload completed successfully"
        exit 0
    else
        echo "❌ Upload failed - exiting script"
        exit 1
    fi
fi

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
yes | gcloud config set project "$PROJECT" || {
    echo "Error: Failed to set project"
    exit 1
}

# Print current account and project
echo "Current account:"
gcloud auth list --filter=status:ACTIVE --format="value(account)"
echo "Current project:"
gcloud config get-value project

# First check if filtered file exists - if it does, just do the upload
FILTERED_FILE="filtered_master_$FOLDER_NAME.csv"
if [ -f "$FILTERED_FILE" ]; then
  echo "✅ Filtered file already exists: $FILTERED_FILE"
  # Add upload_time column to filtered CSV for Supabase upload
  UPLOAD_FILE="ready_for_upload.csv"
  UPLOAD_TIME=$(date +"%Y-%m-%dT%H:%M:%S")  # Use current time for upload timestamp
  echo "Transforming data into JSONB format..."
  # Create a temporary file for the transformed data
  TMP_FILE="transformed_data.csv"
  
  # Use awk to transform the data into JSONB format
  awk -F',' '
    BEGIN {
      OFS=",";
      print "forecast_time,latitude,longitude,population,forecasts"
    }
    NR > 1 {
      key = $2 "," $3 "," $4
      if (!(key in base_data)) {
        timestamp = $1
        gsub(/ UTC$/, "", timestamp)
        base_data[key] = timestamp "," $2 "," $3 "," $4
        forecasts[key] = "["
      }
      if (forecasts[key] != "[") {
        forecasts[key] = forecasts[key] ","
      }
      # Handle null/empty values
      temp_2m = ($5 == "" ? "null" : $5)
      temp_2m_stddev = ($6 == "" ? "null" : $6)
      
      forecasts[key] = forecasts[key] "{\"t\":\"" $1 "\",\"v\":" temp_2m ",\"s\":" temp_2m_stddev "}"
    }
    END {
      for (key in base_data) {
        jsonb = "{\"forecasts\":" forecasts[key] "]}"
        # Double the double quotes for CSV
        gsub(/\"/, "\"\"", jsonb)
        print base_data[key] ",\"" jsonb "\""
      }
    }
  ' "$FILTERED_FILE" >> "$TMP_FILE"
  
  # Move the transformed file to the upload file
  mv "$TMP_FILE" "$UPLOAD_FILE"
  echo "Ready for upload: $UPLOAD_FILE"
  
  # Count unique points and create upload record
  POINTS_COUNT=$(awk -F',' 'NR>1 {print $2 "," $3 "," $4} END {print "Total unique points: " NR-1}' "$UPLOAD_FILE" | sort -u | wc -l)
  echo "Creating upload record..."
  UPLOAD_ID=$(psql "$SUPABASE_CONN" -t -A -c "INSERT INTO uploads (forecast_date, points_count, status) VALUES ('$DATE', $POINTS_COUNT, 'in_progress') RETURNING id;" | head -n 1 | tr -d '[:space:]')

  if [ -z "$UPLOAD_ID" ]; then
      echo "Error: Failed to create upload record"
      exit 1
  fi

  # Upload using batched function
  if upload_data "$UPLOAD_FILE" "$UPLOAD_ID"; then
      echo "✅ Upload completed successfully"
      exit 0
  else
      echo "❌ Upload failed - exiting script"
      exit 1
  fi
fi

# Check if data already exists
if [ -d "$FOLDER_NAME" ] && [ -f "master_$FOLDER_NAME.csv" ]; then
    echo "✅ Data for $DATE already exists:"
    echo "   - Directory: $FOLDER_NAME"
    echo "   - Master file: master_$FOLDER_NAME.csv"
    
    # Skip to filtering and upload
    MASTER_FILE="master_$FOLDER_NAME.csv"
    
    # Run the filter
    if [ -f "$MASTER_FILE" ]; then
      ./filter_nonzero_population "$MASTER_FILE"
    else
      echo "Warning: $MASTER_FILE not found, skipping filtering."
      exit 0
    fi

    # Transform filtered data into JSONB format
    FILTERED_FILE="filtered_master_$FOLDER_NAME.csv"
    UPLOAD_FILE="ready_for_upload.csv"
    if [ -f "$FILTERED_FILE" ]; then
      echo "Transforming filtered data into JSONB format..."
      # Create the upload file with headers
      # Count the number of unique points
      POINTS_COUNT=$(awk -F',' 'NR>1 {print $2 "," $3 "," $4} END {print "Total unique points: " NR-1}' "$FILTERED_FILE" | sort -u | wc -l)
      
      # Create upload record
      echo "Creating upload record..."
      UPLOAD_ID=$(psql "$SUPABASE_CONN" -t -A -c "INSERT INTO uploads (forecast_date, points_count, status) VALUES ('$DATE', $POINTS_COUNT, 'in_progress') RETURNING id;" | head -n 1 | tr -d '[:space:]')
      
      # Transform data using awk
      awk -F',' '
        BEGIN {
            OFS=",";
            print "forecast_time,latitude,longitude,population,forecasts"
        }
        NR > 1 {
            key = $2 "," $3 "," $4
            if (!(key in base_data)) {
                timestamp = $1
                gsub(/ UTC$/, "", timestamp)
                base_data[key] = timestamp "," $2 "," $3 "," $4
                forecasts[key] = "["
            }
            if (forecasts[key] != "[") {
                forecasts[key] = forecasts[key] ","
            }
            # Handle null/empty values
            temp_2m = ($5 == "" ? "null" : $5)
            temp_2m_stddev = ($6 == "" ? "null" : $6)
            
            forecasts[key] = forecasts[key] "{\"t\":\"" $1 "\",\"v\":" temp_2m ",\"s\":" temp_2m_stddev "}"
        }
        END {
            for (key in base_data) {
                jsonb = "{\"forecasts\":" forecasts[key] "]}"
                gsub(/\"/, "\"\"", jsonb)
                print base_data[key] ",\"" jsonb "\""
            }
        }
      ' "$FILTERED_FILE" > "$UPLOAD_FILE"
      echo "Ready for upload: $UPLOAD_FILE"

      # Upload using batched function
      if upload_data "$UPLOAD_FILE" "$UPLOAD_ID"; then
          echo "✅ Upload completed successfully"
          exit 0
      else
          echo "❌ Upload failed - exiting script"
          exit 1
      fi
    else
      echo "Warning: $FILTERED_FILE not found, skipping upload file creation."
      psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'failure', error_message = 'Filtered file not found' WHERE id = $UPLOAD_ID;"
      exit 0
    fi
fi

# If forecast files already exist, just re-run merge
if [ -d "$FOLDER_NAME" ] && ls "$FOLDER_NAME"/*.csv 1> /dev/null 2>&1; then
    echo "✅ Forecast files for $DATE already exist in $FOLDER_NAME. Reprocessing with merge..."
    ./merge
    
    # Filter out rows with zero population
    MASTER_FILE="master_$FOLDER_NAME.csv"
    if [ -f "$MASTER_FILE" ]; then
      ./filter_nonzero_population "$MASTER_FILE"
    else
      echo "Warning: $MASTER_FILE not found, skipping filtering."
      exit 0
    fi

    # Transform filtered data into JSONB format and upload
    FILTERED_FILE="filtered_master_$FOLDER_NAME.csv"
    if [ -f "$FILTERED_FILE" ]; then
      echo "Transforming filtered data into JSONB format..."
      # Create the upload file with headers
      # Count the number of unique points
      POINTS_COUNT=$(awk -F',' 'NR>1 {print $2 "," $3 "," $4} END {print "Total unique points: " NR-1}' "$FILTERED_FILE" | sort -u | wc -l)
      
      # Create upload record
      echo "Creating upload record..."
      UPLOAD_ID=$(psql "$SUPABASE_CONN" -t -A -c "INSERT INTO uploads (forecast_date, points_count, status) VALUES ('$DATE', $POINTS_COUNT, 'in_progress') RETURNING id;" | head -n 1 | tr -d '[:space:]')
      
      # Transform data using awk
      awk -F',' '
        BEGIN {
            OFS=",";
            print "forecast_time,latitude,longitude,population,forecasts"
        }
        NR > 1 {
            key = $2 "," $3 "," $4
            if (!(key in base_data)) {
                timestamp = $1
                gsub(/ UTC$/, "", timestamp)
                base_data[key] = timestamp "," $2 "," $3 "," $4
                forecasts[key] = "["
            }
            if (forecasts[key] != "[") {
                forecasts[key] = forecasts[key] ","
            }
            # Handle null/empty values
            temp_2m = ($5 == "" ? "null" : $5)
            temp_2m_stddev = ($6 == "" ? "null" : $6)
            
            forecasts[key] = forecasts[key] "{\"t\":\"" $1 "\",\"v\":" temp_2m ",\"s\":" temp_2m_stddev "}"
        }
        END {
            for (key in base_data) {
                jsonb = "{\"forecasts\":" forecasts[key] "]}"
                gsub(/\"/, "\"\"", jsonb)
                print base_data[key] ",\"" jsonb "\""
            }
        }
      ' "$FILTERED_FILE" > "$UPLOAD_FILE"
      echo "Ready for upload: $UPLOAD_FILE"

      # Upload using batched function
      if upload_data "$UPLOAD_FILE" "$UPLOAD_ID"; then
          echo "✅ Upload completed successfully"
          exit 0
      else
          echo "❌ Upload failed - exiting script"
          exit 1
      fi
    else
      echo "Warning: $FILTERED_FILE not found, skipping upload file creation."
      psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'failure', error_message = 'Filtered file not found' WHERE id = $UPLOAD_ID;"
      exit 0
    fi
fi

# Cost estimate
echo -e "\nCost per run:"
echo "Estimated ~47.53 GB scanned on BigQuery"
echo "Cost per TB scanned = \$5"
echo "47.53 GB * (1 TB / 1000 GB) * \$5 = ~\$0.24\n"

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
    AVG(e.2m_temperature) AS temp_2m,
    STDDEV(e.2m_temperature) AS temp_2m_stddev
  FROM
    \`$PROJECT.weathernext_gen_forecasts.126478713_1_0\` AS t,
    UNNEST(t.forecast) AS f,
    UNNEST(f.ensemble) AS e
  WHERE
    t.init_time = TIMESTAMP(\"$DATE\")
  GROUP BY
    forecast_time, latitude, longitude
  ORDER BY 
    forecast_time, latitude, longitude
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

# Filter out rows with zero population
MASTER_FILE="master_$FOLDER_NAME.csv"
if [ -f "$MASTER_FILE" ]; then
  ./filter_nonzero_population "$MASTER_FILE"
else
  echo "Warning: $MASTER_FILE not found, skipping filtering."
  exit 0
fi

# Process filtered data
FILTERED_FILE="filtered_master_$FOLDER_NAME.csv"

# If ready_for_upload.csv doesn't exist, proceed with normal flow
if [ ! -f "$FILTERED_FILE" ]; then
    echo "Warning: $FILTERED_FILE not found, skipping processing."
    exit 1
fi

# Count unique points and create upload record
POINTS_COUNT=$(awk -F',' 'NR>1 {print $2 "," $3 "," $4} END {print "Total unique points: " NR-1}' "$FILTERED_FILE" | sort -u | wc -l)
echo "Creating upload record..."
UPLOAD_ID=$(psql "$SUPABASE_CONN" -t -A -c "INSERT INTO uploads (forecast_date, points_count, status) VALUES ('$DATE', $POINTS_COUNT, 'in_progress') RETURNING id;" | head -n 1 | tr -d '[:space:]')

if [ -z "$UPLOAD_ID" ]; then
    echo "Error: Failed to create upload record"
    exit 1
fi

# Transform and upload data
if transform_data "$FILTERED_FILE" "$UPLOAD_FILE"; then
    if ! upload_data "$UPLOAD_FILE" "$UPLOAD_ID"; then
        echo "Upload failed - exiting script"
        exit 1
    fi
else
    echo "Transform failed - exiting script"
    psql "$SUPABASE_CONN" -c "UPDATE uploads SET status = 'failure', error_message = 'Transform failed', updated_at = CURRENT_TIMESTAMP WHERE id = $UPLOAD_ID;"
    exit 1
fi
