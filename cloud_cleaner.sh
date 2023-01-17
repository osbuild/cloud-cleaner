#!/bin/bash

# Colorful output.
function greenprint {
    echo -e "\033[1;32m[$(date -Isecond)] ${1}\033[0m"
}

# filter out resources older than X hours
HOURS_BACK="${HOURS_BACK:-6}"
DELETE_TIME=$(date -d "- $HOURS_BACK hours" +%s)

while test $# -gt 0; do
    case "$1" in
        --dry-run)
            echo "Dry run mode is enabled"
            export DRY_RUN="true"
            shift
        ;;
        -h|--help)
            echo "Cloud Cleaner is a small program to remove unused resources from the cloud"
            echo "options:"
            echo "-h, --help        show brief help"
            echo "--dry-run         show which resources would get removed without doing so"
            exit
        ;;
        *)
            echo "running default cleanup"
            export DRY_RUN="false"
            break
        ;;
    esac
done

#---------------------------------------------------------------
#                       Azure cleanup
#---------------------------------------------------------------

greenprint "Starting azure cleanup"

if ! hash az; then
    # this installation method is taken from the official docs:
    # https://docs.microsoft.com/cs-cz/cli/azure/install-azure-cli-linux?pivots=dnf
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" | sudo tee /etc/yum.repos.d/azure-cli.repo

  sudo dnf install -y azure-cli
  az version
fi

az login --service-principal --username "${V2_AZURE_CLIENT_ID}" --password "${V2_AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"

#---------------------------------------------------------------

# List all resources from AZURE_RESOURCE_GROUP
RESOURCE_LIST=$(az resource list -g "$AZURE_RESOURCE_GROUP")
RESOURCE_COUNT=$( echo "$RESOURCE_LIST" | jq .[].name | wc -l)

# Delete resources in a specific order, as dependency on one another might prevent resource deletion
RESOURCE_TYPES=(
    "Microsoft.Compute/virtualMachines"
    "Microsoft.Network/networkInterfaces"
    "Microsoft.Network/networkSecurityGroups"
    "Microsoft.Network/publicIPAddresses"
    "Microsoft.Network/virtualNetworks"
    "Microsoft.Compute/images"
    "Microsoft.Compute/disks"
)

for i in $(seq 0 $(("${#RESOURCE_TYPES[@]}" - 1))); do
    echo -e "\nDeleting ${RESOURCE_TYPES[i]}\n"
    FILTERED_RESOURCES=$(echo "$RESOURCE_LIST" | jq -r "map(select(.type == \"${RESOURCE_TYPES[i]}\") | select(.tags.\"persist\" != \"true\"))")
    FILTERED_RESOURCES_LEN=$(echo "$FILTERED_RESOURCES" | jq -r "map(select(.type == \"${RESOURCE_TYPES[i]}\")) | length")
    for j in $(seq 0 $(("$FILTERED_RESOURCES_LEN" - 1))); do
        RESOURCE_TIME=$(echo "$FILTERED_RESOURCES" | jq -r ".[$j].createdTime")
        RESOURCE_TIME_SECONDS=$(date -d "$RESOURCE_TIME" +%s)
        if [[ "$RESOURCE_TIME_SECONDS" -lt "$DELETE_TIME" ]]; then
            if [ $DRY_RUN == "true" ]; then
                echo "Resource with id $(echo "$FILTERED_RESOURCES" | jq -r ".[$j].id") would get deleted"
            else
                az resource delete --ids $(echo "$FILTERED_RESOURCES" | jq -r ".[$j].id")
                echo "Deleted resource with id $(echo "$FILTERED_RESOURCES" | jq -r ".[$j].id")"
            fi
        fi
    done
