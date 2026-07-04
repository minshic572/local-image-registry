.PHONY: help start stop status connect-kind mirror-cilium lock clean

DEFAULT_REGISTRY_PORT ?= 5001
DEFAULT_KIND_CLUSTER ?= cyber-resilience

help: ## Show this help message
	@echo "Local Image Registry Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make start           - Start the local registry"
	@echo "  make stop            - Stop the registry (keep data)"
	@echo "  make stop-purge      - Stop and delete registry (remove data)"
	@echo "  make status          - Check registry status"
	@echo "  make connect-kind    - Connect registry to kind cluster"
	@echo "  make mirror-cilium   - Mirror Cilium/Hubble images"
	@echo "  make lock            - Generate lock file from config"
	@echo ""
	@echo "Environment variables:"
	@echo "  DEFAULT_REGISTRY_PORT - Registry port (default: 5001)"
	@echo "  DEFAULT_KIND_CLUSTER   - Kind cluster name (default: cyber-resilience)"

start: ## Start the local registry
	./scripts/registry-start.sh

stop: ## Stop the registry (keep data)
	./scripts/registry-stop.sh

stop-purge: ## Stop and delete registry (remove data)
	./scripts/registry-stop.sh --purge

status: ## Check registry status
	./scripts/registry-status.sh

connect-kind: ## Connect registry to kind cluster
	./scripts/registry-connect-kind.sh

mirror-cilium: ## Mirror Cilium/Hubble images
	./scripts/mirror-images.sh --config config/images.cilium.yaml

lock: ## Generate lock file from config
	./scripts/generate-lock.sh --config config/images.cilium.yaml

clean: ## Clean output directory
	rm -f output/*.json
