#!/bin/bash

# PrizeSavings Contract Test Script
# 
# This script tests the complete lifecycle of the PrizeSavings contract:
# - Contract deployment
# - User collection setup
# - Pool creation
# - Deposits and withdrawals
# - Lottery draw execution
# - All query scripts
#
# Usage:
#   ./test_prize_savings.sh
#
# Prerequisites:
#   - Flow emulator running: flow emulator start
#   - Or run with: flow emulator start & ./test_prize_savings.sh

# Don't use set -e since we handle errors ourselves with check_result
set +e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
NETWORK="emulator"
ADMIN_ACCOUNT="emulator-account"
FLOW_FLAGS="--skip-version-check"

# Test tracking
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=""

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo ""
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS="$FAILED_TESTS\n  - $1"
}

print_info() {
    echo -e "${NC}  $1${NC}"
}

run_tx() {
    local tx=$1
    shift
    echo -e "${NC}  Running: flow transactions send $tx $@${NC}"
    flow transactions send "$tx" "$@" --network $NETWORK $FLOW_FLAGS 2>&1
}

run_script() {
    local script=$1
    shift
    echo -e "${NC}  Running: flow scripts execute $script $@${NC}"
    flow scripts execute "$script" "$@" --network $NETWORK $FLOW_FLAGS 2>&1
}

check_result() {
    local result="$1"
    local success_pattern="$2"
    local test_name="$3"
    
    if echo "$result" | grep -qE "(panic|error|Error|Transaction Error)" && ! echo "$result" | grep -qE "(already exists|skipping)"; then
        print_error "$test_name"
        echo "$result" | grep -E "(panic|error|Error)" | head -5
        return 1
    elif [ -n "$success_pattern" ] && ! echo "$result" | grep -qE "$success_pattern"; then
        print_error "$test_name (pattern not found)"
        echo "$result" | head -10
        return 1
    else
        print_success "$test_name"
        return 0
    fi
}

# Check emulator is running
check_emulator() {
    print_step "Checking emulator status..."
    if curl -s http://localhost:8080/health > /dev/null 2>&1; then
        print_success "Emulator is running"
    else
        print_error "Emulator is not running!"
        echo -e "${YELLOW}Please start it with: flow emulator start${NC}"
        exit 1
    fi
}

# Deploy contracts
deploy_contracts() {
    print_header "DEPLOYING CONTRACTS"
    
    print_step "Installing dependencies..."
    flow dependencies install $FLOW_FLAGS 2>&1 | grep -E "(Installing|installed|already)" || true
    print_success "Dependencies installed"
    
    print_step "Deploying contracts to emulator..."
    local result=$(flow project deploy --network=$NETWORK $FLOW_FLAGS 2>&1)
    echo "$result" | grep -E "(Deploying|deployed|skipping|All contracts)" || echo "$result" | head -20
    
    if echo "$result" | grep -qE "(error|Error|failed)" && ! echo "$result" | grep -qE "skipping"; then
        print_error "Contract deployment"
        echo "$result"
        exit 1
    fi
    print_success "Contracts deployed"
}

