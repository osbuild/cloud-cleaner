#!/bin/bash

# Colorful output.
function greenprint {
    echo -e "\033[1;32m[$(date -Isecond)] ${1}\033[0m"
}

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

HOURS_BACK="${HOURS_BACK:-6}"
DELETE_TIME=$(date -d "- $HOURS_BACK hours" +%s)

TAGGED=$(az rest --method GET --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resources" \
--url-parameters api-version=2020-06-01 \$expand=createdTime,tags \$select=name,createdTime \
| jq -c '.value[] | try {"gitlab-ci-test": .tags."gitlab-ci-test","Id": .id, "CreatedTime": .createdTime} | select(."gitlab-ci-test" != null)')

for resource in $TAGGED; do
    CREATION_TIME=$(echo "${resource}" | jq .CreatedTime | tr -d '"')
    RESOURCE_ID=$(echo "${resource}" | jq .Id | tr -d '"')

	if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
                az resource delete --ids ${RESOURCE_ID}
                echo "destroyed resource: ${RESOURCE_ID}"
	fi
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

# We need awscli to talk to AWS.
if ! hash aws; then
    echo "Using 'awscli' from a container"
    sudo ${CONTAINER_RUNTIME} pull ${CONTAINER_IMAGE_CLOUD_TOOLS}

    AWS_CMD="sudo ${CONTAINER_RUNTIME} run --rm \
        -e AWS_ACCESS_KEY_ID=${V2_AWS_ACCESS_KEY_ID} \
        -e AWS_SECRET_ACCESS_KEY=${V2_AWS_SECRET_ACCESS_KEY} \
        -v ${TEMPDIR}:${TEMPDIR}:Z \
        ${CONTAINER_IMAGE_CLOUD_TOOLS} aws --region $AWS_REGION --output json --color on"
else
    echo "Using pre-installed 'aws' from the system"
    AWS_CMD="aws --region $AWS_REGION --output json --color on"
fi
$AWS_CMD --version


# Remove tagged and old enough instances
INSTANCES=$(${AWS_CMD} ec2 describe-instances | jq -c '.Reservations[].Instances[]|try {"Tag": .Tags[],"InstanceId": .InstanceId,"LaunchTime": .LaunchTime}')

for instance in ${INSTANCES}; do
	TAG=$(echo "${instance}" | jq '.Tag.Key' | tr -d '"')
	TAG_VALUE=$(echo "${instance}" | jq '.Tag.Value' | tr -d '"')
	INSTANCE_ID=$(echo "${instance}" | jq '.InstanceId' | tr -d '"')
	LAUNCH_TIME=$(echo "${instance}" | jq '.LaunchTime' | tr -d '"')

	if [[ ${TAG} == "gitlab-ci-test" && ${TAG_VALUE} == "true" ]]; then	
		if [[ $(date -d "${LAUNCH_TIME}" +%s) -lt "${DELETE_TIME}" ]]; then
			$AWS_CMD ec2 terminate-instances --instance-id "${INSTANCE_ID}"
			echo "The instance with id ${INSTANCE_ID} was terminated"
        	else
        		echo "The instance with id ${INSTANCE_ID} was launched less than ${HOURS_BACK} hours ago"
		fi
	fi
done


# Remove tagged and old enough images
IMAGES=$($AWS_CMD ec2 describe-images --owner self | jq -c '.Images[] | try {"Tag": .Tags[], "ImageId": .ImageId, "CreationDate": .CreationDate}')

for image in ${IMAGES}; do
	TAG=$(echo "${image}" | jq '.Tag.Key' | tr -d '"')
	TAG_VALUE=$(echo "${image}" | jq '.Tag.Value' | tr -d '"')
	IMAGE_ID=$(echo "${image}" | jq '.ImageId' | tr -d '"')
	CREATION_DATE=$(echo "${image}" | jq '.CreationDate' | tr -d '"')

	if [[ ${TAG} == "gitlab-ci-test" && ${TAG_VALUE} == "true" ]]; then
		if [[ $(date -d "${CREATION_DATE}" +%s) -lt "${DELETE_TIME}" ]]; then
			$AWS_CMD ec2 deregister-image --image-id "${IMAGE_ID}"
			echo "The image with id ${IMAGE_ID} was deregistered"
		else
			echo "The image with id ${IMAGE_ID} was created less than ${HOURS_BACK} hours ago"
		fi
	fi
done

# Remove tagged and old enough snapshots
SNAPSHOTS=$($AWS_CMD --color on ec2 describe-snapshots --owner self | jq -c '.Snapshots[] | try {"Tag": .Tags[], "SnapshotId": .SnapshotId, "StartTime": .StartTime}')

for snapshot in ${SNAPSHOTS}; do
	TAG=$(echo "${snapshot}" | jq '.Tag.Key' | tr -d '"')
	TAG_VALUE=$(echo "${snapshot}" | jq '.Tag.Value' | tr -d '"')
	SNAPSHOT_ID=$(echo "${snapshot}" | jq '.SnapshotId' | tr -d '"')
	START_TIME=$(echo "${snapshot}" | jq '.StartTime' | tr -d '"')

	if [[ ${TAG} == "gitlab-ci-test" && ${TAG_VALUE} == "true" ]]; then
		if [[ $(date -d "${START_TIME}" +%s) -lt "${DELETE_TIME}" ]]; then
			$AWS_CMD ec2 delete-snapshot --snapshot-id "${SNAPSHOT_ID}"
			echo "The snapshot with id ${SNAPSHOT_ID} was deleted"
		else
			echo "The snapshot with id ${SNAPSHOT_ID} was created less than ${HOURS_BACK} hours ago"
		fi
	fi
done

# Remove tagged and old enough s3 objects
OBJECTS=$($AWS_CMD s3api list-objects --bucket "${AWS_BUCKET}" | jq -c .Contents[])

for object in ${OBJECTS}; do
        LAST_MODIFIED=$(echo "${object}" | jq '.LastModified' | tr -d '"')
        OBJECT_KEY=$(echo "${object}" | jq '.Key' | tr -d '"')

        if [[ $(date -d "${LAST_MODIFIED}" +%s) -lt ${DELETE_TIME} ]]; then
                TAG=$($AWS_CMD s3api get-object-tagging --bucket "${AWS_BUCKET}" --key "${OBJECT_KEY}" | jq .TagSet[0].Key | tr -d '"')
                TAG_VALUE=$($AWS_CMD s3api get-object-tagging --bucket "${AWS_BUCKET}" --key "${OBJECT_KEY}" | jq .TagSet[0].Value | tr -d '"')

                if [[ ${TAG} == "gitlab-ci-test" && ${TAG_VALUE} == "true" ]]; then
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
INSTANCES=$($GCP_CMD compute instances list --filter='labels.gitlab-ci-test:true' \
	| jq -c '.[] | {"name": .name, "creationTimestamp": .creationTimestamp, "zone": .zone}')

for instance in ${INSTANCES}; do                
	CREATION_TIME=$(echo "${instance}" | jq '.creationTimestamp' | tr -d '"')

        if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
                ZONE=$(echo "${instance}" | jq '.zone' | awk -F / '{print $NF}' | tr -d '"')
                NAME=$(echo "${instance}" | jq '.name' | tr -d '"')
                $GCP_CMD compute instances delete --zone="$ZONE" "$NAME"
                echo "deleted instance: ${NAME}"
        fi
done

# List tagged images and remove the old enough ones
IMAGES=$($GCP_CMD compute images list --filter='labels.gitlab-ci-test:true' \
	| jq -c '.[] | {"name": .name, "creationTimestamp": .creationTimestamp}')

for image in $IMAGES; do
        CREATION_TIME=$(echo "${image}" | jq '.creationTimestamp' | tr -d '"')

        if [[ $(date -d "${CREATION_TIME}" +%s) -lt ${DELETE_TIME} ]]; then
                NAME=$(echo "${image}" | jq '.name' | tr -d '"')
                $GCP_CMD compute images delete "$NAME"
                echo "deleted image: ${NAME}"        
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
