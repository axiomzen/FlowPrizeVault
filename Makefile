# ============================================================================
# FlowPrizeVault Makefile
# ============================================================================

.PHONY: test test-all test-long test-cover help

# Default target
.DEFAULT_GOAL := help

# ----------------------------------------------------------------------------
# Test Commands
# ----------------------------------------------------------------------------

## Run fast tests only (excludes long-running tests)
test:
	@echo "Running fast tests..."
	flow test cadence/tests/*_test.cdc

## Run all tests including long-running tests (same as `flow test`)
test-all:
	@echo "Running all tests (including long-running)..."
	flow test cadence/tests/*_test.cdc cadence/long_tests/*_test.cdc

## Run only long-running tests
test-long:
	@echo "Running long-running tests..."
	flow test cadence/long_tests/*_test.cdc

## Run fast tests with coverage report
test-cover:
	@echo "Running fast tests with coverage..."
	flow test cadence/tests/*_test.cdc --cover

## Run all tests with coverage report
test-all-cover:
	@echo "Running all tests with coverage..."
	flow test cadence/tests/*_test.cdc cadence/long_tests/*_test.cdc --cover

# ----------------------------------------------------------------------------
# Mainnet signing
# ----------------------------------------------------------------------------

## Check gcloud credentials and mainnet deployer key state before a signing session
mainnet-preflight:
	@gcloud auth application-default print-access-token >/dev/null 2>&1 \
		&& echo "ADC: ok" \
		|| (echo "ADC: expired. Run: gcloud auth application-default login"; exit 1)
	@flow accounts get 0xa092c4aab33daeda --network mainnet --skip-version-check 2>/dev/null \
		| grep -E "^Keys|^Key |Revoked|Sequence"

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------

## Show this help message
help:
	@echo "FlowPrizeVault - Available Commands"
	@echo "===================================="
	@echo ""
	@echo "Test Commands:"
	@echo "  make test          - Run fast tests only (recommended for development)"
	@echo "  make test-all      - Run all tests including long-running tests"
	@echo "  make test-long     - Run only long-running tests"
	@echo "  make test-cover    - Run fast tests with coverage report"
	@echo "  make test-all-cover - Run all tests with coverage report"
	@echo ""
	@echo "Mainnet Commands:"
	@echo "  make mainnet-preflight - Check KMS credentials and deployer key state"
	@echo ""
	@echo "Long-running tests are in: cadence/long_tests/"
	@echo ""

