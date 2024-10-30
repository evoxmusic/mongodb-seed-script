# Use official MongoDB image as base
FROM mongo:latest

# Install required tools
RUN apt-get update && apt-get install -y \
    wget \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI for S3 access
RUN pip3 install awscli

# Create script directory
WORKDIR /scripts

# Create the restore script
RUN echo '#!/bin/bash

# Exit on error
set -e

# Check if required environment variables are set
if [ -z "$MONGODB_URI" ] || [ -z "$S3_BUCKET_URL" ] || [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: Required environment variables not set"
    echo "Please set:"
    echo "- MONGODB_URI"
    echo "- S3_BUCKET_URL"
    echo "- AWS_ACCESS_KEY_ID"
    echo "- AWS_SECRET_ACCESS_KEY"
    exit 1
fi

# Configure AWS credentials
export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=fr-par

echo "Starting MongoDB restore process..."

# Function to check if database is empty
check_database() {
    # Extract database name from URI
    DB_NAME=$(echo $MONGODB_URI | awk -F "/" '"'"'{print $NF}'"'"' | awk -F "?" '"'"'{print $1}'"'"')
    if [ -z "$DB_NAME" ]; then
        echo "Error: Could not extract database name from URI"
        exit 1
    fi

    echo "Checking if database $DB_NAME has existing data..."
    
    # Count total documents in all collections
    DOC_COUNT=$(mongosh "$MONGODB_URI" --quiet --eval '"'"'
        db.getCollectionNames().reduce((total, collName) => {
            return total + db.getCollection(collName).countDocuments();
        }, 0)
    '"'"')

    if [ "$DOC_COUNT" -gt 0 ]; then
        return 1  # Database has data
    else
        return 0  # Database is empty
    fi
}

# Check if database has data
if check_database; then
    echo "Database is empty. Proceeding with restore..."
else
    echo "Database contains existing data!"
    
    if [ "$FORCE" = "true" ]; then
        echo "FORCE is set to true. Proceeding with restore anyway..."
    else
        echo "Skipping restore to prevent data loss."
        echo "To force restore over existing data, set FORCE=true"
        exit 0
    fi
fi

# Create temporary directory for the dump
TEMP_DIR=$(mktemp -d)
cd $TEMP_DIR

# Download the dump file from S3
echo "Downloading dump from S3..."
aws s3 cp "$S3_BUCKET_URL/soliguide_db.gzip" ./soliguide_db.gzip

# Unzip the dump file
echo "Unzipping dump file..."
gunzip soliguide_db.gzip

# Restore the database
echo "Restoring database..."
mongorestore --uri="$MONGODB_URI" --gzip --archive=soliguide_db

# Cleanup
echo "Cleaning up temporary files..."
cd /
rm -rf $TEMP_DIR

echo "Database restore completed successfully!"' > /scripts/restore.sh

# Make the script executable
RUN chmod +x /scripts/restore.sh

# Set the script as the entry point
ENTRYPOINT ["/scripts/restore.sh"]