done

                             
echo -e "-------------------------\nCleaning storage accounts\n-------------------------"
# Explicitly check the other storage accounts (mostly the api test one)
STORAGE_ACCOUNT_LIST=$(az resource list -g "$AZURE_RESOURCE_GROUP" --resource-type Microsoft.Storage/storageAccounts | jq -c ".[] | select(.tags.\"persist\" != \"true\")")
STORAGE_ACCOUNT_COUNT=$(echo "$STORAGE_ACCOUNT_LIST" | jq -r .name | wc -l)
for i in $(seq 0 $(("$STORAGE_ACCOUNT_COUNT"-1))); do
    STORAGE_ACCOUNT_NAME=$(echo "$STORAGE_ACCOUNT_LIST" | jq -sr .["$i"].name)
    echo -e "\nChecking storage account $STORAGE_ACCOUNT_NAME for old blobs.\n"

    CONTAINER_LIST=$(az storage container list --account-name "$STORAGE_ACCOUNT_NAME" --only-show-errors)
    CONTAINER_COUNT=$(echo "$CONTAINER_LIST" | jq .[].name | wc -l)
    for i2 in $(seq 0 $(("$CONTAINER_COUNT"-1))); do
        CONTAINER_NAME=$(echo "$CONTAINER_LIST" | jq -r .["$i2"].name)
        BLOB_LIST=$(az storage blob list --account-name "$STORAGE_ACCOUNT_NAME" --container-name "$CONTAINER_NAME" --only-show-errors)
        BLOB_COUNT=$(echo "$BLOB_LIST" | jq .[].name | wc -l)
        for i3 in $(seq 0 $(("$BLOB_COUNT"-1))); do
            BLOB_NAME=$(echo "$BLOB_LIST" | jq -r .["$i3"].name)
            BLOB_TIME=$(echo "$BLOB_LIST" | jq -r .["$i3"].properties.lastModified)
            BLOB_TIME_SECONDS=$(date -d "$BLOB_TIME" +%s)
            if [[ "$BLOB_TIME_SECONDS" -lt "$DELETE_TIME" ]]; then
                if [ $DRY_RUN == "true" ]; then
                    echo "Blob $BLOB_NAME in $STORAGE_ACCOUNT_NAME's $CONTAINER_NAME container would get deleted."
                else
                    echo "Deleting blob $BLOB_NAME in $STORAGE_ACCOUNT_NAME's $CONTAINER_NAME container."
                    az storage blob delete --only-show-errors --account-name "$STORAGE_ACCOUNT_NAME" --container-name "$CONTAINER_NAME" -n "$BLOB_NAME"
                fi
            fi
        done
    done
done

#---------------------------------------------------------------
# 			AWS cleanup
#---------------------------------------------------------------

greenprint "Starting aws cleanup"

TEMPDIR=$(mktemp -d)
function cleanup() {
    sudo rm -rf "$TEMPDIR"
}
trap cleanup EXIT

# Check available container runtime
if which podman 2>/dev/null >&2; then
    CONTAINER_RUNTIME=podman
elif which docker 2>/dev/null >&2; then
    CONTAINER_RUNTIME=docker
else
    echo No container runtime found, install podman or docker.
    exit 2
fi

CONTAINER_IMAGE_CLOUD_TOOLS="quay.io/osbuild/cloud-tools:latest"
AWS_DEFAULT_REGION=$AWS_REGION

# We need awscli to talk to AWS.
if ! hash aws; then
    echo "Using 'awscli' from a container"
    sudo ${CONTAINER_RUNTIME} pull ${CONTAINER_IMAGE_CLOUD_TOOLS}

    AWS_CMD_NO_REGION="sudo ${CONTAINER_RUNTIME} run --rm \
        -e AWS_ACCESS_KEY_ID=${V2_AWS_ACCESS_KEY_ID} \
        -e AWS_SECRET_ACCESS_KEY=${V2_AWS_SECRET_ACCESS_KEY} \
        -e AWS_DEFAULT_REGION=${AWS_REGION} \
        -v ${TEMPDIR}:${TEMPDIR}:Z \
        ${CONTAINER_IMAGE_CLOUD_TOOLS} aws --output json --color on"
else
    echo "Using pre-installed 'aws' from the system"
    AWS_CMD_NO_REGION="aws --output json --color on"
fi
$AWS_CMD_NO_REGION --version

REGIONS=$(${AWS_CMD_NO_REGION} ec2 describe-regions | jq -rc '.Regions[] | select(.OptInStatus == "opt-in-not-required") | .RegionName') 

