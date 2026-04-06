#!/bin/sh

capitalize() {
    printf "%s" "$1" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}' | tr -d '\n'
}

lowercase() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -d '\n'
}

build_date() {
    echo "(+) Retrieving build date from image: $1" >&2
    (
        set -x
        docker inspect -f '{{.Created}}' "$(docker images --no-trunc -q -f reference="$1")"
    )
    printf "\033[2m ~~~•~~~~•~~~~•~~~~•~~~~•~~~~•~~~~•~~~ \033[0m\n" >&2
}

tag_image() {
    [ -n "$1" ] && [ -n "$2" ] || return 0
    [ "$1" != "$2" ] || return 0
    echo "(*) Tagging Docker image '${1}' as '${2}'..." >&2
    (
        set -x
        docker tag "$1" "$2"
    )
    printf "\033[2m ~~~•~~~~•~~~~•~~~~•~~~~•~~~~•~~~~•~~~ \033[0m\n" >&2
}

tag_images() {
    _source_image="$1"
    shift
    for _target in "$@"; do
        tag_image "$_source_image" "$_target"
    done
    unset _source_image _target
}

pull_and_tag() {
    _registry_prefix="$1"
    _build_tag="$2"
    shift 2
    _image="${_registry_prefix}/${_build_tag}"
    echo "(+) Pulling image to local daemon and creating local tags..." >&2
    (
        set -x
        docker pull "${_image}"
    )
    tag_image "${_image}" "${_build_tag}"
    tag_images "${_image}" "$@"
    unset _registry_prefix _build_tag _image
}

remove_danglers() {
    echo "(+) Removing dangling Docker images..." >&2
    (
        set -x
        docker images \
            --filter label="org.opencontainers.image.ref.name=${1}" \
            --filter dangling=true -q \
            | xargs -r docker rmi
    )
    printf "\033[2m ~~~•~~~~•~~~~•~~~~•~~~~•~~~~•~~~~•~~~ \033[0m\n" >&2
}
