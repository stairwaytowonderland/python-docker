#!/usr/bin/env bash
# shellcheck disable=SC1091

# ./docker/bin/build.sh \
#   cpython \
#   --build-arg USERNAME=appuser \
#   --build-arg PYTHON_VERSION=3.14 \
#   --no-cache
#   --progress=plain
#   .

echo "(ƒ) Preparing for Docker image build..." >&2

# ---------------------------------------
set -euo pipefail

if [ -z "$0" ]; then
    echo "(!) Cannot determine script path" >&2
    exit 1
fi

script_name="$0"
script_dir="$(cd "$(dirname "$script_name")" && pwd)"
# ---------------------------------------

# Specify last argument as context if it's a directory
last_arg="${*: -1}"
# Parse first argument as IMAGE_NAME, second as REMOTE_USER (if not a build-arg or option)
first_arg="${1-}"
[ -z "$first_arg" ] || shift
# Check if next argument begins with '-' (indicating a build-arg or option)
# (if so, do not consume it as the second argument)
second_arg=""
if [ $# -gt 0 ]; then
    case "$1" in
        -*) ;;
        "$last_arg"*)
            [ $# -gt 1 ] || {
                second_arg="$1"
                shift
                last_arg=""
            }
            ;;
        *)
            second_arg="$1"
            shift
            ;;
    esac
else
    case "$first_arg" in
        "$last_arg"*) last_arg="" ;;
    esac
fi

. "${script_dir}/loader.sh" "${script_dir}/.."

# ---------------------------------------

DEFAULT_TARGET="${DEFAULT_TARGET:-base}"
DEFAULT_BASE_IMAGE_NAME="${DEFAULT_BASE_IMAGE_NAME:-ubuntu}"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-$DEFAULT_BASE_IMAGE_NAME}"
BASE_IMAGE_VARIANT="${BASE_IMAGE_VARIANT:-latest}"
DEFAULT_PLATFORM="linux/$(uname -m)"
[ "$BASE_IMAGE_VARIANT" = "latest" ] \
    && BASE_IMAGE_REF="$BASE_IMAGE_NAME" \
    || BASE_IMAGE_REF="${BASE_IMAGE_VARIANT}"
REGISTRY_HOST="${REGISTRY_HOST:-registry-1.docker.io}"
REGISTRY_PROVIDER="${REGISTRY_PROVIDER:-Docker Hub}"
REPO_NAMESPACE="${REPO_NAMESPACE-}"
REPO_NAME="${REPO_NAME-}"

# Determine Docker context
if [ -d "$last_arg" ]; then
    BUILD_CONTEXT="$last_arg"
else
    BUILD_CONTEXT="${BUILD_CONTEXT:-${script_dir}/../..}"
fi
if [ ! -d "$BUILD_CONTEXT" ]; then
    echo "(!) Docker context directory not found at expected path: $BUILD_CONTEXT" >&2
    exit 1
fi
# Determine IMAGE_NAME and DOCKER_TARGET
IMAGE_NAME="${IMAGE_NAME:-$first_arg}"
if [ -z "$IMAGE_NAME" ]; then
    echo "Usage: $0 <image-name[:build_target]> [build-args...] [options] [context]" >&2
    exit 1
fi
if [ -n "${IMAGE_NAME##*:}" ] && [ "${IMAGE_NAME##*:}" != "$IMAGE_NAME" ]; then
    DOCKER_TARGET="${IMAGE_NAME##*:}"
    IMAGE_NAME="${IMAGE_NAME%%:*}"
fi
DOCKER_TARGET="${DOCKER_TARGET:-$DEFAULT_TARGET}"
# Determine REMOTE_USER (the devcontainer non-root user, e.g., 'vscode' or 'devcontainer')
REMOTE_USER="${REMOTE_USER:-$second_arg}"
TAG_SUFFIX="${TAG_SUFFIX:-$DOCKER_TARGET}"
[ -n "${TAG_PREFIX-}" ] && TAG_SUFFIX="$DOCKER_TARGET" || TAG_PREFIX="$DOCKER_TARGET"
build_tag="${IMAGE_NAME}:${BASE_IMAGE_REF}"

