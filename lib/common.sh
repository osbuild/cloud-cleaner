# c-inspired include guard to ensure these bits are sourced only once
if [ -z "$COMMON_INCLUDED" ]; then
    COMMON_INCLUDED=YES

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
        -h | --help)
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
fi