# We use resources in more than one region
for region in ${REGIONS}; do
    AWS_CMD="${AWS_CMD_NO_REGION} --region ${region}"
    greenprint "Cleaning ${region}"
    # Remove old enough instances that don't have tag persist=true
    echo -e "------------------\nCleaning instances\n------------------"
    INSTANCES=$(${AWS_CMD} ec2 describe-instances | tr -d "[:space:]" | jq -c '.Reservations[].Instances[]')

    for instance in ${INSTANCES}; do
        REMOVE=1
        INSTANCE_ID=$(echo "${instance}" | jq -r '.InstanceId')
        LAUNCH_TIME=$(echo "${instance}" | jq -r '.LaunchTime')

        if [[ $(date -d "${LAUNCH_TIME}" +%s) -gt "${DELETE_TIME}" ]]; then
            REMOVE=0
            echo "The instance with id ${INSTANCE_ID} was launched less than ${HOURS_BACK} hours ago"
        fi

        HAS_TAGS=$(echo ${instance} | jq  'has("Tags")')
        if [ ${HAS_TAGS} = true ]; then
            TAGS=$(echo "${instance}" | jq -c 'try .Tags[]')

            for tag in ${TAGS}; do
                    KEY=$(echo ${tag} | jq -r '.Key')
                    VALUE=$(echo ${tag} | jq -r '.Value')

                if [[ ${KEY} == "persist" && ${VALUE} == "true" ]]; then
                    REMOVE=0
                    echo "The instance with id ${INSTANCE_ID} has tag 'persist=true'"
                fi
            done
        fi

        if [ ${REMOVE} == 1 ]; then
            if [ $DRY_RUN == "true" ]; then
                echo "The instance with id ${INSTANCE_ID} would get terminated"
            else
                $AWS_CMD ec2 terminate-instances --instance-id "${INSTANCE_ID}"
                echo "The instance with id ${INSTANCE_ID} was terminated"
            fi
        fi
    done

    # Remove old enough images that don't have tag persist=true
    echo -e "---------------\nCleaning images\n---------------"
    IMAGES=$(${AWS_CMD} ec2 describe-images --owner self | tr -d "[:space:]" | jq -c '.Images[]')

    for image in ${IMAGES}; do
        REMOVE=1
        IMAGE_ID=$(echo "${image}" | jq -r '.ImageId')
        CREATION_DATE=$(echo "${image}" | jq -r '.CreationDate')

        if [[ $(date -d "${CREATION_DATE}" +%s) -gt "${DELETE_TIME}" ]]; then
            REMOVE=0
            echo "The image with id ${IMAGE_ID} was created less than ${HOURS_BACK} hours ago"
        fi

        HAS_TAGS=$(echo ${image} | jq  'has("Tags")')
        if [ ${HAS_TAGS} = true ]; then
            TAGS=$(echo "${image}" | jq -c 'try .Tags[]')

            for tag in ${TAGS}; do
                    KEY=$(echo ${tag} | jq -r '.Key')
                    VALUE=$(echo ${tag} | jq -r '.Value')

                if [[ ${KEY} == "persist" && ${VALUE} == "true" ]]; then
                    REMOVE=0
                    echo "The image with id ${IMAGE_ID} has tag 'persist=true'"
                fi
            done
        fi

        if [ ${REMOVE} == 1 ]; then
            if [ $DRY_RUN == "true" ]; then
                echo "The image with id ${IMAGE_ID} would get deregistered"
            else
                $AWS_CMD ec2 deregister-image --image-id "${IMAGE_ID}"
                echo "The image with id ${IMAGE_ID} was deregistered"
            fi
        fi
    done

    # Remove old enough snapshots that don't have tag persist=true
    echo -e "------------------\nCleaning snapshots\n------------------"
    SNAPSHOTS=$(${AWS_CMD} ec2 describe-snapshots --owner self | tr -d "[:space:]" | jq -c '.Snapshots[]')

    for snapshot in ${SNAPSHOTS}; do
        REMOVE=1
        SNAPSHOT_ID=$(echo "${snapshot}" | jq -r '.SnapshotId')
        START_TIME=$(echo "${snapshot}" | jq -r '.StartTime')

        if [[ $(date -d "${START_TIME}" +%s) -gt "${DELETE_TIME}" ]]; then
            REMOVE=0
            echo "The snapshot with id ${SNAPSHOT_ID} was created less than ${HOURS_BACK} hours ago"
        fi

        HAS_TAGS=$(echo ${snapshot} | jq  'has("Tags")')
        if [ ${HAS_TAGS} = true ]; then
            TAGS=$(echo "${snapshot}" | jq -c 'try .Tags[]')

            for tag in ${TAGS}; do
                    KEY=$(echo ${tag} | jq -r '.Key')
                    VALUE=$(echo ${tag} | jq -r '.Value')

                if [[ ${KEY} == "persist" && ${VALUE} == "true" ]]; then
                    REMOVE=0
                    echo "The snapshot with id ${SNAPSHOT_ID} has tag 'persist=true'"
                fi
            done
        fi

        if [ ${REMOVE} == 1 ]; then
            if [ $DRY_RUN == "true" ]; then
                echo "The snapshot with id ${SNAPSHOT_ID} would get deleted"
            else
                $AWS_CMD ec2 delete-snapshot --snapshot-id "${SNAPSHOT_ID}"
                echo "The snapshot with id ${SNAPSHOT_ID} was deleted"
            fi
        fi
    done
