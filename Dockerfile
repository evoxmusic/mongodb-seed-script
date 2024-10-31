FROM mongo:6.0.19

# Install required tools
RUN apt-get update && apt-get install -y \
    wget \
    python3 \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI in user space
ENV PATH="/root/.local/bin:${PATH}"
RUN pip3 install --user awscli

# Set AWS Region and default backup filename
ENV AWS_DEFAULT_REGION=fr-par
ENV BACKUP_FILENAME=soliguide_db.gzip
ARG MONGODB_URI

# Create script directory
WORKDIR /scripts

# Create the restore script with added debugging
COPY <<EOF /scripts/restore.sh
#!/bin/bash

set -e

# Debug: Print all relevant environment variables
echo "Debugging environment variables:"
echo "MONGODB_URI=${MONGODB_URI:-(not set)}"
echo "S3_BUCKET_URL=${S3_BUCKET_URL:-(not set)}"
echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-(not set)}"
echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-(not set)}"
echo "BACKUP_FILENAME=${BACKUP_FILENAME:-(not set)}"
echo "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-(not set)}"

# Check each variable individually for more precise error reporting
missing_vars=()

if [ -z "$MONGODB_URI" ]; then
    missing_vars+=("MONGODB_URI")
fi

if [ -z "$S3_BUCKET_URL" ]; then
    missing_vars+=("S3_BUCKET_URL")
fi

if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    missing_vars+=("AWS_ACCESS_KEY_ID")
fi

if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    missing_vars+=("AWS_SECRET_ACCESS_KEY")
fi

# If any variables are missing, print them and exit
if [ \${#missing_vars[@]} -ne 0 ]; then
    echo "Error: The following required environment variables are not set:"
    printf '%s\n' "\${missing_vars[@]}"
    exit 1
fi

echo "All required environment variables are set. Proceeding with restore..."

# Configure AWS credentials
export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY

echo "Starting MongoDB restore process..."

# Function to check if database is empty
check_database() {
    # Extract database name from URI
    DB_NAME=$(echo $MONGODB_URI | awk -F "/" '{print $NF}' | awk -F "?" '{print $1}')
    if [ -z "$DB_NAME" ]; then
        echo "Error: Could not extract database name from URI"
        exit 1
    fi

    echo "Checking if database $DB_NAME has existing data..."
    
    # Count total documents in all collections
    DOC_COUNT=$(mongosh "$MONGODB_URI" --quiet --eval '
        db.getCollectionNames().reduce((total, collName) => {
            return total + db.getCollection(collName).countDocuments();
        }, 0)
    ')

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
        # TODO drop database if "FORCE = true"
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
aws s3 cp "$S3_BUCKET_URL/$BACKUP_FILENAME" ./$BACKUP_FILENAME

# Unzip the dump file
echo "Unzipping dump file..."
gunzip $BACKUP_FILENAME

# Get the filename without .gzip extension for mongorestore
BACKUP_FILE=\${BACKUP_FILENAME%.gzip}

# Restore the database
echo "Restoring database..."
mongorestore --uri="$MONGODB_URI" --gzip --archive=$BACKUP_FILE

# Cleanup
echo "Cleaning up temporary files..."
cd /
rm -rf $TEMP_DIR

echo "Database restore completed successfully!"
EOF

# Make the script executable
RUN chmod +x /scripts/restore.sh

# Set the script as the entry point
ENTRYPOINT ["/scripts/restore.sh"]
