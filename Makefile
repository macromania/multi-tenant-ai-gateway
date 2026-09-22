SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:
MAKEFLAGS += --no-print-directory

# Separate override/export directives are required by macOS Make 3.81.
override PROMPT := $(value PROMPT)
override PROMPT_FILE := $(value PROMPT_FILE)
override FORMAT := $(value FORMAT)
override REGION := $(value REGION)
override MODEL := $(value MODEL)
override MODEL_VERSION := $(value MODEL_VERSION)
override SKU := $(value SKU)
override CAPACITY := $(value CAPACITY)
override CONFIRM := $(value CONFIRM)
export PROMPT PROMPT_FILE FORMAT REGION MODEL MODEL_VERSION SKU CAPACITY CONFIRM

.PHONY: help doctor up cluster-up gateway-install status logs gateway-forward check test
.PHONY: foundry-register foundry-regions foundry-models foundry-up foundry-status
.PHONY: gateway-configure endpoints prompt down foundry-down

help doctor up cluster-up gateway-install status logs gateway-forward check down:
	@/bin/bash scripts/dev.sh $@

foundry-register foundry-regions foundry-models foundry-up foundry-status gateway-configure endpoints foundry-down:
	@/bin/bash scripts/foundry.sh $@

prompt:
	@/bin/bash scripts/prompt.sh

test:
	@/bin/bash tests/dev-test.sh
