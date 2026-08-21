# Host-side BSOD tooling, containerized for podman (rootless-friendly).
#
# Purpose: recover and inspect Windows crash dumps from the OUTSIDE when the
# guest is frozen or won't boot. On a Linux/KVM host the equivalent of
# "mount the guest VHDX" is: open the qcow2 offline with libguestfs and copy
# C:\Windows\MEMORY.DMP + \Windows\Minidump\*.dmp out of the NTFS filesystem.
#
# This image bundles the deterministic host tools so the workflow is
# reproducible and does not pollute the host with packages:
#   - libguestfs-tools : virt-ls / virt-cat / virt-copy-out / guestfish (offline NTFS access)
#   - qemu-img         : inspect/convert disk images
#   - libvirt-client   : virsh, to query guest state (via mounted socket)
#   - python3          : dump-header parsing helpers
#
# Build:  podman build -t bsod-host-tools host-tools/
# Run:    use host-tools/run.sh (wires up the right mounts).
FROM registry.fedoraproject.org/fedora-minimal:41

# libguestfs needs an appliance; the package pulls a prebuilt one on Fedora.
RUN microdnf install -y \
        libguestfs-tools-c \
        qemu-img \
        libvirt-client \
        python3 \
        jq \
    && microdnf clean all

# libguestfs runs its own tiny KVM appliance; allow TCG fallback when the
# container has no /dev/kvm so extraction still works (just slower).
ENV LIBGUESTFS_BACKEND=direct

WORKDIR /work
COPY extract-dump.sh /usr/local/bin/extract-dump
RUN chmod +x /usr/local/bin/extract-dump

# Default: show usage.
ENTRYPOINT ["/usr/local/bin/extract-dump"]
CMD ["--help"]