# Test setup transactions
test_setup() {
    print_header "TESTING SETUP TRANSACTIONS"
    
    # Setup test yield vault
    print_step "Setting up test yield vault..."
    local result=$(run_tx cadence/transactions/prize-savings/setup_test_yield_vault.cdc --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Setup test yield vault"
    
    # Setup admin collection
    print_step "Setting up admin collection..."
    result=$(run_tx cadence/transactions/prize-savings/setup_collection.cdc --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Setup admin collection"
    
    # Create test pool (10 second draw interval for testing, 50% savings, 40% lottery, 10% treasury)
    print_step "Creating test pool..."
    result=$(run_tx cadence/transactions/prize-savings/create_test_pool.cdc 1.0 10.0 0.5 0.4 0.1 --signer $ADMIN_ACCOUNT)
    if ! check_result "$result" "" "Create test pool"; then
        echo "$result"
        print_error "Pool creation failed - cannot continue tests"
        return 1
    fi
    
    # Verify pool was created and get POOL_ID
    print_step "Verifying pool creation..."
    result=$(run_script cadence/scripts/prize-savings/get_all_pools.cdc)
    POOL_ID=$(echo "$result" | grep -oE '\[.*\]' | grep -oE '[0-9]+' | head -1)
    
    if [ -z "$POOL_ID" ]; then
        print_error "No pool ID found after creation"
        return 1
    fi
    
    print_success "Pool created with ID: $POOL_ID"
    export POOL_ID
}

# Test scripts
test_scripts() {
    print_header "TESTING QUERY SCRIPTS"
    
    # Check POOL_ID is set
    if [ -z "$POOL_ID" ]; then
        print_error "POOL_ID not set - skipping script tests"
        return 1
    fi
    
    # Get all pools
    print_step "Testing get_all_pools.cdc..."
    local result=$(run_script cadence/scripts/prize-savings/get_all_pools.cdc)
    echo "  Result: $result"
    if echo "$result" | grep -qE "\[.*\]"; then
        print_success "get_all_pools.cdc"
        print_info "Pool ID: $POOL_ID"
    else
        print_error "get_all_pools.cdc"
    fi
    
    # Get pool stats
    print_step "Testing get_pool_stats.cdc..."
    result=$(run_script cadence/scripts/prize-savings/get_pool_stats.cdc $POOL_ID)
    check_result "$result" "totalDeposited|poolID" "get_pool_stats.cdc"
    echo "$result" | head -20
    
    # Get draw status
    print_step "Testing get_draw_status.cdc..."
    result=$(run_script cadence/scripts/prize-savings/get_draw_status.cdc $POOL_ID)
    check_result "$result" "isDrawInProgress|canDrawNow" "get_draw_status.cdc"
    echo "$result" | head -15
    
    # Get treasury stats
    print_step "Testing get_treasury_stats.cdc..."
    result=$(run_script cadence/scripts/prize-savings/get_treasury_stats.cdc $POOL_ID)
    check_result "$result" "balance|totalCollected" "get_treasury_stats.cdc"
    echo "$result" | head -10
    
    # Get emergency info
    print_step "Testing get_emergency_info.cdc..."
    result=$(run_script cadence/scripts/prize-savings/get_emergency_info.cdc $POOL_ID)
    check_result "$result" "state|isNormal" "get_emergency_info.cdc"
    echo "$result" | head -10
    
    # Preview deposit
    print_step "Testing preview_deposit.cdc..."
    result=$(run_script cadence/scripts/prize-savings/preview_deposit.cdc $POOL_ID 100.0)
    check_result "$result" "sharesReceived|depositAmount" "preview_deposit.cdc"
    echo "$result" | head -10
}

# Get admin address
get_admin_address() {
    ADMIN_ADDR=$(grep -A 2 '"emulator-account"' flow.json | grep address | awk '{print $2}' | tr -d '",')
    [[ ! "$ADMIN_ADDR" =~ ^0x ]] && ADMIN_ADDR="0x$ADMIN_ADDR"
    echo "$ADMIN_ADDR"
}

# Test deposit and withdrawal
test_deposits() {
    print_header "TESTING DEPOSITS & WITHDRAWALS"
    
    if [ -z "$POOL_ID" ]; then
        print_error "POOL_ID not set - skipping deposit tests"
        return 1
    fi
    
    ADMIN_ADDR=$(get_admin_address)
    print_info "Admin address: $ADMIN_ADDR"
    
    # Deposit
    print_step "Testing deposit.cdc (100 FLOW)..."
    local result=$(run_tx cadence/transactions/prize-savings/deposit.cdc $POOL_ID 100.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Deposit 100 FLOW"
    
    # Check balance after deposit
    print_step "Checking balance after deposit..."
    result=$(run_script cadence/scripts/prize-savings/get_pool_balance.cdc $ADMIN_ADDR $POOL_ID)
    check_result "$result" "deposits|totalBalance" "get_pool_balance.cdc after deposit"
    echo "$result"
    
    # Check if registered
    print_step "Testing is_registered.cdc..."
    result=$(run_script cadence/scripts/prize-savings/is_registered.cdc $ADMIN_ADDR $POOL_ID)
    check_result "$result" "true" "is_registered.cdc"
    echo "  Result: $result"
    
    # Get user pools
    print_step "Testing get_user_pools.cdc..."
    result=$(run_script cadence/scripts/prize-savings/get_user_pools.cdc $ADMIN_ADDR)
    check_result "$result" "\[.*\]" "get_user_pools.cdc"
    echo "  Result: $result"
    
    # Get user shares
    print_step "Testing get_user_shares.cdc..."
    result=$(run_script cadence/scripts/prize-savings/get_user_shares.cdc $ADMIN_ADDR $POOL_ID)
    check_result "$result" "shares|shareValue" "get_user_shares.cdc"
    echo "$result" | head -15
    
    # Partial withdrawal
    print_step "Testing withdraw.cdc (25 FLOW)..."
    result=$(run_tx cadence/transactions/prize-savings/withdraw.cdc $POOL_ID 25.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Withdraw 25 FLOW"
    
    # Check balance after withdrawal
    print_step "Checking balance after withdrawal..."
    result=$(run_script cadence/scripts/prize-savings/get_pool_balance.cdc $ADMIN_ADDR $POOL_ID)
    check_result "$result" "deposits|totalBalance" "get_pool_balance.cdc after withdrawal"
    echo "$result"
}

# Test yield and rewards
test_yield() {
    print_header "TESTING YIELD & REWARDS"
    
    if [ -z "$POOL_ID" ]; then
        print_error "POOL_ID not set - skipping yield tests"
        return 1
    fi
    
    # Add simulated yield to the pool
    print_step "Adding 10 FLOW as simulated yield..."
    local result=$(run_tx cadence/transactions/prize-savings/add_yield_to_pool.cdc 10.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Add yield to pool"
    
    # Check pool stats before processing
    print_step "Pool stats before processing rewards..."
    result=$(run_script cadence/scripts/prize-savings/get_pool_stats.cdc $POOL_ID)
    echo "$result" | grep -E "availableYield|totalStaked|lotteryPool" || echo "$result" | head -15
    
    # Note: processRewards is contract-internal, it's called automatically during deposits/withdrawals
    # To trigger it, we can do a small deposit
    print_step "Triggering reward processing via deposit..."
    result=$(run_tx cadence/transactions/prize-savings/deposit.cdc $POOL_ID 1.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Deposit to trigger reward processing"
    
    # Check pool stats after processing
    print_step "Pool stats after processing rewards..."
    result=$(run_script cadence/scripts/prize-savings/get_pool_stats.cdc $POOL_ID)
    echo "$result" | grep -E "totalSavings|lotteryPool|treasury" || echo "$result" | head -15
    print_success "Yield processing"
}

# Test lottery draw
test_lottery() {
    print_header "TESTING LOTTERY DRAW"
    
    if [ -z "$POOL_ID" ]; then
        print_error "POOL_ID not set - skipping lottery tests"
        return 1
    fi
    
    # Check draw status before
    print_step "Checking if draw can start..."
    local result=$(run_script cadence/scripts/prize-savings/get_draw_status.cdc $POOL_ID)
    echo "$result" | grep -E "canDrawNow|lotteryPoolBalance" || echo "$result" | head -10
    
    # Add more yield to ensure lottery pool has funds
    print_step "Adding more yield for lottery prize pool..."
    result=$(run_tx cadence/transactions/prize-savings/add_yield_to_pool.cdc 20.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Add more yield"
    
    # Trigger processing to move yield to lottery
    result=$(run_tx cadence/transactions/prize-savings/deposit.cdc $POOL_ID 1.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Process yield"
    
    # Wait for draw interval (reduced for testing)
    print_step "Waiting for draw interval (11 seconds)..."
    sleep 11
    
    # Start draw
    print_step "Starting lottery draw..."
    result=$(run_tx cadence/transactions/prize-savings/start_draw.cdc $POOL_ID --signer $ADMIN_ACCOUNT)
    if check_result "$result" "" "Start draw"; then
        # Check draw status (should be in progress)
        result=$(run_script cadence/scripts/prize-savings/get_draw_status.cdc $POOL_ID)
        echo "$result" | grep -E "isDrawInProgress" || echo "$result" | head -5
        
        # Wait for block advancement
        print_step "Waiting for block advancement..."
        sleep 2
        
        # Complete draw
        print_step "Completing lottery draw..."
        result=$(run_tx cadence/transactions/prize-savings/complete_draw.cdc $POOL_ID --signer $ADMIN_ACCOUNT)
        check_result "$result" "" "Complete draw"
        
        # Check draw status after
        print_step "Draw status after completion..."
        result=$(run_script cadence/scripts/prize-savings/get_draw_status.cdc $POOL_ID)
        echo "$result" | head -10
    else
        print_info "Draw may have failed due to insufficient prize pool or timing"
    fi
}

# Test admin functions
test_admin() {
    print_header "TESTING ADMIN FUNCTIONS"
    
    if [ -z "$POOL_ID" ]; then
        print_error "POOL_ID not set - skipping admin tests"
        return 1
    fi
    
    # Update draw interval
    print_step "Testing update_draw_interval.cdc..."
    local result=$(run_tx cadence/transactions/prize-savings/update_draw_interval.cdc $POOL_ID 20.0 --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Update draw interval to 20s"
    
    # Verify update
    result=$(run_script cadence/scripts/prize-savings/get_pool_stats.cdc $POOL_ID)
    echo "$result" | grep -E "drawInterval" || true
    
    # Test emergency mode
    print_step "Testing enable_emergency_mode.cdc..."
    result=$(run_tx cadence/transactions/prize-savings/enable_emergency_mode.cdc $POOL_ID "Testing emergency mode" --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Enable emergency mode"
    
    # Verify emergency state
    print_step "Checking emergency state..."
    result=$(run_script cadence/scripts/prize-savings/get_emergency_info.cdc $POOL_ID)
    check_result "$result" "EmergencyMode|isEmergencyMode.*true" "Emergency state active"
    echo "$result" | head -10
    
    # Disable emergency mode
    print_step "Testing disable_emergency_mode.cdc..."
    result=$(run_tx cadence/transactions/prize-savings/disable_emergency_mode.cdc $POOL_ID --signer $ADMIN_ACCOUNT)
    check_result "$result" "" "Disable emergency mode"
    
    # Verify normal state
    result=$(run_script cadence/scripts/prize-savings/get_emergency_info.cdc $POOL_ID)
    echo "$result" | grep -E "Normal|isNormal" || true
}

# Print summary
print_summary() {
    print_header "TEST SUMMARY"
    
    echo ""
    echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"
    
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "\n${RED}Failed Tests:${NC}"
        echo -e "$FAILED_TESTS"
    fi
    
    echo ""
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ALL TESTS PASSED! 🎉${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        exit 0
    else
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  SOME TESTS FAILED${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        exit 1
    fi
}

# Main execution
main() {
    print_header "PRIZESAVINGS CONTRACT TEST SUITE"
    
    check_emulator
    deploy_contracts
    
    # Setup is critical - if it fails, we can't continue
    if ! test_setup; then
        print_error "Setup failed - cannot continue with tests"
        print_summary
        exit 1
    fi
    
    test_scripts
    test_deposits
    test_yield
    test_lottery
    test_admin
    print_summary
}

# Run main
main "$@"

