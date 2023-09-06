#!/bin/bash

set -euo pipefail

# include the common library
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh"

#---------------------------------------------------------------
#                       vmware cleanup
#---------------------------------------------------------------

greenprint "starting vmware cleanup"

GOVC_CMD=/tmp/govc

# We need govc to talk to vSphere
if ! hash govc; then
    greenprint "Installing govc"
    pushd /tmp || exit
    curl -Ls --retry 5 --output govc.tar.gz \
        https://github.com/vmware/govmomi/releases/download/v0.30.4/govc_Linux_x86_64.tar.gz
    tar -xzvf govc.tar.gz
    chmod +x ./govc
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
    else
        echo "The instance ${vm} was launched less than ${HOURS_BACK} hours ago"
    fi
done
