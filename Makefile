SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:
MAKEFLAGS += --no-print-directory

# Every user-supplied variable is taken literally: $(value VAR) stops Make from expanding
# $(...) inside command-line values. Separate override/export lines are required by macOS Make 3.81.
override CLUSTER := $(value CLUSTER)
override TENANT := $(value TENANT)
override UPSTREAM := $(value UPSTREAM)
override PROMPT := $(value PROMPT)
override PROMPT_FILE := $(value PROMPT_FILE)
override FORMAT := $(value FORMAT)
override REGION := $(value REGION)
override MODEL := $(value MODEL)
override MODEL_VERSION := $(value MODEL_VERSION)
override SKU := $(value SKU)
override CAPACITY := $(value CAPACITY)
override CONFIRM := $(value CONFIRM)
export CLUSTER TENANT UPSTREAM PROMPT PROMPT_FILE FORMAT REGION MODEL MODEL_VERSION SKU CAPACITY CONFIRM

DEV_TARGETS := help doctor up cluster-up gateway-install status k9s dashboard logs gateway-forward \
	grafana prometheus check down legacy-down
FOUNDRY_TARGETS := foundry-register foundry-regions foundry-models foundry-up foundry-status \
	gateway-configure endpoints foundry-down

.PHONY: $(DEV_TARGETS) $(FOUNDRY_TARGETS) prompt

$(DEV_TARGETS):
	@/bin/bash scripts/dev.sh $@

$(FOUNDRY_TARGETS):
	@/bin/bash scripts/foundry.sh $@

prompt:
	@/bin/bash scripts/prompt.sh
