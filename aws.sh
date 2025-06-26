#!/bin/bash

set -euo pipefail

# include the common library
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh"

#---------------------------------------------------------------
# 			AWS cleanup
#---------------------------------------------------------------

greenprint "Starting aws cleanup"

# We need awscli to talk to AWS.
if ! hash aws; then
    if [ -z "$CONTAINER_RUNTIME" ]; then
        echo 'no awscli, nor container runtime available, cannot proceed'
        exit 2
    fi
    echo "Using 'awscli' from a container"
    sudo "${CONTAINER_RUNTIME}" pull "${CONTAINER_IMAGE_CLOUD_TOOLS}"

    AWS_CMD_NO_REGION="sudo ${CONTAINER_RUNTIME} run --rm \
        -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
        -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
        -e AWS_DEFAULT_REGION=${AWS_REGION} \
        -v ${TEMPDIR}:${TEMPDIR}:Z \
        ${CONTAINER_IMAGE_CLOUD_TOOLS} aws --output json --color on"
else
    echo "Using pre-installed 'aws' from the system"
    export AWS_DEFAULT_REGION=${AWS_REGION}
    AWS_CMD_NO_REGION="aws --output json --color on"
fi
$AWS_CMD_NO_REGION --version

AWS_CMD="${AWS_CMD_NO_REGION} --region ${AWS_REGION}"

# This script is being rewritten in Python. So far, only the instance, AMI and snapshot cleanup is done in Python, so let's call it here.
if [ "$DRY_RUN" == "true" ]; then
    ./aws.py --dry-run --max-age "${HOURS_BACK}"
else
    ./aws.py --max-age "${HOURS_BACK}"
fi

# Remove old enough objects that don't have tag persist=true
print_separator 'Cleaning objects...'

if [ -z "${AWS_BUCKET:-}" ]; then
    echo "AWS_BUCKET is empty, no object cleaning will be done"
    exit 0
fi
OBJECTS=$($AWS_CMD s3api list-objects --bucket "${AWS_BUCKET}" | jq -c '(.Contents? // [])[]')

for object in ${OBJECTS}; do
    REMOVE=1
    LAST_MODIFIED=$(echo "${object}" | jq -r '.LastModified')
    OBJECT_KEY=$(echo "${object}" | jq -r '.Key')

    if [[ $(date -d "${LAST_MODIFIED}" +%s) -gt ${DELETE_TIME} ]]; then
        REMOVE=0
        echo "The object with key ${OBJECT_KEY} was last modified less than ${HOURS_BACK} hours ago"
    fi

    TAGS=$($AWS_CMD s3api get-object-tagging --bucket "${AWS_BUCKET}" --key "${OBJECT_KEY}" | jq -c .TagSet[])
    for tag in ${TAGS}; do
        KEY=$(echo "${tag}" | jq -r '.Key')
        VALUE=$(echo "${tag}" | jq -r '.Value')

        if [[ ${KEY} == "persist" && ${VALUE} == "true" ]]; then
            REMOVE=0
            echo "The object with key ${OBJECT_KEY} has tag 'persist=true'"
        fi
    done

    if [ ${REMOVE} == 1 ]; then
        if [ "$DRY_RUN" == "true" ]; then
            echo "The object with key ${OBJECT_KEY} would get removed"
        else
            $AWS_CMD s3 rm "s3://${AWS_BUCKET}/${OBJECT_KEY}"
            echo "The object with key ${OBJECT_KEY} was removed"
        fi
    fi
done
