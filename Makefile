# Pieceocraft — see README.md for the full picture.
# Every target here is safe to run from a clean checkout.
#
# Everything actually runs on the server named in ansible/inventory.ini, not
# on this machine — `deploy` goes through Ansible (which also bootstraps
# Docker there the first time); the day-to-day targets below just SSH over
# and run `docker compose` (or a helper inside the container) in the
# checkout Ansible made on the server, since that's simpler than reaching
# for Ansible for something this direct.

.DEFAULT_GOAL := help
ANSIBLE := ansible-playbook
SSH := ssh

# Extra flags forwarded to ansible-playbook — for password-based SSH:
#   make deploy ANSIBLE_ARGS="--ask-pass --ask-become-pass"
# (--ask-become-pass, the sudo password, is only actually used the first time,
# to install Docker — harmless to keep passing it after that.)
# Using an SSH key instead? Leave ANSIBLE_ARGS empty; the key lives in
# inventory.ini instead.
ANSIBLE_ARGS ?=

# Lines shown by `make logs`: make logs N=500
N ?= 100

# A single console command for `make cmd`, e.g. make cmd CMD="say hello"
CMD ?=

# A backup file for `make restore`, e.g.
#   make restore FILE=backups/pieceocraft-data-2026-09-16-1530.tar.gz
FILE ?=

# Parsed straight out of inventory.ini so every target below hits the same
# server `make deploy` does, without repeating the address everywhere.
# REMOTE_DIR matches deploy.yml's own default (pieceocraft_dir) — if you
# changed that there, change it here too.
REMOTE_HOST := $(shell awk '/^\[pieceocraft\]/{f=1;next} f && NF && $$1 !~ /^\[/{print $$1; exit}' ansible/inventory.ini 2>/dev/null)
REMOTE_USER := $(shell awk '/^\[pieceocraft\]/{f=1;next} f && NF && $$1 !~ /^\[/{for(i=1;i<=NF;i++) if ($$i ~ /^ansible_user=/) print substr($$i, index($$i,"=")+1); exit}' ansible/inventory.ini 2>/dev/null)
REMOTE_DIR := pieceocraft
REMOTE := $(SSH) $(REMOTE_USER)@$(REMOTE_HOST)
CONTAINER := pieceocraft-bedrock

.PHONY: help deploy up down restart ps logs pull console cmd backup restore destroy check check-remote

help: ## Show this help
	@echo "Pieceocraft"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  First run:"
	@echo "    cp ansible/vars.yml.example ansible/vars.yml && \$$EDITOR ansible/vars.yml"
	@echo "    cp ansible/inventory.ini.example ansible/inventory.ini && \$$EDITOR ansible/inventory.ini"
	@echo "    make deploy ANSIBLE_ARGS=\"--ask-pass --ask-become-pass\""

deploy: check ## Set up Docker (first run only) and the Bedrock server on the server
	@cd ansible && $(ANSIBLE) deploy.yml $(ANSIBLE_ARGS)

up: check-remote ## Start the server (no configuration)
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose up -d'

down: check-remote ## Stop the server (the world is kept)
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose down'

restart: down up ## Restart the server

ps: check-remote ## Show whether the server is running
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose ps'

logs: check-remote ## Tail the server log: make logs N=500
	@$(SSH) -t $(REMOTE_USER)@$(REMOTE_HOST) 'cd $(REMOTE_DIR) && docker compose logs -f --tail=$(N)'

pull: check-remote ## Pull the pinned wrapper image again and recreate the container
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose pull && docker compose up -d'

console: check-remote ## Attach to the live server console (Ctrl-p Ctrl-q to detach WITHOUT stopping it)
	@$(SSH) -t $(REMOTE_USER)@$(REMOTE_HOST) 'cd $(REMOTE_DIR) && docker attach $(CONTAINER)'

cmd: check-remote ## Run one console command, e.g. make cmd CMD="say hello"
	@test -n "$(CMD)" || { echo 'Usage: make cmd CMD="say hello"'; exit 1; }
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose exec -T bedrock send-command $(CMD)'

# Stops the server so the world can't be mid-write, tars data/ straight over
# SSH into a local file (nothing extra left behind on the server), then
# starts the server back up. This IS the migration path: back up here, then
# `make deploy` + `make restore` on whatever server you move to next.
backup: check-remote ## Stop, tar up the world, download it, start again
	@mkdir -p backups
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose stop'
	@$(REMOTE) 'cd $(REMOTE_DIR) && tar czf - data' > backups/pieceocraft-data-$$(date +%Y-%m-%d-%H%M).tar.gz
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose start'
	@echo "Saved to backups/pieceocraft-data-$$(date +%Y-%m-%d-%H%M).tar.gz"

# Deliberately interactive: this overwrites whatever world is currently on
# the server with the one in FILE. Meant for moving to a fresh server (run
# `make deploy` there first so the checkout and .env exist), not everyday use.
restore: check-remote ## Replace the server's world with a backup: make restore FILE=backups/....tar.gz
	@test -n "$(FILE)" || { echo 'Usage: make restore FILE=backups/pieceocraft-data-....tar.gz'; exit 1; }
	@test -f "$(FILE)" || { echo "$(FILE) not found"; exit 1; }
	@echo "This replaces the world currently on $(REMOTE_HOST) with $(FILE)."
	@printf "Type 'yes' to continue: " && read ans && [ "$$ans" = "yes" ]
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose stop'
	@cat "$(FILE)" | $(REMOTE) 'cd $(REMOTE_DIR) && rm -rf data && tar xzf -'
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose start'
	@echo "Restored. The server is back up."

# Deliberately noisy and interactive: this deletes the world on the server.
destroy: check-remote ## Remove the container AND the world on the server (asks first)
	@echo "This deletes data/ on $(REMOTE_HOST) — the whole world is gone."
	@printf "Type 'yes' to continue: " && read ans && [ "$$ans" = "yes" ]
	@$(REMOTE) 'cd $(REMOTE_DIR) && docker compose down -v && rm -rf data'
	@echo "Removed. Run 'make deploy' to start a fresh world."

# Guard rail: the most common first-run mistakes are forgetting to create
# vars.yml/inventory.ini, or not having Ansible itself yet — Docker is no
# longer this machine's problem, the playbook installs it on the server.
check:
	@test -f ansible/vars.yml || { \
		echo "ansible/vars.yml is missing."; \
		echo "Create it first:  cp ansible/vars.yml.example ansible/vars.yml"; \
		exit 1; }
	@test -f ansible/inventory.ini || { \
		echo "ansible/inventory.ini is missing."; \
		echo "Create it first:  cp ansible/inventory.ini.example ansible/inventory.ini"; \
		exit 1; }
	@command -v ansible-playbook >/dev/null || { \
		echo "ansible is not installed.  brew install ansible"; exit 1; }

# Same idea, for the targets that skip Ansible and SSH over directly.
check-remote: check
	@if [ -z "$(REMOTE_HOST)" ] || [ "$(REMOTE_HOST)" = "SERVER_IP" ]; then \
		echo "ansible/inventory.ini still has the placeholder SERVER_IP."; \
		echo "Edit it with your server's real address first."; exit 1; fi
