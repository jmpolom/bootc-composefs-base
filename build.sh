#!/usr/bin/env bash

set -xeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# defaults
backend="composefs"
containerfile=""
name=""
registry=""
rel="44"
arch="x86_64"
ts="main"

declare -a tss=()
declare -a tagged_names=()
declare -a tag_opts=()
declare -a backend_build_opts=()

assert_not_empty() {
    local argn="$1"
    local val="$2" 

    if [ -z "$val" ]; then
        echo "Invalid argument for -$argn: must not be empty" >&2
        exit 2
    fi
}

while getopts ":a:b:c:d:n:r:s:" opt; do
    case ${opt} in
        a)
            assert_not_empty "a" "$OPTARG"
            arch="$OPTARG"
            ;;
        b)
            assert_not_empty "b" "$OPTARG"
            backend="$OPTARG"
            ;;
        c)
            assert_not_empty "c" "$OPTARG"
            containerfile="$OPTARG"
            ;;
        d)
            assert_not_empty "d" "$OPTARG"
            registry="$OPTARG"
            ;;
        n)
            assert_not_empty "n" "$OPTARG"
            name="$OPTARG"
            ;;
        r)
            assert_not_empty "r" "$OPTARG"
            rel="$OPTARG"
            ;;
        s)
            assert_not_empty "s" "$OPTARG"
            # tag suffixes
            tss+=("$OPTARG")
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Missing argument: -$OPTARG" >&2
            exit 2
            ;;
    esac
done

case "${backend}" in
    composefs)
        default_containerfile="Containerfile.composefs"
        default_name="fedora-bootc-composefs"
        ;;
    ostree)
        default_containerfile="Containerfile.ostree"
        default_name="fedora-bootc-ostree"
        # rpm-ostree compose rootfs requires FUSE and elevated build privileges.
        # Keep these limited to the OSTree build; the composefs image does not
        # require them.
        backend_build_opts=(
            "--security-opt=label=disable"
            "--cap-add=all"
            "--device=/dev/fuse"
        )
        ;;
    *)
        echo "Invalid argument for -b: expected composefs or ostree, got ${backend}" >&2
        exit 2
        ;;
esac

containerfile="${containerfile:-${default_containerfile}}"
name="${name:-${default_name}}"

if [[ ${containerfile} != /* ]]; then
    containerfile="${script_dir}/${containerfile}"
fi
if [[ ! -f ${containerfile} ]]; then
    echo "Containerfile does not exist: ${containerfile}" >&2
    exit 2
fi

case "${arch}" in
    x86_64)
        platform_arch="amd64"
        ;;
    aarch64)
        platform_arch="arm64"
        ;;
    *)
        echo "Invalid argument for -a: unsupported architecture: ${arch}" >&2
        exit 2
        ;;
esac

# construct image names with suffixed tags
if ((${#tss[@]})); then
    for t in "${tss[@]}"; do
        tagged_names+=("${name}:${rel}-${t}")
    done
else
    tagged_names+=("${name}:${rel}-${ts}")
fi

# construct array of tag opts for podman build
for n in "${tagged_names[@]}"; do
    tag_opts+=("-t" "${n}")
done

# build the container
podman build \
    --platform "linux/${platform_arch}" \
    --build-arg RELEASE="${rel}" \
    "${backend_build_opts[@]}" \
    "${tag_opts[@]}" \
    -f "${containerfile}" \
    "${script_dir}"

# push if a registry was specified
if [[ -n ${registry} ]]; then
    for n in "${tagged_names[@]}"; do
        podman push "${n}" "${registry}/${n}"
    done
fi
