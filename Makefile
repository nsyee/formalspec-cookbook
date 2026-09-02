ALLOY := ./scripts/alloy.py
ALLOY_MODELS := $(wildcard */alloy/*.als)
TLA := ./scripts/tla.py
TLA_DIRS := $(wildcard */tla)
QUINT := ./scripts/quint.py
QUINT_DIRS := $(wildcard */quint)
CEDAR := ./scripts/cedar.py
CEDAR_DIRS := $(wildcard */cedar)
SOUTHER := ./scripts/souther.py
SOUTHER_DIRS := $(wildcard */souther)

.PHONY: help verify verify-alloy verify-tla verify-quint verify-cedar verify-souther commands models checks clean

help:
	@echo "make verify         # run every model checker in this repository"
	@echo "make verify-alloy   # run the Alloy 6 models ($(ALLOY_MODELS))"
	@echo "make verify-tla     # run the TLA+ models with TLC ($(TLA_DIRS))"
	@echo "make verify-quint   # run the Quint models ($(QUINT_DIRS))"
	@echo "make verify-cedar   # run the Cedar models ($(CEDAR_DIRS))"
	@echo "make verify-souther # run the Souther models ($(SOUTHER_DIRS))"
	@echo "make commands       # list the commands of every Alloy model"
	@echo "make models         # list the TLC models"
	@echo "make checks         # list the Quint, Cedar and Souther checks"
	@echo "make clean          # remove downloaded tools"
	@echo
	@echo "single model: $(ALLOY) verify approval_request/alloy/approval.als"
	@echo "single command: $(ALLOY) trace approval_request/alloy/approval.als selfApprovalIsAllowed"
	@echo "single TLC model: $(TLA) verify approval_request/tla --only MCSafety"
	@echo "TLC counterexample: $(TLA) trace approval_request/tla/MCScenarioRoundTrip.cfg"
	@echo "single Quint check: $(QUINT) verify approval_request/quint --only safety"
	@echo "Quint counterexample: $(QUINT) trace approval_request/quint --only liveness-no-fairness"
	@echo "Quint typecheck: $(QUINT) typecheck approval_request/quint/models.qnt"
	@echo "single Cedar check: $(CEDAR) verify approval_request/cedar --only P1-only-target-managers-decide"
	@echo "Cedar counterexample: $(CEDAR) trace approval_request/cedar --only D-self-approval-without-hierarchy-assumption"
	@echo "Cedar request: $(CEDAR) authorize approval_request/cedar 'User::\"alice\"' 'Action::\"approve\"' 'Request::\"dev/pending-by-alice\"'"
	@echo "Cedar decision table: $(CEDAR) matrix approval_request/cedar"
	@echo "single Souther check: $(SOUTHER) verify approval_request/souther --only examples"
	@echo "Souther example report: $(SOUTHER) examples approval_request/souther"
	@echo "Souther behavior run: $(SOUTHER) run approval_request/souther approve '[...directory...]' '\"bob\"' '{\"author\":\"alice\",...}'"

verify: verify-alloy verify-tla verify-quint verify-cedar verify-souther

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

verify-quint:
	@set -e; for dir in $(QUINT_DIRS); do \
		echo "== $$dir"; \
		$(QUINT) verify $$dir; \
	done

verify-cedar:
	@set -e; for dir in $(CEDAR_DIRS); do \
		echo "== $$dir"; \
		$(CEDAR) verify $$dir; \
	done

verify-souther:
	@set -e; for dir in $(SOUTHER_DIRS); do \
		echo "== $$dir"; \
		$(SOUTHER) verify $$dir; \
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

checks:
	@set -e; for dir in $(QUINT_DIRS); do \
		echo "== $$dir"; \
		$(QUINT) checks $$dir; \
	done
	@set -e; for dir in $(CEDAR_DIRS); do \
		echo "== $$dir"; \
		$(CEDAR) checks $$dir; \
	done
	@set -e; for dir in $(SOUTHER_DIRS); do \
		echo "== $$dir"; \
		$(SOUTHER) checks $$dir; \
	done

clean:
	rm -rf .tools
