#!/bin/bash

CMD="$1"

source "/usr/local/bin/scripts/functions.sh"
script_path="$(realpath "${BASH_SOURCE[0]}")"
self="$script_path"


# compute the script directory and make rr relative to it
SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
rr="--root $SCRIPT_DIR/containers --runroot $SCRIPT_DIR/containers/tmp"

log "Script directory: $SCRIPT_DIR"
log "Root and runroot dirs: $SCRIPT_DIR/containers{/tmp}"

arch=$(uname -m)
case "$arch" in
    x86_64) arch=amd64;;
    aarch64|arm64) arch=arm64;;
    armv7l|armv7) arch=arm;;
    i386|i686) arch=386;;
esac


pm(){
    /usr/bin/podman $rr "$@"
}
pmc(){
    /usr/bin/podman-compose --podman-args "$rr" "$@"
}


case "$CMD" in

    "update-images")
        shift
        log "Updating images..."

        # FILTER="ghcr.io/hotio"
        FILTER="${1:-}"
        get_images(){
            pm images --format "{{.Repository}}:{{.Tag}}" | grep "$FILTER" | sort -u
        }

        log "Getting list of images..."
        images=()
        while IFS= read -r line; do
            images+=("$line")
        done < <(get_images)
        new_image=false

        if [ ${#images[@]} -eq 0 ]; then
            log "No images found to check."
            exit 2
        fi

        for image in "${images[@]}"; do
            log "---------- Checking image: ----------"

            # If the image specifies a registry, skip localhost/127.* registry pulls
            registry="${image%%/*}"
            if [ "$registry" != "$image" ]; then
                case "$registry" in
                    localhost*|127.*)
                        log "Skipping pull for localhost registry image: $image"
                        log "-------------------------------------"
                        continue
                        ;;
                esac
            fi
            # Skip images with missing repo or tag (e.g. <none>:<none>)
            repo="${image%%:*}"
            tag="${image##*:}"
            if [ -z "$repo" ] || [ -z "$tag" ] || [ "$repo" = "<none>" ] || [ "$tag" = "<none>" ]; then
                log "Skipping invalid or untagged image entry: $image"
                log "-------------------------------------"
                continue
            fi

            # Always pull the image (idempotent, only downloads if changed)
            log "Pulling $image"

            pm pull -q "$image"

            # Get the pulled image's digest and image ID (after pull)
            PULLED_DIGEST=$(pm images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' | awk -v img="$image" '$1==img {print $2}')
            PULLED_IMAGE_ID=$(pm images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk -v img="$image" '$1==img {print $2}')
            # log "Pulled digest: $PULLED_DIGEST"
            # log "Pulled image ID: $PULLED_IMAGE_ID"

            # Find all containers (running or not) using this image reference (repo:tag)
            CONTAINERS=$(pm ps -a --format '{{.ID}} {{.Image}}' | awk -v img="$image" '$2==img {print $1}')
            if [ -z "$CONTAINERS" ]; then
                log "No containers found for $image."
                log "-------------------------------------"
                continue
            fi

            for cid in $CONTAINERS; do
                # Get the image ID and digest currently used by the container
                CONTAINER_IMAGE_ID=$(pm inspect --format '{{.Image}}' "$cid")
                CONTAINER_IMAGE_DIGEST=$(pm inspect --format '{{.Digest}}' "$CONTAINER_IMAGE_ID" 2>/dev/null)
                # Debug output
                # log "Container $cid uses image ID: $CONTAINER_IMAGE_ID"
                # log "Container $cid image digest: $CONTAINER_IMAGE_DIGEST"

                # Compare container's current image ID to the newly pulled image ID
                if [ "$CONTAINER_IMAGE_ID" = "$PULLED_IMAGE_ID" ]; then
                    log "Container $cid is up-to-date (image ID matches)."
                    continue
                fi

                # If not, compare by digest as fallback
                if [ -n "$CONTAINER_IMAGE_DIGEST" ] && [ "$PULLED_DIGEST" = "$CONTAINER_IMAGE_DIGEST" ]; then
                    log "Container $cid is up-to-date (digest matches)."
                    continue
                fi

                log "Container $cid needs update (image ID and digest mismatch)."
                new_image=true
                # Here you could add logic to restart/recreate the container
            done
            log "-------------------------------------"
        done

        if [ "$new_image" == true ]; then
            log "At least one container has an update available."
            # Exit 0 indicates updates were applied
            exit 0
        else
            log "No images were updated."
            # Exit 2 indicates a normal no-op (no updates available)
            exit 2
        fi
        ;;

    "upgrade-pod")
        shift
        yaml="${1:-./compose.yml}"
        # pm play kube -q --start=false --replace --log-driver=k8s-file --log-opt path=./logs/oc.log --log-opt max-size=15M "$yaml"
        pm play kube -q --start=false --log-driver=none --replace "$yaml"
        ;;

    "create-container")
        shift
        file="$1"
        shift
        pmc "$@" -f "$file" up --no-start 
        ;;

    "compose")
        shift
        pmc "$@"
        ;;

    *)
        args="$@"
        pm $args

esac
exit 0
