#!/bin/bash

set -euo pipefail

# include the common library
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/common.sh"

#---------------------------------------------------------------
# 			AWS cleanup
#---------------------------------------------------------------

greenprint "Starting aws cleanup"

# This script is being rewritten in Python. So far, only the instance, AMI and snapshot cleanup is done in Python, so let's call it here.
if [ "$DRY_RUN" == "true" ]; then
    ./aws.py --dry-run --max-age "${HOURS_BACK}"
else
    ./aws.py --max-age "${HOURS_BACK}"
fi
