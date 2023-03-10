#!/bin/bash

# include the common library
source $(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh

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

az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"

#---------------------------------------------------------------

# List all resources
RESOURCE_LIST=$(az resource list)
RESOURCE_COUNT=$(echo "$RESOURCE_LIST" | jq .[].name | wc -l)

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
STORAGE_ACCOUNT_LIST=$(az resource list --resource-type Microsoft.Storage/storageAccounts | jq -c ".[] | select(.tags.\"persist\" != \"true\")")
STORAGE_ACCOUNT_COUNT=$(echo "$STORAGE_ACCOUNT_LIST" | jq -r .name | wc -l)
for i in $(seq 0 $(("$STORAGE_ACCOUNT_COUNT" - 1))); do
    STORAGE_ACCOUNT_NAME=$(echo "$STORAGE_ACCOUNT_LIST" | jq -sr .["$i"].name)
    echo -e "\nChecking storage account $STORAGE_ACCOUNT_NAME for old blobs.\n"

    CONTAINER_LIST=$(az storage container list --account-name "$STORAGE_ACCOUNT_NAME" --only-show-errors)
    CONTAINER_COUNT=$(echo "$CONTAINER_LIST" | jq .[].name | wc -l)
    for i2 in $(seq 0 $(("$CONTAINER_COUNT" - 1))); do
        CONTAINER_NAME=$(echo "$CONTAINER_LIST" | jq -r .["$i2"].name)
        BLOB_LIST=$(az storage blob list --account-name "$STORAGE_ACCOUNT_NAME" --container-name "$CONTAINER_NAME" --only-show-errors)
        BLOB_COUNT=$(echo "$BLOB_LIST" | jq .[].name | wc -l)
        for i3 in $(seq 0 $(("$BLOB_COUNT" - 1))); do
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
