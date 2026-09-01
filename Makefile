ALLOY := ./scripts/alloy.py
ALLOY_MODELS := $(wildcard */alloy/*.als)
TLA := ./scripts/tla.py
TLA_DIRS := $(wildcard */tla)

.PHONY: help verify verify-alloy verify-tla commands models clean

help:
	@echo "make verify         # run every model checker in this repository"
	@echo "make verify-alloy   # run the Alloy 6 models ($(ALLOY_MODELS))"
	@echo "make verify-tla     # run the TLA+ models with TLC ($(TLA_DIRS))"
	@echo "make commands       # list the commands of every Alloy model"
	@echo "make models         # list the TLC models"
	@echo "make clean          # remove downloaded tools"
	@echo
	@echo "single model: $(ALLOY) verify approval_request/alloy/approval.als"
	@echo "single command: $(ALLOY) trace approval_request/alloy/approval.als selfApprovalIsAllowed"
	@echo "single TLC model: $(TLA) verify approval_request/tla --only MCSafety"
	@echo "TLC counterexample: $(TLA) trace approval_request/tla/MCScenarioRoundTrip.cfg"

verify: verify-alloy verify-tla

verify-alloy:
	@set -e; for model in $(ALLOY_MODELS); do \
		echo "== $$model"; \
		$(ALLOY) verify $$model; \
	done

verify-tla:
	@set -e; for dir in $(TLA_DIRS); do \
		echo "== $$dir"; \
		$(TLA) verify $$dir; \
	done

commands:
	@set -e; for model in $(ALLOY_MODELS); do \
		echo "== $$model"; \
		$(ALLOY) commands $$model; \
	done

models:
	@set -e; for dir in $(TLA_DIRS); do \
		echo "== $$dir"; \
		$(TLA) models $$dir; \
	done

clean:
	rm -rf .tools
