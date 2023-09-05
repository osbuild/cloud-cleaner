#!/bin/bash

set -euo pipefail

# include the common library
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh"

#---------------------------------------------------------------
#                       GCP cleanup
#---------------------------------------------------------------

greenprint "starting gcp cleanup"

# We need Google GCloud SDK to communicate with gcp
if ! hash gcloud; then
    if [ -z "$CONTAINER_RUNTIME" ]; then
        echo 'No gcloud cli, nor container runtime available, cannot proceed'
        exit 2
    fi
    echo "Using 'gcloud' from a container"
    sudo "${CONTAINER_RUNTIME}" pull "${CONTAINER_IMAGE_CLOUD_TOOLS}"

    # directory mounted to the container, in which gcloud stores the credentials after logging in
    GCP_CMD_CREDS_DIR="${TEMPDIR}/gcloud_credentials"
    mkdir "${GCP_CMD_CREDS_DIR}"

    GCP_CMD="sudo ${CONTAINER_RUNTIME} run --rm \
    -v ${GCP_CMD_CREDS_DIR}:/root/.config/gcloud:Z \
    -v ${GOOGLE_APPLICATION_CREDENTIALS}:${GOOGLE_APPLICATION_CREDENTIALS}:Z \
    -v ${TEMPDIR}:${TEMPDIR}:Z \
    ${CONTAINER_IMAGE_CLOUD_TOOLS} gcloud --format=json"
else
    echo "Using pre-installed 'gcloud' from the system"
    GCP_CMD="gcloud --format=json --quiet"
fi
$GCP_CMD --version

# Authenticate
$GCP_CMD auth activate-service-account --key-file "$GOOGLE_APPLICATION_CREDENTIALS"
# Extract and set the default project to be used for commands
GCP_PROJECT=$(jq -r '.project_id' "$GOOGLE_APPLICATION_CREDENTIALS")
$GCP_CMD config set project "$GCP_PROJECT"

# List tagged instances and remove the old enough ones
print_separator 'Cleaning instances...'
INSTANCES=$($GCP_CMD compute instances list --filter='NOT labels.persist:true AND NOT tags.persist:true' |
    jq -c '.[] | {"name": .name, "creationTimestamp": .creationTimestamp, "zone": .zone}')

for instance in ${INSTANCES}; do
    CREATION_TIME=$(echo "${instance}" | jq -r '.creationTimestamp')

    if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
        ZONE=$(echo "${instance}" | jq -r '.zone' | awk -F / '{print $NF}')
        NAME=$(echo "${instance}" | jq -r '.name')
        if [ "$DRY_RUN" == "true" ]; then
            echo "instance ${NAME} would get deleted."
        else
            $GCP_CMD compute instances delete --zone="$ZONE" "$NAME"
            echo "Deleted instance: ${NAME}"
        fi
    fi
done

# List tagged images and remove the old enough ones
print_separator 'Cleaning images...'
IMAGES=$($GCP_CMD compute images list --filter='NOT labels.persist:true' |
    jq -c '.[] | select(.selfLink|contains("cockpituous")) | {"name": .name, "creationTimestamp": .creationTimestamp}')

for image in $IMAGES; do
    CREATION_TIME=$(echo "${image}" | jq -r '.creationTimestamp')

    if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
        NAME=$(echo "${image}" | jq -r '.name')
        if [ "$DRY_RUN" == "true" ]; then
            echo "image ${NAME} would get deleted."
        else
            $GCP_CMD compute images delete "$NAME"
            echo "Deleted image: ${NAME}"
        fi
    fi
done
