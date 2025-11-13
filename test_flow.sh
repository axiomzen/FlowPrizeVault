#!/bin/bash

# PrizeVaultModular Testing Script
# 
# Usage: ./test_flow.sh [OPTIONS]
#
# Options:
#   --skip-setup           Skip admin setup (if already configured)
#   --skip-deploy          Skip contract deployment (if already deployed)
#   --skip-manual-draw     Skip manual draw test
#   --admin-account ACCT   Admin account name (default: emulator-account)
#   --user-account ACCT    User account name (default: az-emulator)
#   --network NETWORK      Network to use (default: emulator)
#
# Examples:
#   ./test_flow.sh                          # Full test including manual draws
#   ./test_flow.sh --skip-manual-draw       # Skip draw testing
#   ./test_flow.sh --skip-setup --skip-deploy  # Quick test with existing setup
#
# Note: For scheduler testing, use test_scheduler.sh instead

set +e

FLOW_FLAGS="--skip-version-check"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ADMIN_ACCOUNT="emulator-account"
USER_ACCOUNT="az-emulator"
NETWORK="emulator"
SKIP_SETUP=false
SKIP_DEPLOY=false
SKIP_MANUAL_DRAW=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-setup) SKIP_SETUP=true; shift ;;
        --skip-deploy) SKIP_DEPLOY=true; shift ;;
        --skip-manual-draw) SKIP_MANUAL_DRAW=true; shift ;;
        --admin-account) ADMIN_ACCOUNT="$2"; shift 2 ;;
        --user-account) USER_ACCOUNT="$2"; shift 2 ;;
        --network) NETWORK="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
    echo -e "${BLUE}Step $1: $2...${NC}"
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

# Main script
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  PrizeVaultModular Testing Script     ${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Check emulator
if ! curl -s http://localhost:8080/health > /dev/null 2>&1; then
    print_error "Emulator is not running!"
    echo -e "${YELLOW}Please start it with: flow emulator start${NC}"
    exit 1
fi
print_success "Emulator is running\n"

# Step 1: Install dependencies
print_step "1" "Installing dependencies"
flow dependencies install $FLOW_FLAGS 2>/dev/null | grep -E "(Installing|already)" || true
echo ""

# Step 2: Deploy contracts
if [ "$SKIP_DEPLOY" = false ]; then
    print_step "2" "Deploying contracts"
    flow project deploy --network=$NETWORK $FLOW_FLAGS 2>&1 | grep -E "(Deploying|deployed|skipping)" || true
    print_success "Contracts deployed\n"
else
    echo -e "${YELLOW}⏭️  Skipping contract deployment\n${NC}"
fi

# Step 3: Setup admin
if [ "$SKIP_SETUP" = false ]; then
    print_step "3" "Setting up admin resource"
    run_tx cadence/transactions/prize-vault-modular/setup_admin.cdc --signer $ADMIN_ACCOUNT | \
        grep -E "(Transaction ID|Error|panic)" || print_warn "Admin already exists"
    print_success "Admin setup complete\n"
else
    echo -e "${YELLOW}⏭️  Skipping admin setup\n${NC}"
fi

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
        print_warn "Creating account automatically..."
        # Try to create account (simplified - may need manual creation)
        flow accounts create --network $NETWORK $FLOW_FLAGS 2>&1 | grep -E "(Account created|created with address)" && sleep 2 || \
            print_warn "Account creation failed - use admin account as fallback"
    fi
    
    if account_exists "$USER_ACCT"; then
        run_tx cadence/transactions/prize-vault-modular/setup_collection.cdc --signer $USER_ACCT | \
            grep -E "(Transaction ID|Error)" || print_warn "Collection may already exist"
    fi
fi
print_success "Collections setup complete\n"

# Step 5: Fund user account and set USER_ACCOUNT
if [ -n "$USER_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
    print_step "5" "Funding $USER_ACCT account"
    run_tx cadence/transactions/fund_account.cdc $USER_ADDR 500.0 --signer $ADMIN_ACCOUNT | \
        grep -E "(Transaction ID|Error)" && (print_success "$USER_ACCT account funded"; USER_ACCOUNT=$USER_ACCT) || \
        (print_warn "Funding failed - using $ADMIN_ACCOUNT"; USER_ACCOUNT=$ADMIN_ACCOUNT)
    echo ""
else
    # User account doesn't exist, use admin account
    USER_ACCOUNT=$ADMIN_ACCOUNT
fi

# Step 5.5: Setup winner tracker
print_step "5.5" "Setting up PrizeWinnerTracker"
TRACKER_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/setup_winner_tracker.cdc 100 --signer $ADMIN_ACCOUNT --include logs)
if check_error "$TRACKER_OUTPUT"; then
    echo "$TRACKER_OUTPUT" | grep -E "(Transaction ID|Tracker created)" || true
    print_success "Winner tracker setup complete"
else
    echo "$TRACKER_OUTPUT" | grep -E "(already exists|skipping)" && print_success "Tracker already exists" || \
        (print_warn "Tracker setup failed"; echo "$TRACKER_OUTPUT" | grep -E "(error|Error|panic)" | head -3)
fi
sleep 1

# Verify tracker and prepare admin address
ADMIN_ADDR=$(get_account_address "$ADMIN_ACCOUNT")
[[ ! "$ADMIN_ADDR" =~ ^0x ]] && ADMIN_ADDR="0x$ADMIN_ADDR"
TRACKER_VERIFY=$(run_script cadence/scripts/prize-vault-modular/get_winner_history.cdc $ADMIN_ADDR 0 1)
echo "$TRACKER_VERIFY" | grep -qE "(panic|not found|nil)" && \
    print_error "Tracker capability not accessible!" || print_success "Tracker capability verified"
echo ""

# Step 6: Create pool
print_step "6" "Creating pool (60% savings, 40% lottery)"
# Note: autoSchedule is false - this test doesn't use the scheduler
POOL_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/create_pool.cdc 0.6 0.4 0.0 1.0 10.0 $ADMIN_ADDR false --signer $ADMIN_ACCOUNT --include logs)
echo "$POOL_OUTPUT" | grep -q "Winner tracking: Enabled" && print_success "Winner tracking enabled" || \
    print_warn "Winner tracking disabled"