if [ "$BASE_IMAGE_VARIANT" = "latest" ] || [ -n "$TAG_PREFIX" ]; then
    tag_prefix="${IMAGE_NAME}:${TAG_PREFIX}"
    build_tag="${tag_prefix}-${BASE_IMAGE_REF}"
fi

if [ "$TAG_PREFIX" = "latest" ]; then
    build_tag="${IMAGE_NAME}:${BASE_IMAGE_REF}"
fi

[ "$TAG_SUFFIX" = "$DEFAULT_TARGET" ] || build_tag="${build_tag}-${TAG_SUFFIX}"

dockerfile_path="${BUILD_CONTEXT}/docker/Dockerfile"
tag_variant=$(echo "$TAG_PREFIX" | cut -d- -f2-)

if [ ! -f "$dockerfile_path" ]; then
    echo "(!) Dockerfile not found at expected path: ${dockerfile_path}" >&2
    exit 1
fi

tag_image() {
    local source_image="$1"
    local target_image="$2"
    echo "(*) Tagging Docker image '${source_image}' as '${target_image}'..." >&2
    (
        set -x
        docker tag "$source_image" "$target_image"
    )
    echo -e "\033[2m~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\033[0m" >&2
}

pull_and_tag() {
    local registry_prefix="$1"
    local build_tag="$2"
    shift 2
    local tags=("$@")
    local image="${registry_prefix}/${build_tag}"
    echo "(+) Pulling image to local daemon and creating local tags..." >&2
    (
        set -x
        docker pull "${image}"
    )
    [ "${image}" = "${build_tag}" ] || tag_image "${image}" "${build_tag}"
    for tag in "${tags[@]}"; do
        [ -z "$tag" ] || [ "$tag" = "$build_tag" ] || tag_image "${image}" "${tag}"
    done
}

echo "(*) Building Docker image for ${build_tag}..." >&2
echo "(*) Dockerfile path: ${dockerfile_path}" >&2
echo "(*) Docker context: ${BUILD_CONTEXT}" >&2

if [ -z "${version_tag-}" ] && [ "$BASE_IMAGE_NAME" = "$DEFAULT_BASE_IMAGE_NAME" ] && [ "$DOCKER_TARGET" = "$DEFAULT_TARGET" ] && [ "${LATEST:-false}" != "true" ]; then
    if [ "$tag_variant" != "ext" ] && [ "$tag_variant" != "perf" ]; then
        echo -n "(*) Also tagging with version ... " >&2
        version_tag="${IMAGE_NAME}:${TAG_PREFIX}"
        echo "'${version_tag}'" >&2
    fi
elif [ -z "${unstable_tag-}" ] && [ "$DOCKER_TARGET" = "$DEFAULT_TARGET" ] && [ "${UNSTABLE:-false}" = "true" ]; then
    echo -n "(*) Also tagging with unstable ... " >&2
    unstable_tag="${IMAGE_NAME}:unstable"
    echo "'${unstable_tag}'" >&2
elif [ -z "${latest_tag-}" ] && [ "$DOCKER_TARGET" = "$DEFAULT_TARGET" ] && [ "${LATEST:-false}" = "true" ]; then
    echo -n "(*) Also tagging with major version ... " >&2
    # major_version_tag="${IMAGE_NAME}:${TAG_PREFIX%%.*}"
    major_version_tag="${IMAGE_NAME}:3"
    echo "'${major_version_tag}'" >&2
    echo -n "(*) Also tagging with latest ... " >&2
    latest_tag="${IMAGE_NAME}:latest"
    echo "'${latest_tag}'" >&2
fi

com_arg=()
com_arg+=("--build-arg" "IMAGE_NAME=${BASE_IMAGE_NAME}")
com_arg+=("--build-arg" "VARIANT=${BASE_IMAGE_VARIANT}")
if [ -n "$REMOTE_USER" ]; then
    com_arg+=("--build-arg" "USERNAME=${REMOTE_USER}")
fi
com_arg+=("--build-arg" "TIMEZONE=$(zoneinfo)")
# Automatically pass build arguments prefixed with DOCKER_BUILD_
# Strip the prefix and pass the variable to docker build
while IFS='=' read -r name value; do
    if [[ $name == DOCKER_BUILD_*   ]]; then
        arg_name="${name#DOCKER_BUILD_}"
        com_arg+=("--build-arg" "${arg_name}=${value}")
    fi
