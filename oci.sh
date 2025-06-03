#!/bin/bash

set -euo pipefail

# include the common library
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh"

#---------------------------------------------------------------
#                       OCI cleanup
#---------------------------------------------------------------

greenprint "🔮☁ Starting OCI cleanup"

if ! hash oci 2>/dev/null && [ ! -e /root/bin/oci ]; then
    echo 'No oci cli, cannot proceed'
    exit 1
fi

OCI_CONFIG=$(mktemp -p "${TEMPDIR}")
echo "$OCI_PRIV_KEY_DATA" > "${TEMPDIR}/priv_key.pem"
echo "$OCI_CONFIG_DATA" > "$OCI_CONFIG"
echo "key_file=${TEMPDIR}/priv_key.pem" >> "$OCI_CONFIG"

OCI_CMD="/root/bin/oci --config-file $OCI_CONFIG"
echo -n "OCI version: "
$OCI_CMD --version
$OCI_CMD setup repair-file-permissions --file "${TEMPDIR}/priv_key.pem"
$OCI_CMD setup repair-file-permissions --file "$OCI_CONFIG"

greenprint "🧹 Cleaning up instances"
INSTANCES=$($OCI_CMD compute instance list -c "$OCI_COMPARTMENT" | jq -r ".data[].id")
for i in $INSTANCES; do
    INSTANCE_DATA=$($OCI_CMD compute instance get --instance-id "$i" | jq -r ".data")

    if [[ $(echo "$INSTANCE_DATA" | jq -r '.["freeform-tags"].persist') = true ]]; then
        echo "Instance $i is tagged with persist=true"
        continue
    fi

    if [[ $(echo "$INSTANCE_DATA" | jq -r '.["lifecycle-state"]') = TERMINATED ]]; then
        echo "Instance $i already terminated"
        continue
    fi

    TIME_CREATED=$(echo "$INSTANCE_DATA" | jq -r '.["time-created"]')
    if [[ $(date -d "$TIME_CREATED" +%s) -gt "$DELETE_TIME" ]]; then
        echo "Instance $i was created less than $HOURS_BACK hours ago"
        continue
    fi

    if [ "$DRY_RUN" == "true" ]; then
        echo "Dry run, skipping termination of instance $i"
        continue
    fi

    echo "Terminating instance $i"
    $OCI_CMD compute instance terminate --force --instance-id "$i"
done

greenprint "🧹 Cleaning up images"
IMAGES=$($OCI_CMD compute image list -c "$OCI_COMPARTMENT" --all | jq -r ".data[] | select(.[\"compartment-id\"] == \"$OCI_COMPARTMENT\").id")
for i in $IMAGES; do
    IMAGE_DATA=$($OCI_CMD compute image get --image-id "$i" | jq -r ".data")

    if [[ $(echo "$IMAGE_DATA" | jq -r '.["freeform-tags"].persist') = true ]]; then
        echo "Image $i is tagged with persist=true"
        continue
    fi

    TIME_CREATED=$(echo "$IMAGE_DATA" | jq -r '.["time-created"]')
    if [[ $(date -d "$TIME_CREATED" +%s) -gt "$DELETE_TIME" ]]; then
        echo "IMAGE $i was created less than $HOURS_BACK hours ago"
        continue
    fi

    if [ "$DRY_RUN" == "true" ]; then
        echo "Dry run, skipping deletion of image $i"
        continue
    fi

    echo "Deleting image $i"
    $OCI_CMD compute image delete --force --image-id "$i"
done

greenprint "🔮☁ Finished OCI cleanup"
