.PHONY: build push clean help validate
.DEFAULT_GOAL := help
.NOTPARALLEL:

IMAGE_REGISTRY ?= quay.io
IMAGE_NAMESPACE ?= redhatqe
IMAGE_NAME ?= bsod-detector
IMAGE_TAG ?= latest
IMAGE_FULL = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)

APP_DIR = apps/bsod-detector
OCP_CLIENT_URL ?=
OCP_CLIENT_SHA256 ?=
VIRTCTL_URL ?=
VIRTCTL_SHA256 ?=

# Validate required variables before using them
validate:
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    [ -n '$(IMAGE_REGISTRY)' ] || { echo 'ERROR: IMAGE_REGISTRY is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_NAMESPACE)' ] || { echo 'ERROR: IMAGE_NAMESPACE is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_NAME)' ] || { echo 'ERROR: IMAGE_NAME is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_TAG)' ] || { echo 'ERROR: IMAGE_TAG is empty' >&2; exit 1; }; \
	    [ -n '$(OCP_CLIENT_URL)' ] || { echo 'ERROR: OCP_CLIENT_URL is empty' >&2; exit 1; }; \
	    [ -n '$(OCP_CLIENT_SHA256)' ] || { echo 'ERROR: OCP_CLIENT_SHA256 is empty' >&2; exit 1; }; \
	    [ -n '$(VIRTCTL_URL)' ] || { echo 'ERROR: VIRTCTL_URL is empty' >&2; exit 1; }; \
	    [ -n '$(VIRTCTL_SHA256)' ] || { echo 'ERROR: VIRTCTL_SHA256 is empty' >&2; exit 1; }; \
	    echo 'Validation passed. IMAGE_FULL=$(IMAGE_FULL)'; \
	}

# Build container image
build: validate
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    echo 'Building container image: $(IMAGE_FULL)'; \
	    [ -d '../../../$(APP_DIR)' ] || { echo 'ERROR: Application not found: ../../../$(APP_DIR)' >&2; exit 1; }; \
	    [ -f Dockerfile ] || { echo 'ERROR: Dockerfile not found in current directory' >&2; exit 1; }; \
	    podman build -t '$(IMAGE_FULL)' \
	        --build-arg 'OCP_CLIENT_URL=$(OCP_CLIENT_URL)' \
	        --build-arg 'OCP_CLIENT_SHA256=$(OCP_CLIENT_SHA256)' \
	        --build-arg 'VIRTCTL_URL=$(VIRTCTL_URL)' \
	        --build-arg 'VIRTCTL_SHA256=$(VIRTCTL_SHA256)' \
	        -f Dockerfile \
	        '../../..'; \
	    echo 'Successfully built: $(IMAGE_FULL)'; \
	}

# Build and push to registry
push: validate build
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    echo 'Pushing container image to $(IMAGE_REGISTRY): $(IMAGE_FULL)'; \
	    podman push '$(IMAGE_FULL)'; \
	    echo 'Successfully pushed: $(IMAGE_FULL)'; \
	}

# Remove local image
clean:
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    echo 'Removing local image: $(IMAGE_FULL)'; \
	    podman rmi '$(IMAGE_FULL)' || true; \
	}

# Display help
help:
	@{ \
	    echo 'BSOD Detector Container Build'; \
	    echo ''; \
	    echo 'Available targets:'; \
	    echo '  build    - Build container image (default: $(IMAGE_FULL))'; \
	    echo '  push     - Build and push container image to registry'; \
	    echo '  clean    - Remove local container image'; \
	    echo '  validate - Validate required variables'; \
	    echo ''; \
	    echo 'Variables:'; \
	    echo '  IMAGE_REGISTRY  - Container registry (default: $(IMAGE_REGISTRY))'; \
	    echo '  IMAGE_NAMESPACE - Registry namespace (default: $(IMAGE_NAMESPACE))'; \
	    echo '  IMAGE_NAME      - Image name (default: $(IMAGE_NAME))'; \
	    echo '  IMAGE_TAG       - Image tag (default: $(IMAGE_TAG))'; \
	    echo '  OCP_CLIENT_URL / OCP_CLIENT_SHA256 - pinned OpenShift client archive'; \
	    echo '  VIRTCTL_URL / VIRTCTL_SHA256       - pinned virtctl binary'; \
	    echo ''; \
	    echo 'Examples:'; \
	    echo '  make build OCP_CLIENT_URL=<url> OCP_CLIENT_SHA256=<sha> VIRTCTL_URL=<url> VIRTCTL_SHA256=<sha>'; \
	    echo '  make push OCP_CLIENT_URL=<url> OCP_CLIENT_SHA256=<sha> VIRTCTL_URL=<url> VIRTCTL_SHA256=<sha>'; \
	    echo '  make clean'; \
	}
