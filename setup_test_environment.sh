#!/bin/bash

# Common Test Environment Setup Script
# 
# This script sets up the complete test environment for PrizeVault testing.
# It can be sourced by other scripts or run standalone.
#
# Usage:
#   source ./setup_test_environment.sh && setup_test_environment
#   OR
#   ./setup_test_environment.sh
#
# Environment Variables:
#   SKIP_SETUP=true          Skip admin resource setup
#   SKIP_DEPLOY=true         Skip contract deployment
#   ADMIN_ACCOUNT=name       Admin account (default: emulator-account)
#   USER_ACCOUNT=name        User account (default: az-emulator)
#   NETWORK=network          Network to use (default: emulator)

set +e

FLOW_FLAGS="${FLOW_FLAGS:---skip-version-check}"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration (can be overridden by environment variables)
ADMIN_ACCOUNT="${ADMIN_ACCOUNT:-emulator-account}"
USER_ACCOUNT="${USER_ACCOUNT:-az-emulator}"
NETWORK="${NETWORK:-emulator}"
SKIP_SETUP="${SKIP_SETUP:-false}"
SKIP_DEPLOY="${SKIP_DEPLOY:-false}"

# Helper functions
get_account_address() {
    grep -A 2 "\"$1\"" flow.json 2>/dev/null | grep address | awk '{print $2}' | tr -d '",' || echo ""
}

find_user_account() {
    grep -q "\"az-emulator2\"" flow.json 2>/dev/null && echo "az-emulator2" || \
    (grep -q "\"az-emulator\"" flow.json 2>/dev/null && echo "az-emulator" || echo "")
}

account_exists() {
    ! flow accounts get "$1" --network $NETWORK $FLOW_FLAGS 2>&1 | grep -qE "(Account.*not found|could not find account|Invalid argument)"
}

run_tx() {
    local tx=$1; shift
    flow transactions send "$tx" "$@" --network $NETWORK $FLOW_FLAGS 2>&1
}

run_script() {
    local script=$1; shift
    flow scripts execute "$script" "$@" --network $NETWORK $FLOW_FLAGS 2>&1
}

check_error() {
    echo "$1" | grep -qE "(Transaction Error|Error Code|error caused by|panic)" && return 1 || return 0
}

print_step() {
    echo -e "${BLUE}--- Step $1: $2...${NC}"
}