done < <(env)
for arg in "$@"; do
    if [ "$arg" != "$BUILD_CONTEXT" ]; then
        com_arg+=("$arg")
    fi
done

common_com=("-f" "${dockerfile_path}")
common_com+=("--label" "org.opencontainers.image.ref.name=${build_tag}")
common_com+=("--target" "${DOCKER_TARGET}")
common_com+=("--platform=$(dedupe "${PLATFORM:-$DEFAULT_PLATFORM}")")

local_tag_com=("-t" "${build_tag}")
[ -z "${version_tag-}" ]       || local_tag_com+=("-t" "${version_tag}")
[ -z "${unstable_tag-}" ]      || local_tag_com+=("-t" "${unstable_tag}")
[ -z "${major_version_tag-}" ] || local_tag_com+=("-t" "${major_version_tag}")
[ -z "${latest_tag-}" ]        || local_tag_com+=("-t" "${latest_tag}")

if [ "${USE_BUILDX:-true}" != "true" ]; then
    echo "(*) Building Docker image without pushing..." >&2

    build_com=(docker build)
    build_com+=("${common_com[@]}")
    build_com+=("${local_tag_com[@]}")
    build_com+=("${com_arg[@]}")
    build_com+=("$BUILD_CONTEXT")

    set -- "${build_com[@]}"
    . "${script_dir}/executer.sh" "$@"
else
    echo "(*) Building and pushing Docker image with provenance and sbom attestations..." >&2

    if ! . "${script_dir}/login.sh" "${REGISTRY_USER:-${REPO_NAMESPACE}}" "${REPO_NAME:-${IMAGE_NAME}}"; then
        echo "Error: Not logged in to ${REGISTRY_PROVIDER} Container Registry." >&2
        exit 1
    elif [ -z "${REGISTRY_URL_PREFIX-}" ]; then
        echo "Error: REGISTRY_URL_PREFIX is not set." >&2
        exit 1
    fi
    IMAGE_VERSION="${IMAGE_VERSION:-latest}"
    REGISTRY_URL="${REGISTRY_URL_PREFIX}/${build_tag}"

    registry_tag_com=("-t" "${REGISTRY_URL_PREFIX}/${build_tag}")
    [ -z "${version_tag-}" ]       || registry_tag_com+=("-t" "${REGISTRY_URL_PREFIX}/${version_tag}")
    [ -z "${unstable_tag-}" ]      || registry_tag_com+=("-t" "${REGISTRY_URL_PREFIX}/${unstable_tag}")
    [ -z "${major_version_tag-}" ] || registry_tag_com+=("-t" "${REGISTRY_URL_PREFIX}/${major_version_tag}")
    [ -z "${latest_tag-}" ]        || registry_tag_com+=("-t" "${REGISTRY_URL_PREFIX}/${latest_tag}")

    buildx_com=(docker buildx build)
    buildx_com+=("${common_com[@]}")
    buildx_com+=("--provenance=mode=max")
    buildx_com+=("--sbom=true")
    if [ "${NO_PUSH:-false}" != "true" ]; then
        buildx_com+=("--cache-from" "type=registry,ref=${REGISTRY_URL}-build-cache")
        buildx_com+=("--cache-to" "type=registry,ref=${REGISTRY_URL}-build-cache,mode=max")
        buildx_com+=("--push")
        buildx_com+=("${registry_tag_com[@]}")
    else
        buildx_com+=("--load")
        buildx_com+=("${local_tag_com[@]}")
    fi
    buildx_com+=("${com_arg[@]}")
    buildx_com+=("$BUILD_CONTEXT")

    set -- "${buildx_com[@]}"
    . "${script_dir}/executer.sh" "$@"

    # Comment out when running in a CI pipeline
    [ "${NO_PUSH:-false}" = "true" ] || pull_and_tag "${REGISTRY_URL_PREFIX}" "${build_tag}" "${version_tag-}" "${unstable_tag-}" "${latest_tag-}" "${major_version_tag-}"
fi

echo "(√) Done! Docker image build complete." >&2
# echo "_______________________________________" >&2
echo >&2
