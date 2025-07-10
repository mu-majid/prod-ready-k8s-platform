# =============================================================================
# Terraform Platform Management Makefile
# =============================================================================

# Define the layers in deployment order
LAYERS := 01_foundation 02_platform 03_platform 04_observability 05_resilience 100_app

# Colors for output
BLUE := \033[0;34m
GREEN := \033[0;32m
RED := \033[0;31m
YELLOW := \033[1;33m
NC := \033[0m

# Default target
.DEFAULT_GOAL := help

# =============================================================================
# HELP
# =============================================================================

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "🏗️  Terraform Platform Management"
	@echo ""
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Available layers: $(LAYERS)"
	@echo ""

# =============================================================================
# DEPLOYMENT COMMANDS
# =============================================================================

.PHONY: deploy
deploy: ## Deploy all layers in order
	@echo "$(BLUE)🚀 Deploying all platform layers...$(NC)"
	@for layer in $(LAYERS); do \
		if [ -d $$layer ]; then \
			echo "$(BLUE)📁 Processing layer: $$layer$(NC)"; \
			cd $$layer && \
			terraform init && \
			terraform plan -out=tfplan && \
			terraform apply -auto-approve tfplan && \
			rm -f tfplan && \
			cd .. && \
			echo "$(GREEN)✅ Layer $$layer deployed successfully$(NC)" && \
			sleep 5; \
		else \
			echo "$(YELLOW)⚠️  Directory $$layer not found, skipping...$(NC)"; \
		fi; \
	done
	@echo "$(GREEN)🎉 All layers deployed successfully!$(NC)"

.PHONY: destroy
destroy: ## Destroy all layers in reverse order
	@echo "$(RED)⚠️  This will destroy ALL infrastructure!$(NC)"
	@read -p "Are you sure? (yes/no): " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		echo "$(RED)🔥 Destroying all platform layers...$(NC)"; \
		for layer in 04_observability 03_platform 02_platform 01_foundation; do \
			if [ -d $$layer ]; then \
				echo "$(RED)📁 Destroying layer: $$layer$(NC)"; \
				cd $$layer && \
				terraform init > /dev/null 2>&1 && \
				terraform destroy -auto-approve && \
				cd .. && \
				echo "$(GREEN)✅ Layer $$layer destroyed$(NC)" && \
				sleep 3; \
			else \
				echo "$(YELLOW)⚠️  Directory $$layer not found, skipping...$(NC)"; \
			fi; \
		done; \
		echo "$(GREEN)🎉 All layers destroyed successfully!$(NC)"; \
	else \
		echo "$(BLUE)Operation cancelled$(NC)"; \
	fi