# Verify pool ID
ALL_POOLS=$(run_script cadence/scripts/prize-vault-modular/get_all_pools.cdc)
POOL_ID=$(echo "$ALL_POOLS" | grep -oE '\[.*\]' | grep -oE '[0-9]+' | tr ' ' '\n' | sort -n | tail -1)

if [ -z "$POOL_ID" ]; then
    print_error "No pools found after creation!"
    echo "$POOL_OUTPUT" | head -30
    exit 1
fi
print_success "Pool created with ID: $POOL_ID\n"

# Step 7: Verify pool
print_step "7" "Verifying pool creation"
run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID | \
    grep -E "(Result:|poolID|totalDeposited|totalStaked)" || true
echo ""

# Step 8: Deposit from admin
print_step "8" "Depositing 100 FLOW from $ADMIN_ACCOUNT"
DEPOSIT_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/deposit.cdc $POOL_ID 100.0 --signer $ADMIN_ACCOUNT)
if check_error "$DEPOSIT_OUTPUT"; then
    echo "$DEPOSIT_OUTPUT" | grep -E "(Transaction ID|Deposited)" || true
    print_success "Deposit complete"
else
    print_error "Deposit failed"
    echo "$DEPOSIT_OUTPUT" | grep -A 15 "Transaction Error" | head -20 || \
        echo "$DEPOSIT_OUTPUT" | grep -E "(error|panic)" | head -10
fi
echo ""

# Step 9: Deposit from user
if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
    print_step "9" "Depositing 50 FLOW from $USER_ACCT"
    USER_DEPOSIT_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/deposit.cdc $POOL_ID 50.0 --signer $USER_ACCT)
    if check_error "$USER_DEPOSIT_OUTPUT"; then
        echo "$USER_DEPOSIT_OUTPUT" | grep -E "(Transaction ID|Deposited)" || true
        print_success "User deposit complete"
    else
        print_error "User deposit failed"
        echo "$USER_DEPOSIT_OUTPUT" | grep -E "(error|panic)" | head -10
    fi
    echo ""
fi

# Step 10: Check balances
print_step "10" "Checking pool balances"
run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID | \
    grep -E "(Result:|poolID|totalDeposited|totalStaked)" || true

if [ "$ADMIN_ACCOUNT" != "$USER_ACCOUNT" ]; then
    echo -e "\n${YELLOW}Admin balance:${NC}"
    run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $ADMIN_ADDR $POOL_ID | \
        grep -E "(Result:|deposits|pendingSavings)" || true
    
    if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ]; then
        echo -e "\n${YELLOW}User balance:${NC}"
        run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $USER_ADDR $POOL_ID | \
            grep -E "(Result:|deposits|pendingSavings)" || true
    fi
fi
echo ""

