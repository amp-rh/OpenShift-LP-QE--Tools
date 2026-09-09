.PHONY: build push clean help

IMAGE_REGISTRY ?= quay.io
IMAGE_NAMESPACE ?= redhatqe
IMAGE_NAME ?= bsod-detector
IMAGE_TAG ?= latest
IMAGE_FULL = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)

APP_DIR = apps/bsod-detector

build:
	@echo "Building container image: $(IMAGE_FULL)"
	podman build -t $(IMAGE_FULL) -f Dockerfile ../../../$(APP_DIR)

push: build
	@echo "Pushing container image: $(IMAGE_FULL)"
	podman push $(IMAGE_FULL)

clean:
	@echo "Removing local image: $(IMAGE_FULL)"
	podman rmi $(IMAGE_FULL) || true

help:
	@echo "BSOD Detector Container Build"
	@echo ""
	@echo "Available targets:"
	@echo "  build  - Build container image (default: $(IMAGE_FULL))"
	@echo "  push   - Build and push container image to registry"
	@echo "  clean  - Remove local container image"
	@echo ""
	@echo "Variables:"
	@echo "  IMAGE_REGISTRY  - Container registry (default: $(IMAGE_REGISTRY))"
	@echo "  IMAGE_NAMESPACE - Registry namespace (default: $(IMAGE_NAMESPACE))"
	@echo "  IMAGE_NAME      - Image name (default: $(IMAGE_NAME))"
	@echo "  IMAGE_TAG       - Image tag (default: $(IMAGE_TAG))"
	@echo ""
	@echo "Example:"
	@echo "  make build IMAGE_TAG=v1.0.0"
	@echo "  make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg IMAGE_TAG=v1.0.0"
