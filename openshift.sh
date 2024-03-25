#!/bin/bash

set -euo pipefail

# Default is 6hrs, we want to clean up OpenShift more aggressively
# b/c resource quota is rather small
# WARNING: must be defined before we import the common library
HOURS_BACK="1"

# include the common library
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh"

TEMPDIR=$(mktemp -d)

# install the OpenShift cli & virtctl binary
sudo dnf -y install wget jq
# https://docs.openshift.com/container-platform/4.13/cli_reference/openshift_cli/getting-started-cli.html
wget --no-check-certificate https://downloads-openshift-console.apps.ocp-virt.prod.psi.redhat.com/amd64/linux/oc.tar --directory-prefix "$TEMPDIR"
# https://docs.openshift.com/container-platform/4.13/virt/virt-using-the-cli-tools.html
wget --no-check-certificate https://hyperconverged-cluster-cli-download-openshift-cnv.apps.ocp-virt.prod.psi.redhat.com/amd64/linux/virtctl.tar.gz --directory-prefix "$TEMPDIR"
pushd "$TEMPDIR"
tar -xvf oc.tar
tar -xzvf virtctl.tar.gz
popd
OC_CLI="$TEMPDIR/oc"
VIRTCTL="$TEMPDIR/virtctl"
chmod a+x "$OC_CLI"
chmod a+x "$VIRTCTL"


# Authenticate via the gitlab-ci service account
# oc describe secret gitab-ci-token-g7sw2
$OC_CLI login --token="$OPENSHIFT_TOKEN" --server=https://api.ocp-virt.prod.psi.redhat.com:6443 --insecure-skip-tls-verify=true
$OC_CLI whoami

OPENSHIFT_PROJECT="image-builder"
$OC_CLI project $OPENSHIFT_PROJECT

# iterate over VMs - note: remove the .spec.template field b/c cloud-init data contains
# unescaped newlines which break echo
ALL_VMS=$($OC_CLI get vm --output json | jq 'del(.items[].spec.template)' | jq 'del(.items[].status.volumeSnapshotStatuses)' | jq -c '.items[]')
for INSTANCE in ${ALL_VMS}; do
    REMOVE=1
    VM_NAME=$(echo "${INSTANCE}" | jq -r '.metadata.name')
    CREATION_TIME=$(echo "${INSTANCE}" | jq -r '.metadata.creationTimestamp')

    if [[ $(date -d "${CREATION_TIME}" +%s) -gt "${DELETE_TIME}" ]]; then
        REMOVE=0
        echo "The VM '${VM_NAME}' was launched less than ${HOURS_BACK} hours ago"
    fi

    # TODO: check for tag persist=true

    if [ ${REMOVE} == 1 ]; then
        if [ "$DRY_RUN" == "true" ]; then
            echo "The VM '${VM_NAME}' would be terminated"
        else
            $OC_CLI delete vm --cascade='foreground' --force=true --timeout=300s "$VM_NAME" || echo
            echo "The VM '${VM_NAME}' was terminated"
        fi
    fi
done

# wait 60 seconds before attemtping to remove any PVCs
# in case cascade removal is still running in the background
if [ "$DRY_RUN" != "true" ]; then
    sleep 60
fi

# iterate over PVCs - removing fields which break the echo command
ALL_PVCS=$($OC_CLI get pvc --output json | jq 'del(.items[].metadata.annotations)' | jq -c '.items[]')
for INSTANCE in ${ALL_PVCS}; do
    REMOVE=1
    PVC_NAME=$(echo "${INSTANCE}" | jq -r '.metadata.name')
    CREATION_TIME=$(echo "${INSTANCE}" | jq -r '.metadata.creationTimestamp')

    if [[ $(date -d "${CREATION_TIME}" +%s) -gt "${DELETE_TIME}" ]]; then
        REMOVE=0
        echo "PVC '${PVC_NAME}' was created less than ${HOURS_BACK} hours ago"
    fi

    # TODO: check for tag persist=true

    if [ ${REMOVE} == 1 ]; then
        if [ "$DRY_RUN" == "true" ]; then
            echo "The PVC '${PVC_NAME}' would be terminated"
        else
            $OC_CLI delete pvc --cascade='foreground' --force=true --timeout=300s "$PVC_NAME" || echo
            echo "The PVC '${PVC_NAME}' was terminated"
        fi
    fi
done

rm -rf "$TEMPDIR"
