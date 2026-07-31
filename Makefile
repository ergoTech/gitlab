.PHONY: help up down restart logs logs-gitlab logs-runner status ps clean backup restore get-password register-runner health registry-gc maintenance install-cron

# Default target
.DEFAULT_GOAL := help

# Address that cron mails when a maintenance run fails. Empty disables mail.
MAINTENANCE_MAILTO ?= root

# Colors
YELLOW := \033[1;33m
GREEN := \033[0;32m
RED := \033[0;31m
NC := \033[0m

help: ## Show this help message
	@echo "$(YELLOW)GitLab Docker Compose - Available Commands$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""

up: ## Start all services
	@echo "$(YELLOW)Starting GitLab...$(NC)"
	docker compose up -d
	@echo "$(GREEN)GitLab is starting. This may take 3-5 minutes.$(NC)"
	@echo "Run 'make logs' to watch the startup process."
	@echo "Run 'make health' to check when GitLab is ready."

down: ## Stop all services
	@echo "$(YELLOW)Stopping GitLab...$(NC)"
	docker compose down
	@echo "$(GREEN)GitLab stopped.$(NC)"

restart: ## Restart all services
	@echo "$(YELLOW)Restarting GitLab...$(NC)"
	docker compose restart
	@echo "$(GREEN)GitLab restarted.$(NC)"

logs: ## Show logs from all services
	docker compose logs -f

logs-gitlab: ## Show logs from GitLab only
	docker compose logs -f gitlab

logs-runner: ## Show logs from GitLab Runner only
	docker compose logs -f gitlab-runner

status: ## Show service status
	@docker compose ps

ps: status ## Alias for status

health: ## Check GitLab health status
	@echo "$(YELLOW)Checking GitLab health...$(NC)"
	@HEALTH=$$(docker inspect --format='{{.State.Health.Status}}' gitlab 2>/dev/null || echo "not running"); \
	if [ "$$HEALTH" = "healthy" ]; then \
		echo "$(GREEN)✓ GitLab is healthy and ready!$(NC)"; \
	elif [ "$$HEALTH" = "starting" ]; then \
		echo "$(YELLOW)⏳ GitLab is still starting...$(NC)"; \
	elif [ "$$HEALTH" = "unhealthy" ]; then \
		echo "$(RED)✗ GitLab is unhealthy. Check logs with 'make logs-gitlab'$(NC)"; \
	else \
		echo "$(RED)✗ GitLab is not running. Start with 'make up'$(NC)"; \
	fi

get-password: ## Get initial root password
	@./scripts/get-root-password.sh

register-runner: ## Register GitLab Runner
	@./scripts/register-runner.sh

backup: ## Create backup of all data
	@echo "$(YELLOW)Creating backup...$(NC)"
	@BACKUP_FILE="gitlab-backup-$$(date +%Y%m%d-%H%M%S).tar.gz"; \
	tar -czf $$BACKUP_FILE data/; \
	echo "$(GREEN)Backup created: $$BACKUP_FILE$(NC)"

restore: ## Restore from backup (usage: make restore BACKUP=filename.tar.gz)
	@if [ -z "$(BACKUP)" ]; then \
		echo "$(RED)Error: Please specify backup file$(NC)"; \
		echo "Usage: make restore BACKUP=gitlab-backup-YYYYMMDD-HHMMSS.tar.gz"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Stopping services...$(NC)"
	@docker compose down
	@echo "$(YELLOW)Restoring from $(BACKUP)...$(NC)"
	@tar -xzf $(BACKUP)
	@echo "$(YELLOW)Starting services...$(NC)"
	@docker compose up -d
	@echo "$(GREEN)Restore complete!$(NC)"

clean: ## Remove all containers, volumes, and data (DANGEROUS!)
	@echo "$(RED)WARNING: This will delete ALL GitLab data!$(NC)"
	@read -p "Are you sure? Type 'yes' to continue: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		echo "$(YELLOW)Stopping and removing containers...$(NC)"; \
		docker compose down -v; \
		echo "$(YELLOW)Removing data directory...$(NC)"; \
		rm -rf data/; \
		echo "$(GREEN)Cleanup complete.$(NC)"; \
	else \
		echo "$(GREEN)Cancelled.$(NC)"; \
	fi

shell-gitlab: ## Open shell in GitLab container
	docker exec -it gitlab bash

shell-runner: ## Open shell in Runner container
	docker exec -it gitlab-runner sh

update: ## Pull latest images and restart
	@echo "$(YELLOW)Pulling latest images...$(NC)"
	docker compose pull
	@echo "$(YELLOW)Restarting services...$(NC)"
	docker compose up -d
	@echo "$(GREEN)Update complete!$(NC)"

prune: ## Remove unused Docker resources
	@echo "$(YELLOW)Pruning unused Docker resources...$(NC)"
	docker system prune -f
	@echo "$(GREEN)Prune complete!$(NC)"


registry-gc: maintenance ## Alias for maintenance (registry GC runs through the same lock)

maintenance: ## Run the full disk maintenance pass now (docker + journal + registry GC)
	@echo "$(YELLOW)Running maintenance...$(NC)"
	sudo -E ./scripts/maintenance.sh --with-registry-gc
	@echo "$(GREEN)Maintenance complete!$(NC)"

install-cron: ## Install the scheduled maintenance (daily docker cleanup, weekly registry GC)
	@echo "$(YELLOW)Installing /etc/cron.d/gitlab-maintenance...$(NC)"
	@printf '%s\n' \
		'# Disk maintenance for the GitLab host - installed by `make install-cron`.' \
		'# Edit scripts/maintenance.sh in the repo, not this file.' \
		'SHELL=/bin/bash' \
		'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
		'# Only failures produce output, so mail means something is wrong.' \
		'MAILTO=$(MAINTENANCE_MAILTO)' \
		'' \
		'30 3 * * 1-6 root $(CURDIR)/scripts/maintenance.sh' \
		'30 3 * * 0 root $(CURDIR)/scripts/maintenance.sh --with-registry-gc' \
		'' | sudo tee /etc/cron.d/gitlab-maintenance > /dev/null
	@sudo chmod 644 /etc/cron.d/gitlab-maintenance
	@echo "$(GREEN)Installed. Schedule:$(NC)"
	@echo "  Mon-Sat 03:30  docker cache + old images + journal"
	@echo "  Sun     03:30  the above plus registry garbage collection"
	@echo "  Log: /var/log/gitlab-maintenance.log"
