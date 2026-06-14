#!/usr/bin/env bash
# lib/image-prune.sh — keep only the last N successful Docker images per
# deployment. Old images get docker-image-rm'd; the durable record (release
# manifest + config + lockfile + logs) stays on disk so you can always
# rebuild any prior release from source.
#
# Called automatically by the deploy pipeline after a successful release.
# Can also be invoked manually: `nelly image-prune <name> [--keep N] [--dry-run]`.
#
# Safety rules:
#   - Never remove the image used by the currently running container.
#   - Never remove the deployment's :latest tag.
#   - Only consider tags for *this deployment's* image_name (so other
#     deployments' images are untouched).
#   - Skip any image referenced by the last N successful releases.

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"

DEPLOY_DIR="$1"; shift || true
KEEP="${NELLY_IMAGE_KEEP:-2}"
DRY_RUN=0
while (( $# > 0 )); do
    case "$1" in
        --keep)    KEEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) shift ;;
    esac
done

[[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a number"

CONFIG="$DEPLOY_DIR/def/config.json"
[[ -f "$CONFIG" ]] || die "no config at $CONFIG"

require_cmd docker jq
IMAGE_NAME="$(jqget "$CONFIG" '.image_name')"
CONTAINER_NAME="$(jqget "$CONFIG" '.container_name')"
RELEASES_IDX="$DEPLOY_DIR/def/releases.index.json"

# What's currently running for this deployment? Never prune it.
RUNNING_IMAGE=""
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    RUNNING_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
fi

# Pull the list of images this deployment owns (filtered by image_name).
mapfile -t ALL_TAGS < <(docker images "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}}' | sort -u)
if (( ${#ALL_TAGS[@]} == 0 )); then
    info "no $IMAGE_NAME images to prune"
    exit 0
fi

# Compute KEEP: the most recent N successful releases' images.
declare -a KEEP_IMAGES=()
if [[ -f "$RELEASES_IDX" ]]; then
    # successful releases in reverse-chronological order; pull image from each manifest
    mapfile -t recent_rel < <(
        jq -r '.releases | map(select(.outcome == "success")) | reverse | .[].release_id' "$RELEASES_IDX"
    )
    for rid in "${recent_rel[@]}"; do
        m="$DEPLOY_DIR/def/releases/$rid/manifest.json"
        [[ -f "$m" ]] || continue
        img="$(jq -r '.image // empty' "$m")"
        [[ -z "$img" ]] && continue
        KEEP_IMAGES+=("$img")
        (( ${#KEEP_IMAGES[@]} >= KEEP )) && break
    done
fi
# Always keep :latest and the currently-running image.
KEEP_IMAGES+=("$IMAGE_NAME:latest")
[[ -n "$RUNNING_IMAGE" ]] && KEEP_IMAGES+=("$RUNNING_IMAGE")

# Now compute the set difference: tags - keep.
declare -a TO_REMOVE=()
for tag in "${ALL_TAGS[@]}"; do
    skip=0
    for keep in "${KEEP_IMAGES[@]}"; do
        if [[ "$tag" == "$keep" ]]; then skip=1; break; fi
    done
    (( skip )) || TO_REMOVE+=("$tag")
done

if (( ${#TO_REMOVE[@]} == 0 )); then
    info "$IMAGE_NAME: nothing to prune (kept ${#KEEP_IMAGES[@]} image(s))"
    exit 0
fi

if (( DRY_RUN )); then
    info "(dry-run) would remove ${#TO_REMOVE[@]} image(s):"
    printf '   %s\n' "${TO_REMOVE[@]}" >&2
    exit 0
fi

info "pruning ${#TO_REMOVE[@]} old image(s) for $IMAGE_NAME (keeping last $KEEP successful + :latest + running)"
removed=0
for tag in "${TO_REMOVE[@]}"; do
    if docker image rm "$tag" >/dev/null 2>&1; then
        removed=$((removed+1))
        printf '   removed %s\n' "$tag" >&2
    else
        warn "could not remove $tag (still referenced?)"
    fi
done
info "pruned $removed image(s)"
