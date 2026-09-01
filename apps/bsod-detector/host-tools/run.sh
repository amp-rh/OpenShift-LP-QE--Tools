#!/usr/bin/env bash
# run.sh - run the bsod-host-tools container with the right podman mounts.
#
# Wraps `podman run` so the containerized libguestfs can read the guest qcow2
# and write recovered dumps into the project's git-ignored output dir.
#
# Podman conventions used here:
#   --rm                     ephemeral; no leftover containers
#   -v ...:...:ro,Z          read-only bind for the disk image; :Z relabels for SELinux
#   -v ...:...:Z             read-write bind for output; :Z relabels for SELinux
#   --userns=keep-id         files land owned by the invoking user (rootless)
#   --security-opt label=... only if relabel fails on a shared path
#
# Usage:
#   host-tools/run.sh --disk /var/lib/libvirt/images/bsod-test.qcow2
#   host-tools/run.sh --disk <img> --out ./output/dumps
#
# Build the image first (from the repo root):
#   make -C image/container/bsod-detector build IMAGE_TAG=host-tools
#   # or:  podman build -t bsod-host-tools \
#   #        -f image/container/bsod-detector/Dockerfile apps/bsod-detector
# Override the image name with BSOD_HOST_IMAGE if you tagged it differently.
set -euxo pipefail; shopt -s inherit_errexit

typeset image="${BSOD_HOST_IMAGE:-bsod-host-tools}"
typeset here=''
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset project=''
project="$(cd "${here}/.." && pwd)"

typeset disk=''; typeset out="${project}/output/dumps"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) disk="$2"; shift 2 ;;
    --out)  out="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${disk}" ]] || { echo "run.sh: --disk is required" >&2; exit 2; }
[[ -r "${disk}" ]] || { echo "run.sh: cannot read disk: ${disk} (need libvirt group or root)" >&2; exit 2; }
mkdir -p "${out}"

# The disk image lives under /var/lib/libvirt/images (root-owned). Rootless
# podman may not be able to read it; if so, run this wrapper via sudo or add an
# ACL. We bind the *file* read-only.
#
# SELinux: the disk under /var/lib/libvirt/images is typically root-owned with a
# libvirt label (virt_image_t). We must NOT use ':Z' on it - relabeling a file
# you don't own fails with EPERM and would also break libvirt's own access.
# Instead bind it ':ro' and disable label separation for this container so it
# can read the existing label. The output dir we own, so ':Z' is correct there.
typeset -a selinuxOpt=()
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  selinuxOpt=(--security-opt label=disable)
fi

exec podman run --rm \
  --userns=keep-id \
  "${selinuxOpt[@]}" \
  -v "${disk}":/images/"$(basename "${disk}")":ro \
  -v "${out}":/out:Z \
  "${image}" \
  --disk /images/"$(basename "${disk}")" --out /out
