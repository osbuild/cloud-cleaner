#!/bin/bash

# include the common library
source $(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh

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