# Step 11: Contribute rewards
print_step "11" "Contributing 10 FLOW rewards (from $ADMIN_ACCOUNT)"
CONTRIBUTE_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/contribute_rewards.cdc $POOL_ID 10.0 --signer $ADMIN_ACCOUNT)
if check_error "$CONTRIBUTE_OUTPUT"; then
    echo "$CONTRIBUTE_OUTPUT" | grep -E "(Transaction ID|RewardContributed)" || true
    print_success "Rewards contributed"
else
    print_error "Reward contribution failed"
    echo "$CONTRIBUTE_OUTPUT" | grep -E "(error|panic)" | head -10
fi
echo ""

# Step 12: Process rewards
print_step "12" "Processing rewards"
# Ensure USER_ACCOUNT exists, fallback to ADMIN_ACCOUNT if not
if ! account_exists "$USER_ACCOUNT"; then
    print_warn "User account $USER_ACCOUNT not found, using $ADMIN_ACCOUNT"
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
        print_error "No RewardsProcessed event found!"
    fi
else
    print_error "Process rewards failed"
    echo "$PROCESS_OUTPUT" | grep -A 20 -E "(Error Code|Transaction Error|error caused by|panic)" | head -25
    echo -e "${YELLOW}💡 Tip: Make sure rewards were contributed in Step 11${NC}"
fi
echo ""

# Step 13: Check pending savings
print_step "13" "Checking pending savings for all users"
echo -e "${YELLOW}  $ADMIN_ACCOUNT:${NC}"
run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $ADMIN_ADDR $POOL_ID | \
    grep -E "(Result:|pendingSavings|deposits|totalClaimedSavings)" || true

if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
    echo -e "\n${YELLOW}  $USER_ACCT:${NC}"
    run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $USER_ADDR $POOL_ID | \
        grep -E "(Result:|pendingSavings|deposits|totalClaimedSavings)" || \
        print_warn "Account not registered with pool"
fi
echo ""

# Step 14: Claim savings
print_step "14" "Claiming savings interest for all users"
echo -e "${YELLOW}  Claiming for $ADMIN_ACCOUNT...${NC}"
CLAIM_ADMIN_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/claim_savings.cdc $POOL_ID --signer $ADMIN_ACCOUNT)
check_error "$CLAIM_ADMIN_OUTPUT" && (echo "$CLAIM_ADMIN_OUTPUT" | grep -E "(Transaction ID|SavingsInterestClaimed)" || true; print_success "Savings claimed") || \
    print_warn "No pending savings or error"

if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
    echo -e "${YELLOW}  Claiming for $USER_ACCT...${NC}"
    CLAIM_USER_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/claim_savings.cdc $POOL_ID --signer $USER_ACCT)
    check_error "$CLAIM_USER_OUTPUT" && (echo "$CLAIM_USER_OUTPUT" | grep -E "(Transaction ID|SavingsInterestClaimed)" || true; print_success "Savings claimed") || \
        print_warn "No pending savings or error"
fi
echo ""

# Step 15-17: Manual lottery draw (optional)
if [ "$SKIP_MANUAL_DRAW" = false ]; then
    # Step 15: Start lottery draw
    print_step "15" "Starting lottery draw (manual test)"
    LOTTERY_BALANCE=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID | \
        grep -oE '"totalStaked":\s*[0-9.]+' | grep -oE '[0-9.]+' || echo "0")
    [ "$LOTTERY_BALANCE" = "0" ] && print_warn "Warning: No funds in lottery pool. Draw may fail."

    # Ensure USER_ACCOUNT exists
    if ! account_exists "$USER_ACCOUNT"; then
        USER_ACCOUNT=$ADMIN_ACCOUNT
    fi
    START_DRAW_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/start_draw.cdc $POOL_ID --signer $USER_ACCOUNT)
    if check_error "$START_DRAW_OUTPUT"; then
        echo "$START_DRAW_OUTPUT" | grep -E "(Transaction ID|PrizeDrawCommitted)" || true
        print_success "Draw started"
    else
        print_error "Start draw failed"
        echo "$START_DRAW_OUTPUT" | grep -E "(error|panic)" | head -10
    fi
    echo ""

    # Step 16: Complete draw
    print_step "16" "Completing lottery draw (manual test)"
    sleep 1
    # Ensure USER_ACCOUNT exists
    if ! account_exists "$USER_ACCOUNT"; then
        USER_ACCOUNT=$ADMIN_ACCOUNT
    fi
    COMPLETE_DRAW_OUTPUT=$(run_tx cadence/transactions/prize-vault-modular/complete_draw.cdc $POOL_ID --signer $USER_ACCOUNT)
    if check_error "$COMPLETE_DRAW_OUTPUT"; then
        echo "$COMPLETE_DRAW_OUTPUT" | grep -E "(Transaction ID|PrizesAwarded|winners)" || true
        print_success "Draw completed"
    else
        print_error "Complete draw failed"
        echo "$COMPLETE_DRAW_OUTPUT" | grep -E "(error|panic)" | head -10
    fi
    echo ""

    # Step 17: Check winners
    print_step "17" "Checking winners and prizes"
    echo -e "${YELLOW}  $ADMIN_ACCOUNT:${NC}"
    run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $ADMIN_ADDR $POOL_ID | \
        grep -E "(Result:|prizes|deposits|totalClaimedSavings)" || true

    if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ] && [ -n "$USER_ACCT" ] && account_exists "$USER_ACCT"; then
        echo -e "\n${YELLOW}  $USER_ACCT:${NC}"
        run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $USER_ADDR $POOL_ID | \
            grep -E "(Result:|prizes|deposits|totalClaimedSavings)" || \
            print_warn "Account not registered with pool"
    fi
    echo ""
