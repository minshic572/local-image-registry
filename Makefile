.PHONY: help harbor-install harbor-init start stop status logs inventory migrate cutover rollback connect-kind mirror-cilium lock clean-lock verify

DEFAULT_KIND_CLUSTER ?= cyber-resilience

help: ## Show available commands
	@echo "Harbor-backed Local Image Registry"
	@echo ""
	@echo "Deployment:"
	@echo "  make harbor-install  - Download, verify and install Harbor with Trivy on staging port"
	@echo "  make harbor-init     - Create projects and migration robot account"
	@echo "  make start           - Start the Harbor Compose stack"
	@echo "  make stop            - Stop Harbor and preserve data"
	@echo "  make status          - Show Harbor component and API health"
	@echo "  make logs            - Show recent Harbor logs"
	@echo ""
	@echo "Migration:"
	@echo "  make inventory       - Inventory registry:2 repositories, tags and digests"
	@echo "  make migrate         - Copy inventory to Harbor and verify digests"
	@echo "  make cutover         - Stop registry:2 and move Harbor from 5002 to 5001"
	@echo "  make rollback        - Stop Harbor and restart the preserved registry:2"
	@echo ""
	@echo "Operations:"
	@echo "  make connect-kind    - Configure kind containerd for Harbor"
	@echo "  make mirror-cilium   - Mirror configured Cilium images to Harbor"
	@echo "  make lock            - Generate the image lock file"
	@echo "  make verify          - Run static and unit checks"

harbor-install: ## Install Harbor with Trivy on the staging port
	./scripts/harbor-install.sh

harbor-init: ## Create Harbor projects and robot account
	./scripts/harbor-init.sh

start: ## Start Harbor
	./scripts/registry-start.sh

stop: ## Stop Harbor and preserve data
	./scripts/registry-stop.sh

status: ## Check Harbor status
	./scripts/registry-status.sh

logs: ## Show recent Harbor logs
	./scripts/harbor-manage.sh logs

inventory: ## Inventory the legacy registry:2 instance
	./scripts/registry-inventory.py --registry http://localhost:5001 --output output/registry-v2-inventory.json

migrate: ## Copy inventoried images to Harbor and verify digests
	./scripts/migrate-to-harbor.sh

cutover: ## Cut over from registry:2 to Harbor
	./scripts/harbor-cutover.sh

rollback: ## Roll back to registry:2
	./scripts/harbor-rollback.sh

connect-kind: ## Connect Harbor to kind cluster
	DEFAULT_KIND_CLUSTER=$(DEFAULT_KIND_CLUSTER) ./scripts/registry-connect-kind.sh

mirror-cilium: ## Mirror Cilium/Hubble images to Harbor
	./scripts/mirror-images.sh --config config/images.cilium.yaml

lock: ## Generate lock file without syncing
	./scripts/generate-lock.sh --config config/images.cilium.yaml

clean-lock: ## Remove generated reports and lock files
	rm -f output/*.json

verify: ## Run repository checks
	./tests/run.sh
