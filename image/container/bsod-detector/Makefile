SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

.PHONY: build push clean help validate test
.DEFAULT_GOAL := help
.NOTPARALLEL:

IMAGE_REGISTRY ?= quay.io
IMAGE_NAMESPACE ?= redhatqe
IMAGE_NAME ?= bsod-detector
IMAGE_TAG ?= latest
IMAGE_FULL = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)

APP_DIR = apps/bsod-detector

# Pre-flight validation: variable non-empty checks guard against CI overrides
# that set IMAGE_* to blank. The file-existence checks catch build-context
# misconfiguration before the slower podman-build step.
validate:
	@{ \
	    [ -n '$(IMAGE_REGISTRY)' ] || { echo 'ERROR: IMAGE_REGISTRY is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_NAMESPACE)' ] || { echo 'ERROR: IMAGE_NAMESPACE is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_NAME)' ] || { echo 'ERROR: IMAGE_NAME is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_TAG)' ] || { echo 'ERROR: IMAGE_TAG is empty' >&2; exit 1; }; \
	    [ -f Dockerfile ] || { echo 'ERROR: Dockerfile not found in current directory' >&2; exit 1; }; \
	    [ -d '../../../$(APP_DIR)/host-tools' ] || { echo 'ERROR: host-tools dir not found at ../../../$(APP_DIR)/host-tools' >&2; exit 1; }; \
	    echo 'Validation passed. IMAGE_FULL=$(IMAGE_FULL)'; \
	}

# Build container image
build: validate
	@{ \
	    echo 'Building container image: $(IMAGE_FULL)'; \
	    [ -d '../../../$(APP_DIR)' ] || { echo 'ERROR: Build context not found: ../../../$(APP_DIR)' >&2; exit 1; }; \
	    [ -f Dockerfile ] || { echo 'ERROR: Dockerfile not found in current directory' >&2; exit 1; }; \
	    podman build -t '$(IMAGE_FULL)' -f Dockerfile '../../../$(APP_DIR)'; \
	    echo 'Successfully built: $(IMAGE_FULL)'; \
	}

# Build and push to registry
push: validate build
	@{ \
	    echo 'Pushing container image to $(IMAGE_REGISTRY): $(IMAGE_FULL)'; \
	    podman push '$(IMAGE_FULL)'; \
	    echo 'Successfully pushed: $(IMAGE_FULL)'; \
	}

# Remove local image
clean:
	@{ \
	    echo 'Removing local image: $(IMAGE_FULL)'; \
	    podman rmi '$(IMAGE_FULL)' || true; \
	}

# Run BATS test suite
test:
	bats ../../../$(APP_DIR)/test/

# Display help
help:
	@{ \
	    echo 'BSOD Detector Container Build'; \
	    echo ''; \
	    echo 'Available targets:'; \
	    echo '  build    - Build container image (default: $(IMAGE_FULL))'; \
	    echo '  push     - Build and push container image to registry'; \
	    echo '  clean    - Remove local container image'; \
	    echo '  test     - Run BATS test suite'; \
	    echo '  validate - Validate required variables'; \
	    echo ''; \
	    echo 'Variables:'; \
	    echo '  IMAGE_REGISTRY  - Container registry (default: $(IMAGE_REGISTRY))'; \
	    echo '  IMAGE_NAMESPACE - Registry namespace (default: $(IMAGE_NAMESPACE))'; \
	    echo '  IMAGE_NAME      - Image name (default: $(IMAGE_NAME))'; \
	    echo '  IMAGE_TAG       - Image tag (default: $(IMAGE_TAG))'; \
	    echo ''; \
	    echo 'Examples:'; \
	    echo '  make build IMAGE_TAG=v1.0.0'; \
	    echo '  make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg IMAGE_TAG=v1.0.0'; \
	    echo '  make clean'; \
	}
