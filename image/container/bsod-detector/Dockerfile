# BSOD Detector — unified host-side container image.
#
# Supports two operating modes controlled by the MODE environment variable:
#
#   MODE=watch   (default)
#     Watch a KubeVirt Windows VM for natural or intentional BSODs via
#     qemu-guest-agent pings. Calls watch-crash.sh. Requires oc login
#     (in-cluster ServiceAccount or mounted KUBECONFIG).
#
#   MODE=recover
#     Evidence recovery for a hard-frozen VM (guest won't reboot).
#     Calls recover-natural-crash.sh — runs virsh dump + ODF snapshot
#     → libguestfs extraction of MEMORY.DMP and Minidumps.
#
#   MODE=extract
#     Offline dump extraction from a guest disk image via libguestfs.
#     Calls extract-dump. Pass --disk / --out as CMD args.
#     Original use case — run via host-tools/run.sh on a KVM host.
#
# All target parameters come from environment variables — nothing is
# hardcoded to a specific VM, namespace, or cluster:
#
#   GA_VM                  VM name (required for watch/recover)
#   GA_NS                  Kubernetes namespace (required for watch/recover)
#   WATCH_INTERVAL         Seconds between QGA pings        (default: 5)
#   WATCH_MISS             Missed pings before crash declared (default: 2)
#   WATCH_REBOOT_WAIT      Seconds to wait for guest reboot  (default: 300)
#   EVIDENCE_DIR           Output directory                  (default: /evidence)
#
# Build (from repo root apps/bsod-detector/):
#   podman build -t bsod-detector -f image/container/bsod-detector/Dockerfile .
#   make -C image/container/bsod-detector build
#
# Run examples:
#   # Watch a VM for natural crashes
#   podman run --rm -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
#     -v ./evidence:/evidence bsod-detector
#
#   # Recover evidence from a hard-frozen VM
#   podman run --rm -e MODE=recover \
#     -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
#     -v ./evidence:/evidence bsod-detector
#
#   # Offline dump extraction from a disk image (original use case)
#   podman run --rm -e MODE=extract \
#     -v /path/to/guest.qcow2:/disk.qcow2:ro -v ./out:/out \
#     bsod-detector --disk /disk.qcow2 --out /out
#
FROM registry.fedoraproject.org/fedora-minimal:41

# ── System packages ──────────────────────────────────────────────────────────
# libguestfs-tools : virt-copy-out / guestfish  (MODE=extract + MODE=recover PATH2)
# libvirt-client   : virsh (virsh dump --memory-only for MODE=recover PATH1)
# python3 + pip    : guest-agent.py, parse-dump-header.sh helper
# python-evtx      : offline .evtx event log parsing
# jq               : JSON processing in all shell scripts
# xxd              : binary dump parsing in parse-dump-header.sh
# tar / curl       : oc CLI download
RUN <<run-EOF
set -euxo pipefail; shopt -s inherit_errexit
microdnf install -y \
    libguestfs-tools-c \
    qemu-img \
    libvirt-client \
    python3 \
    python3-pip \
    jq \
    xxd \
    curl \
    tar
pip3 install --no-cache-dir python-evtx
microdnf clean all
run-EOF

# ── oc CLI ───────────────────────────────────────────────────────────────────
# Required for MODE=watch and MODE=recover:
#   oc exec  → reach virt-launcher pod → virsh qemu-agent-command
#   oc get   → resolve VMI, pod names, node
#   oc cp    → copy extracted dumps from recovery pod
#   oc debug → capture worker node kernel log for host-signals
ARG OCP_VERSION=stable-4.22
RUN <<oc-EOF
set -euxo pipefail
curl -fsSL \
  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz" \
  | tar -xz -C /usr/local/bin oc kubectl
chmod +x /usr/local/bin/oc /usr/local/bin/kubectl
oc version --client
oc-EOF

# ── Scripts ──────────────────────────────────────────────────────────────────
# Build context is apps/bsod-detector/ (set by Makefile / podman build -f ... .)
# All host scripts are copied so the image is self-contained — no volume mounts
# required for scripts, only for evidence output and optional KUBECONFIG.
COPY src/scripts/host/watch-crash.sh          /usr/local/bin/watch-crash
COPY src/scripts/host/recover-natural-crash.sh /usr/local/bin/recover-natural-crash
COPY src/scripts/host/guest-agent.py          /usr/local/bin/guest-agent.py
COPY src/scripts/host/parse-dump-header.sh    /usr/local/bin/parse-dump-header
COPY src/scripts/host/collect-host-signals.sh /usr/local/bin/collect-host-signals
COPY src/data/bugcheck-codes.json             /usr/share/bsod-detector/bugcheck-codes.json
COPY host-tools/extract-dump.sh               /usr/local/bin/extract-dump
RUN chmod +x \
    /usr/local/bin/watch-crash \
    /usr/local/bin/recover-natural-crash \
    /usr/local/bin/parse-dump-header \
    /usr/local/bin/collect-host-signals \
    /usr/local/bin/extract-dump

# ── Environment defaults ─────────────────────────────────────────────────────
# All overridable at runtime via -e / env: in a pod spec / Deployment.
# GA_VM and GA_NS have no default — they are required for watch/recover.
ENV MODE=watch \
    GA_VM="" \
    GA_NS="" \
    WATCH_INTERVAL=5 \
    WATCH_MISS=2 \
    WATCH_REBOOT_WAIT=300 \
    EVIDENCE_DIR=/evidence \
    LIBGUESTFS_BACKEND=direct \
    HOME=/tmp

# Evidence and bugcheck-codes data paths
RUN mkdir -p /evidence
# Let parse-dump-header.sh find bugcheck-codes.json via BSOD_CODES_FILE
ENV BSOD_CODES_FILE=/usr/share/bsod-detector/bugcheck-codes.json

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY image/container/bsod-detector/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /evidence
ENTRYPOINT ["/entrypoint.sh"]
CMD []