print_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# Main setup function
setup_test_environment() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Setting up Test Environment          ${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    # Check emulator
    if ! curl -s http://localhost:8080/health > /dev/null 2>&1; then
        print_error "Emulator is not running!"
        echo -e "${YELLOW}Please start it with: flow emulator start${NC}"
        return 1
    fi
    print_success "Emulator is running"
    echo ""
    
    # Step 1: Install dependencies
    print_step "1" "Installing dependencies"
    echo -e "${YELLOW}Installing dependencies from flow.json...${NC}"
    INSTALL_OUTPUT=$(flow dependencies install $FLOW_FLAGS 2>&1)
    echo "$INSTALL_OUTPUT" | grep -E "(Installing|installed|already)" || true
    
    # Step 2: Deploy contracts
    if [ "$SKIP_DEPLOY" = false ]; then
        print_step "2" "Deploying contracts"
        DEPLOY_OUTPUT=$(flow project deploy --network=$NETWORK $FLOW_FLAGS 2>&1)
        DEPLOY_STATUS=$?
        
        echo "$DEPLOY_OUTPUT" | grep -E "(Deploying|deployed|skipping|error|Error)" || echo "$DEPLOY_OUTPUT"
        
        if [ $DEPLOY_STATUS -eq 0 ]; then
            print_success "Contracts deployed"
        else
            print_error "Contract deployment failed!"
            echo "$DEPLOY_OUTPUT"
            return 1
        fi
    else
        echo -e "${YELLOW}[SKIP] Skipping contract deployment${NC}"
    fi
    echo ""
    
    # Step 3: Setup admin
    if [ "$SKIP_SETUP" = false ]; then
        print_step "3" "Setting up admin resource"
        ADMIN_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/setup_admin.cdc --signer $ADMIN_ACCOUNT)
        echo "$ADMIN_OUTPUT" | grep -E "(Transaction ID|Error|panic)" || print_warn "Admin already exists"
        print_success "Admin setup complete"
    else
        echo -e "${YELLOW}[SKIP] Skipping admin setup${NC}"
    fi
    echo ""
    
    # Step 4: Setup collections
    print_step "4" "Setting up user collections"
    run_tx cadence/transactions/prize-vault-modular/setup_collection.cdc --signer $ADMIN_ACCOUNT | \
        grep -E "(Transaction ID|Error)" || print_warn "Collection may already exist"
    
    USER_ACCT=$(find_user_account)
    USER_ADDR=$(get_account_address "$USER_ACCT")
    [ -n "$USER_ADDR" ] && [[ ! "$USER_ADDR" =~ ^0x ]] && USER_ADDR="0x$USER_ADDR"
    
    if [ -n "$USER_ADDR" ] && [ -n "$USER_ACCT" ]; then
        if [ "$NETWORK" = "emulator" ] && ! account_exists "$USER_ACCT"; then
            print_warn "Account $USER_ACCT not found in emulator"
        fi
        
        if account_exists "$USER_ACCT"; then
            run_tx cadence/transactions/prize-vault-modular/setup_collection.cdc --signer $USER_ACCT | \
                grep -E "(Transaction ID|Error)" || print_warn "Collection may already exist"
        fi
    fi
    print_success "Collections setup complete"
    echo ""
    
    # Step 5: Fund user account
    if [ -n "$USER_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
        print_step "5" "Funding $USER_ACCT account"
        FUND_OUTPUT=$(run_tx cadence/transactions/fund_account.cdc $USER_ADDR 500.0 --signer $ADMIN_ACCOUNT)
        if check_error "$FUND_OUTPUT"; then
            print_success "$USER_ACCT account funded"
            USER_ACCOUNT=$USER_ACCT
        else
            print_warn "Funding failed - using $ADMIN_ACCOUNT"
            USER_ACCOUNT=$ADMIN_ACCOUNT
        fi
    else
        USER_ACCOUNT=$ADMIN_ACCOUNT
    fi
    echo ""
    
    # Step 5.5: Setup winner tracker
    print_step "5.5" "Setting up PrizeWinnerTracker"
    TRACKER_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/setup_winner_tracker.cdc 100 --signer $ADMIN_ACCOUNT --include logs)
    if check_error "$TRACKER_OUTPUT"; then
        echo "$TRACKER_OUTPUT" | grep -E "(Transaction ID|Tracker created)" || true
        print_success "Winner tracker setup complete"
    else
        echo "$TRACKER_OUTPUT" | grep -E "(already exists|skipping)" && print_success "Tracker already exists" || \
            print_warn "Tracker setup may have issues"
    fi
    sleep 1
    
    # Verify tracker
    ADMIN_ADDR=$(get_account_address "$ADMIN_ACCOUNT")
    [[ ! "$ADMIN_ADDR" =~ ^0x ]] && ADMIN_ADDR="0x$ADMIN_ADDR"
    TRACKER_VERIFY=$(run_script cadence/scripts/prize-vault-modular/get_winner_history.cdc $ADMIN_ADDR 0 1)
    echo "$TRACKER_VERIFY" | grep -qE "(panic|not found|nil)" && \
        print_error "Tracker capability not accessible!" || print_success "Tracker capability verified"
    echo ""
    
    # Step 6: Create pool
    print_step "6" "Creating pool (60% savings, 40% lottery)"
    # Note: autoSchedule is false here - scheduler is set up separately in test_scheduler.sh
    POOL_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/create_pool.cdc 0.6 0.4 0.0 1.0 10.0 $ADMIN_ADDR false --signer $ADMIN_ACCOUNT --include logs)
    echo "$POOL_OUTPUT" | grep -q "Winner tracking: Enabled" && print_success "Winner tracking enabled" || \
        print_warn "Winner tracking disabled"
    
    # Verify pool ID
    ALL_POOLS=$(run_script cadence/scripts/prize-vault-modular/get_all_pools.cdc)
    export POOL_ID=$(echo "$ALL_POOLS" | grep -oE '\[.*\]' | grep -oE '[0-9]+' | tr ' ' '\n' | sort -n | tail -1)
    
    if [ -z "$POOL_ID" ]; then
        print_error "No pools found after creation!"
        echo "$POOL_OUTPUT" | head -30
        return 1
    fi
    print_success "Pool created with ID: $POOL_ID"
    echo ""
    
    # Step 7: Verify pool
    print_step "7" "Verifying pool creation"
    POOL_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
    echo "Result: $POOL_STATS"
    echo ""
    
    # Step 8: Deposit from admin
    print_step "8" "Depositing 100 FLOW from $ADMIN_ACCOUNT"
    DEPOSIT_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/deposit.cdc $POOL_ID 100.0 --signer $ADMIN_ACCOUNT)
    if check_error "$DEPOSIT_OUTPUT"; then
        echo "$DEPOSIT_OUTPUT" | grep -E "(Transaction ID|Deposited)" || true
        print_success "Deposit complete"
    else
        print_error "Deposit failed"
        echo "$DEPOSIT_OUTPUT" | grep -E "(error|panic)" | head -10
        return 1
    fi
    echo ""
    
    # Step 9: Deposit from user (if different account)
    if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
        print_step "9" "Depositing 50 FLOW from $USER_ACCT"
        USER_DEPOSIT_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/deposit.cdc $POOL_ID 50.0 --signer $USER_ACCT)
        if check_error "$USER_DEPOSIT_OUTPUT"; then
            echo "$USER_DEPOSIT_OUTPUT" | grep -E "(Transaction ID|Deposited)" || true
            print_success "User deposit complete"
        else
            print_warn "User deposit had issues"
        fi
        echo ""
    fi
    
    # Step 10: Contribute rewards
    print_step "10" "Contributing 10 FLOW rewards (from $ADMIN_ACCOUNT)"
    CONTRIBUTE_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/contribute_rewards.cdc $POOL_ID 10.0 --signer $ADMIN_ACCOUNT)
    if check_error "$CONTRIBUTE_OUTPUT"; then
        echo "$CONTRIBUTE_OUTPUT" | grep -E "(Transaction ID|RewardContributed)" || true
        print_success "Rewards contributed"
    else
        print_error "Reward contribution failed"
        echo "$CONTRIBUTE_OUTPUT" | grep -E "(error|panic)" | head -10
        return 1
    fi
    echo ""
    
    # Step 11: Process rewards
    print_step "11" "Processing rewards"
    if ! account_exists "$USER_ACCOUNT"; then
        USER_ACCOUNT=$ADMIN_ACCOUNT
    fi
    PROCESS_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/process_rewards.cdc $POOL_ID --signer $USER_ACCOUNT --include events)
    if check_error "$PROCESS_OUTPUT"; then
        if echo "$PROCESS_OUTPUT" | grep -qE "RewardsProcessed|SavingsInterestDistributed"; then
            echo "$PROCESS_OUTPUT" | grep -E "(Transaction ID|RewardsProcessed|SavingsInterestDistributed)" || true
            SAVINGS_AMT=$(echo "$PROCESS_OUTPUT" | grep -A 5 "SavingsInterestDistributed" | grep -oE 'amount[^0-9]*([0-9.]+)' | grep -oE '[0-9.]+' | head -1)
            LOTTERY_AMT=$(echo "$PROCESS_OUTPUT" | grep -A 5 "RewardsProcessed" | grep -oE 'lotteryAmount[^0-9]*([0-9.]+)' | grep -oE '[0-9.]+' | head -1)
            [ -n "$SAVINGS_AMT" ] && [ -n "$LOTTERY_AMT" ] && \
                print_success "Rewards processed ($SAVINGS_AMT FLOW to savings, $LOTTERY_AMT FLOW to lottery)" || \
                print_success "Rewards processed"
        else
            print_warn "Rewards processed but no events found"
        fi
    else
        print_error "Process rewards failed"
        echo "$PROCESS_OUTPUT" | grep -E "(error|panic)" | head -10
        return 1
    fi
    echo ""
    
    # Summary
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Test Environment Ready!               ${NC}"
    echo -e "${GREEN}========================================${NC}\n"
    
    echo -e "${YELLOW}Environment Details:${NC}"
    echo "  Admin Account: $ADMIN_ACCOUNT ($ADMIN_ADDR)"
    echo "  User Account: $USER_ACCOUNT"
    echo "  Pool ID: $POOL_ID"
    echo "  Network: $NETWORK"
    echo ""
    
    return 0
}

# If script is executed directly (not sourced), run setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_test_environment
    exit $?
fi

