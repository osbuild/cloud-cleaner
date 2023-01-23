#!/bin/bash

# include the common library
source $(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh

#---------------------------------------------------------------
# 			AWS cleanup
#---------------------------------------------------------------

greenprint "Starting aws cleanup"
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

        HAS_TAGS=$(echo ${instance} | jq 'has("Tags")')
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

        HAS_TAGS=$(echo ${image} | jq 'has("Tags")')
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

        HAS_TAGS=$(echo ${snapshot} | jq 'has("Tags")')
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