else
    echo -e "${YELLOW}⏭️  Skipping manual draw steps\n${NC}"
fi

# Final Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Testing Complete!                     ${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} Final Summary${NC}"
echo -e "${BLUE}========================================${NC}\n"

echo -e "${YELLOW}Pool Information:${NC}"
echo "  Pool ID: $POOL_ID"
echo "  Admin Account: $ADMIN_ACCOUNT"
echo "  User Account: $USER_ACCOUNT"
echo ""

echo -e "${YELLOW}Pool Stats:${NC}"
run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID | \
    grep -E "(Result:|poolID|totalDeposited|totalStaked|distributionStrategy|drawIntervalSeconds|canDrawNow)" || true
echo ""

echo -e "${YELLOW}User Balances:${NC}"
echo -e "${BLUE}  $ADMIN_ACCOUNT ($ADMIN_ADDR):${NC}"
BALANCE_OUTPUT=$(run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $ADMIN_ADDR $POOL_ID)
echo "$BALANCE_OUTPUT" | grep -E "(Result:|deposits|pendingSavings|totalClaimedSavings|prizes|totalBalance)" || echo "$BALANCE_OUTPUT"
echo ""

if [ -n "$USER_ADDR" ] && [ "$USER_ADDR" != "$ADMIN_ADDR" ] && [ -n "$USER_ACCT" ]; then
    if account_exists "$USER_ACCT"; then
        echo -e "${BLUE}  $USER_ACCT ($USER_ADDR):${NC}"
        BALANCE_OUTPUT=$(run_script cadence/scripts/prize-vault-modular/get_pool_balance.cdc $USER_ADDR $POOL_ID)
        echo "$BALANCE_OUTPUT" | grep -qE "(panic|No collection|error)" && \
            print_warn "Account not registered with pool or no collection found" || \
            (echo "$BALANCE_OUTPUT" | grep -E "(Result:|deposits|pendingSavings|totalClaimedSavings|prizes|totalBalance)" || echo "$BALANCE_OUTPUT")
    else
        echo -e "${YELLOW}  $USER_ACCT: Account not found in emulator${NC}"
    fi
    echo ""
fi

# Winner History
echo -e "${YELLOW}Winner History:${NC}"
POOL_STATS_OUTPUT=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
if echo "$POOL_STATS_OUTPUT" | grep -qiE '"hasWinnerTracker"\s*:\s*true'; then
    WINNER_OUTPUT=$(run_script cadence/scripts/prize-vault-modular/get_winner_history.cdc $ADMIN_ADDR $POOL_ID 10)
    if echo "$WINNER_OUTPUT" | grep -qE "(Result:.*\[.*poolID|round|winnerReceiverID|amount)"; then
        echo "$WINNER_OUTPUT" | grep -A 50 "Result:" | head -30
    elif echo "$WINNER_OUTPUT" | grep -qE "(Result:.*\[\])"; then
        print_warn "No winners recorded yet"
    fi
else
    print_warn "PrizeWinnerTracker not configured for this pool"
fi
echo ""

echo -e "${BLUE}========================================${NC}\n"

echo -e "${YELLOW}Next steps:${NC}"
echo "  - Check events in emulator logs"
echo "  - Test strategy updates with admin account"
echo "  - Test multi-winner selection strategy"
echo "  - For production, use --skip-setup and --skip-deploy to speed up testing"
echo "  - For automated draw testing, use ./test_scheduler.sh"
echo ""