done

# Remove old enough objects that don't have tag persist=true
echo -e "----------------\nCleaning objects\n----------------"
OBJECTS=$($AWS_CMD s3api list-objects --bucket "${AWS_BUCKET}" | jq -c .Contents[])

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
        KEY=$(echo ${tag} | jq -r '.Key')
        VALUE=$(echo ${tag} | jq -r '.Value')

        if [[ ${KEY} == "persist" && ${VALUE} == "true" ]]; then
            REMOVE=0
            echo "The object with key ${OBJECT_KEY} has tag 'persist=true'"
        fi
    done

    if [ ${REMOVE} == 1 ]; then
        if [ $DRY_RUN == "true" ]; then
            echo "The object with key ${OBJECT_KEY} would get removed"
        else
            $AWS_CMD s3 rm "s3://${AWS_BUCKET}/${OBJECT_KEY}"
            echo "The object with key ${OBJECT_KEY} was removed"
        fi
    fi
done

#---------------------------------------------------------------
#                       GCP cleanup
#---------------------------------------------------------------

greenprint "starting gcp cleanup"

# We need Google Gloud SDK to comunicate with gcp
if ! hash gcloud; then
  echo "Using 'gcloud' from a container"
  sudo ${CONTAINER_RUNTIME} pull ${CONTAINER_IMAGE_CLOUD_TOOLS}

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

# List tagged intances and remove the old enough ones
echo -e "------------------\nCleaning instances\n------------------"
INSTANCES=$($GCP_CMD compute instances list --filter='NOT labels.persist:true AND NOT labels.persist:true' \
	| jq -c '.[] | {"name": .name, "creationTimestamp": .creationTimestamp, "zone": .zone}')

for instance in ${INSTANCES}; do                
	CREATION_TIME=$(echo "${instance}" | jq -r '.creationTimestamp')

        if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
                ZONE=$(echo "${instance}" | jq -r '.zone' | awk -F / '{print $NF}')
                NAME=$(echo "${instance}" | jq -r '.name')
                if [ $DRY_RUN == "true" ]; then
                    echo "instance ${NAME} would get deleted."
                else
                    $GCP_CMD compute instances delete --zone="$ZONE" "$NAME"
                    echo "deleted instance: ${NAME}"
                fi
        fi
done

# List tagged images and remove the old enough ones
echo -e "---------------\nCleaning images\n---------------"
IMAGES=$($GCP_CMD compute images list --filter='NOT labels.persist:true AND NOT labels.persist:true' \
	| jq -c '.[] | select(.selfLink|contains("cockpituous")) | {"name": .name, "creationTimestamp": .creationTimestamp}')

for image in $IMAGES; do
        CREATION_TIME=$(echo "${image}" | jq -r '.creationTimestamp')

        if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
                NAME=$(echo "${image}" | jq -r '.name')
                if [ $DRY_RUN == "true" ]; then
                    echo "image ${NAME} would get deleted."
                else
                    $GCP_CMD compute images delete "$NAME"
                    echo "deleted image: ${NAME}"
                fi
	    fi
done


#---------------------------------------------------------------
#                       vmware cleanup
#---------------------------------------------------------------

greenprint "starting vmware cleanup"

GOVC_CMD=/tmp/govc

# We need govc to talk to vSphere
if ! hash govc; then
    greenprint "Installing govc"
    pushd /tmp || exit
        curl -Ls --retry 5 --output govc.gz \
            https://github.com/vmware/govmomi/releases/download/v0.24.0/govc_linux_amd64.gz
        gunzip -f govc.gz
        chmod +x /tmp/govc
        $GOVC_CMD version
    popd || exit
fi

GOVC_AUTH="${GOVMOMI_USERNAME}:${GOVMOMI_PASSWORD}@${GOVMOMI_URL}"

TAGGED=$($GOVC_CMD tags.attached.ls -u "${GOVC_AUTH}" -k "gitlab-ci-test" | xargs -r ${GOVC_CMD} ls -u "${GOVC_AUTH}" -k -L)

for vm in $TAGGED; do
	# Could use JSON output, but it takes much longer, as it includes more properties
	CREATION_TIME=$($GOVC_CMD vm.info -u "${GOVC_AUTH}" -k "${vm}" | awk '$1 ~ /^ *Boot/ { print $3 " " $4 $5 }')
	
	if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
                $GOVC_CMD vm.destroy -u "${GOVC_AUTH}" -k "${vm}"
                echo "destroyed vm: ${vm}"
	fi
done
