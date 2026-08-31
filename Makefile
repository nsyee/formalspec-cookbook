ALLOY := ./scripts/alloy.py
ALLOY_MODELS := $(wildcard */alloy/*.als)

.PHONY: help verify verify-alloy commands clean

help:
	@echo "make verify         # run every model checker in this repository"
	@echo "make verify-alloy   # run the Alloy 6 models ($(ALLOY_MODELS))"
	@echo "make commands       # list the commands of every Alloy model"
	@echo "make clean          # remove downloaded tools"
	@echo
	@echo "single model: $(ALLOY) verify approval_request/alloy/approval.als"
	@echo "single command: $(ALLOY) trace approval_request/alloy/approval.als selfApprovalIsAllowed"

verify: verify-alloy

verify-alloy:
	@set -e; for model in $(ALLOY_MODELS); do \
		echo "== $$model"; \
		$(ALLOY) verify $$model; \
	done

commands:
	@set -e; for model in $(ALLOY_MODELS); do \
		echo "== $$model"; \
		$(ALLOY) commands $$model; \
	done

clean:
	rm -rf .tools
