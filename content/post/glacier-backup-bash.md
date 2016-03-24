+++
date = "2016-03-24T11:46:20-05:00"
title = "Amazon Glacier Backups in Bash"
+++

Why use an official Java or .NET-based algorithm when you can write your own
in Bash? This script uses the AWS CLI tool to back up a file to an Amazon
Glacier vault, without the need for a heavy runtime.

<!--more-->

Tested on Linux, so YMMV on other systems.

Requires the AWS CLI tool to be configured appropriately via `aws configure`.

{{<highlight bash>}}
#!/bin/bash
#
# This script takes a path to a file and uploads it to Amazon
# Glacier. It does this in several steps:
#
#    1. Split the file up into 1MiB chunks.
#    2. Initiate a multipart upload.
#    3. Upload each part individually.
#    4. Calculate the file's tree hash and finish the upload.
#
# See: http://amzn.to/1RjTwYk
#
# Author: Damien Radtke <damienradtke at gmail dot com>
# License: WTFPL

# Set this to the name of the Glacier vault to upload to.
VAULT_NAME=...
# 1 MiB in bytes; the tree hash algorithm requires chunks of this
# size.
CHUNK_SIZE=1048576

if [[ -z "${1}" ]]; then
    echo "No file provided."
    exit 1
fi
ARCHIVE="`realpath ${1}`"
ARCHIVE_SIZE=`cat "${ARCHIVE}" | wc --bytes`

TEMP=`mktemp --directory`
cd "${TEMP}"

# Clean up at exit.
function cleanup {
    echo "Cleaning up."
    cd ~-
    rm -rf "${TEMP}"
}
trap cleanup EXIT

echo "Initiating multipart upload..."

# Split the archive into chunks.
split --bytes=${CHUNK_SIZE} "${ARCHIVE}" chunk
NUM_CHUNKS=`ls chunk* | wc -l`

# Initiate upload.
UPLOAD_ID=$(aws glacier initiate-multipart-upload \
    --account-id=- \
    --vault-name="${VAULT_NAME}" \
    --archive-description="`basename \"${ARCHIVE}\"`" \
    --part-size=${CHUNK_SIZE} \
    --query=uploadId | sed 's/"//g')

RETVAL=$?
if [[ ${RETVAL} -ne 0 ]]; then
    echo "initiate-multipart-upload failed with status code: ${RETVAL}"
    exit 1
fi
echo "Upload ID: ${UPLOAD_ID}"

# Abort the upload if forced to exit.
function abort_upload {
    echo "Aborting upload."
    aws glacier abort-multipart-upload \
        --account-id=- \
        --vault-name="${VAULT_NAME}" \
        --upload-id="${UPLOAD_ID}"
}
trap abort_upload SIGINT SIGTERM

# Loop through the chunks.
INDEX=0
for CHUNK in chunk*; do
    # Calculate the byte range for this chunk.
    START=$((INDEX*CHUNK_SIZE))
    END=$((((INDEX+1)*CHUNK_SIZE)-1))
    END=$((END>(ARCHIVE_SIZE-1)?ARCHIVE_SIZE-1:END))
    # Increment the index.
    INDEX=$((INDEX+1))

    while true; do
        echo "Uploading chunk ${INDEX} / ${NUM_CHUNKS}..."
        aws glacier upload-multipart-part \
            --account-id=- \
            --vault-name="${VAULT_NAME}" \
            --upload-id="${UPLOAD_ID}" \
            --body="${CHUNK}" \
            --range="bytes ${START}-${END}/*" \
            >/dev/null
        RETVAL=$?
        if [[ ${RETVAL} -eq 0 ]]; then
            # Upload succeeded, on to the next one.
            break
        elif [[ ${RETVAL} -eq 130 ]]; then
            # Received a SIGINT.
            exit 1
        elif [[ ${RETVAL} -eq 255 ]]; then
            # Most likely a timeout, just let it try again.
            echo "Chunk ${INDEX} ran into an error, retrying..."
            sleep 1
        else
            echo "upload-multipart-part failed with status code: ${RETVAL}"
            echo "Aborting upload."
            aws glacier abort-multipart-upload \
                --account-id=- \
                --vault-name="${VAULT_NAME}" \
                --upload-id="${UPLOAD_ID}"
            exit 1
        fi
    done
    openssl dgst -sha256 -binary ${CHUNK} > "hash${CHUNK:5}"
done

# Calculate tree hash.
# ("And now for the tricky bit.")
echo "Calculating tree hash..."
while true; do
    COUNT=`ls hash* | wc -l`
    if [[ ${COUNT} -eq 2 ]]; then
        TREE_HASH=$(cat hash* | openssl dgst -sha256 | awk '{print $2}')
        break
    fi
    ls hash* | xargs -n 2 | while read PAIR; do
        PAIRARRAY=(${PAIR})
        if [[ ${#PAIRARRAY[@]} -eq 1 ]]; then
            break
        fi
        cat ${PAIR} | openssl dgst -sha256 -binary > temphash
        rm ${PAIR}
        mv temphash "${PAIRARRAY[0]}"
    done
done

echo "Finalizing..."
aws glacier complete-multipart-upload \
    --account-id=- \
    --vault-name="${VAULT_NAME}" \
    --upload-id="${UPLOAD_ID}" \
    --checksum="${TREE_HASH}" \
    --archive-size=${ARCHIVE_SIZE}
RETVAL=$?
if [[ ${RETVAL} -ne 0 ]]; then
    echo "complete-multipart-upload failed with status code: ${RETVAL}"
    echo "Aborting upload ${UPLOAD_ID}"
    aws glacier abort-multipart-upload \
        --account-id=- \
        --vault-name="${VAULT_NAME}" \
        --upload-id="${UPLOAD_ID}"
    exit 1
fi

echo "Done."
exit 0
{{</highlight>}}
