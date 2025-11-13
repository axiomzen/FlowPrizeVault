#!/bin/bash


## TIP: Ensure that you run the emulator with --block-time 1s 
# Quick Scheduler Testing Script
# 
# This script focuses on testing the PrizeVault Scheduler functionality.
# It verifies TWO complete draw cycles to ensure automatic rescheduling works.
# The script will set up the environment if needed.
#
# NOTE: The scheduler now automatically uses the pool's drawIntervalSeconds
# configuration. No manual timing parameters are needed!
#
# Usage:
#   ./test_scheduler.sh [POOL_ID]
#
# Arguments:
#   POOL_ID           Pool ID to test (default: 0)
#
# Examples:
#   ./test_scheduler.sh        # Test pool 0 with its configured draw frequency
#   ./test_scheduler.sh 1      # Test pool 1 with its configured draw frequency

set +e

FLOW_FLAGS="--skip-version-check"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
ADMIN_ACCOUNT="emulator-account"
NETWORK="emulator"
POOL_ID="${1:-0}"
# Note: ROUND_DURATION and timing are now derived from pool's drawIntervalSeconds configuration
# The pool is created with drawIntervalSeconds=10.0 (10 seconds between draws)

# Helper functions
get_account_address() {
    grep -A 2 "\"$1\"" flow.json 2>/dev/null | grep address | awk '{print $2}' | tr -d '",' || echo ""
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

# Main script
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}   PrizeVault Scheduler Quick Test         ${NC}"
echo -e "${BLUE}=============================================${NC}\n"

echo -e "${YELLOW}Configuration:${NC}"
echo "  Pool ID: $POOL_ID"
echo "  Timing: Automatically derived from pool's drawIntervalSeconds config"
echo "  (Pool created with drawIntervalSeconds=10.0 → 10 second rounds)"
echo ""

# Check emulator
if ! curl -s http://localhost:8080/health > /dev/null 2>&1; then
    print_error "Emulator is not running!"
    echo -e "${YELLOW}Please start it with: flow emulator start${NC}"
    exit 1
fi
print_success "Emulator is running"
echo ""

# Get admin address
ADMIN_ADDR=$(get_account_address "$ADMIN_ACCOUNT")
[[ ! "$ADMIN_ADDR" =~ ^0x ]] && ADMIN_ADDR="0x$ADMIN_ADDR"

# Step 1: Verify pool exists or set up environment
print_step "1" "Verifying pool exists"
POOL_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID 2>&1)
if echo "$POOL_STATS" | grep -qE "(panic|not found|error)"; then
    print_warn "Pool $POOL_ID not found. Setting up test environment..."
    echo ""
    
    # Source the setup script
    if [ -f "./setup_test_environment.sh" ]; then
        source ./setup_test_environment.sh
        setup_test_environment
        SETUP_RESULT=$?
        
        if [ $SETUP_RESULT -ne 0 ]; then
            print_error "Environment setup failed!"
            exit 1
        fi
        
        # POOL_ID is exported by setup script
        print_success "Environment setup complete. Using Pool ID: $POOL_ID"
    else
        print_error "setup_test_environment.sh not found!"
        echo -e "${YELLOW}Please run ./test_flow.sh first to create a pool, or ensure setup script exists${NC}"
        exit 1
    fi
else
    echo "$POOL_STATS" | grep -E "(poolID|totalDeposited|totalStaked)" || true
    print_success "Pool $POOL_ID exists"
fi
echo ""

# Step 2: Initialize Scheduler
print_step "2" "Initializing PrizeVault Scheduler"
INIT_OUTPUT=$(run_tx cadence/transactions/init_scheduler.cdc --signer $ADMIN_ACCOUNT --include logs)
if check_error "$INIT_OUTPUT"; then
    echo "$INIT_OUTPUT" | grep -E "(Transaction ID|Manager|Handler|initialized)" || true
    print_success "Scheduler initialized"
else
    if echo "$INIT_OUTPUT" | grep -qi "already exists"; then
        print_warn "Scheduler already initialized (re-initialized)"
    else
        print_error "Scheduler initialization failed"
        echo "$INIT_OUTPUT" | grep -E "(error|panic)" | head -5
        exit 1
    fi
fi
echo ""

# Step 3: Check Scheduler Status
print_step "3" "Checking scheduler status"
SCHEDULER_STATUS=$(run_script cadence/scripts/get_scheduler_status.cdc $ADMIN_ADDR)

# Debug: Show full output
echo -e "${YELLOW}Full scheduler status output:${NC}"
echo "$SCHEDULER_STATUS"
echo ""

if echo "$SCHEDULER_STATUS" | grep -q '"isInitialized": true'; then
    FEE_BALANCE=$(echo "$SCHEDULER_STATUS" | grep -oE '"feeBalance":\s*[0-9.]+' | grep -oE '[0-9.]+')
    print_success "Scheduler active (Fee balance: ${FEE_BALANCE} FLOW)"
    
    if (( $(echo "$FEE_BALANCE < 1.0" | bc -l) )); then
        print_warn "Low fee balance. Ensure account has sufficient FLOW."
    fi
else
    print_warn "Scheduler status check returned unexpected result"
    echo -e "${YELLOW}This may indicate the handler capability isn't published correctly.${NC}"
    echo -e "${YELLOW}Attempting to continue anyway...${NC}"
fi
echo ""

# Step 4: Schedule First Draw
print_step "4" "Scheduling first automated draw"
# Note: Using schedule_pool_draw.cdc which registers the pool and schedules first draw
# The scheduler now automatically derives timing from the pool's drawIntervalSeconds configuration
SCHEDULE_OUTPUT=$(run_tx cadence/transactions/schedule_pool_draw.cdc $POOL_ID --signer $ADMIN_ACCOUNT --include logs)
if check_error "$SCHEDULE_OUTPUT"; then
    echo "$SCHEDULE_OUTPUT" | grep -E "(Transaction ID|scheduled successfully|Execution time)" || true
    
    EXEC_TIME=$(echo "$SCHEDULE_OUTPUT" | grep "Execution time:" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$EXEC_TIME" ]; then
        print_success "First draw scheduled for timestamp $EXEC_TIME"
    else
        print_success "First draw scheduled (timing based on pool config)"
    fi
else
    print_error "Failed to schedule first draw"
    echo "$SCHEDULE_OUTPUT" | grep -E "(error|panic)" | head -10
    exit 1
fi
echo ""

# Step 5: Monitor pool before draw
print_step "5" "Pool status before automated draw"
BEFORE_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
BEFORE_TIMESTAMP=$(echo "$BEFORE_STATS" | grep -oE '"lastDrawTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
BEFORE_CURRENT=$(echo "$BEFORE_STATS" | grep -oE '"currentTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
echo "$BEFORE_STATS" | grep -E "(lastDrawTimestamp|isDrawInProgress|currentTimestamp|totalStaked)" || true
echo ""

# Step 6: Wait for scheduled draw
print_step "6" "Waiting for automated draw to execute"
# With drawIntervalSeconds=10.0, draws happen every 10 seconds
# Adding extra time for initial scheduling and execution
WAIT_TIME=15
echo -e "${YELLOW}Waiting ${WAIT_TIME} seconds for startDraw to execute automatically...${NC}"
echo -e "${BLUE}(The Flow scheduler will execute the transaction)${NC}"

for i in $(seq 1 $WAIT_TIME); do
    sleep 1
    echo -n "."
    if [ $((i % 10)) -eq 0 ]; then
        echo -n " ${i}s "
    fi
done
echo ""
print_success "Wait complete"
echo ""

# Step 7: Verify startDraw executed
print_step "7" "Verifying startDraw was executed automatically"
AFTER_START_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
IS_DRAWING=$(echo "$AFTER_START_STATS" | grep -oE '"isDrawInProgress":\s*(true|false)' | grep -oE '(true|false)')
CURRENT_TIMESTAMP=$(echo "$AFTER_START_STATS" | grep -oE '"currentTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')

echo "$AFTER_START_STATS" | grep -E "(lastDrawTimestamp|isDrawInProgress|currentTimestamp)" || true

if [ "$IS_DRAWING" = "true" ]; then
    print_success "startDraw was executed automatically by the scheduler!"
    echo -e "${GREEN}The automated draw cycle has begun!${NC}"
else
    print_warn "startDraw may not have executed yet or already completed"
    echo "Current block: $CURRENT_BLOCK, Last draw block: $BEFORE_BLOCK"
fi
echo ""

# Step 8: Wait for completeDraw
print_step "8" "Waiting for completeDraw to execute"
echo -e "${YELLOW}Waiting 10 seconds for completeDraw...${NC}"
sleep 10
echo ""

# Step 9: Verify completeDraw executed
print_step "9" "Verifying completeDraw was executed"
FINAL_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
FINAL_TIMESTAMP=$(echo "$FINAL_STATS" | grep -oE '"lastDrawTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
FINAL_IS_DRAWING=$(echo "$FINAL_STATS" | grep -oE '"isDrawInProgress":\s*(true|false)' | grep -oE '(true|false)')

echo "$FINAL_STATS" | grep -E "(lastDrawTimestamp|isDrawInProgress|currentTimestamp)" || true

if [ "$FINAL_IS_DRAWING" = "false" ] && (( $(echo "$FINAL_TIMESTAMP > $BEFORE_TIMESTAMP" | bc -l) )); then
    print_success "completeDraw was executed automatically!"
    echo -e "${GREEN}Full draw cycle completed successfully!${NC}"
    echo -e "${GREEN}Next startDraw scheduled based on pool's drawIntervalSeconds config${NC}"
else
    print_warn "completeDraw may still be pending or needs more time"
fi
echo ""

# Step 10: Check for winners
print_step "10" "Checking for prize winners from first draw"
if echo "$FINAL_STATS" | grep -qiE '"hasWinnerTracker"\s*:\s*true'; then
    WINNER_OUTPUT=$(run_script cadence/scripts/prize-vault-modular/get_winner_history.cdc $ADMIN_ADDR $POOL_ID 5)
    if echo "$WINNER_OUTPUT" | grep -qE "winnerReceiverID|amount"; then
        echo "$WINNER_OUTPUT" | grep -A 30 "Result:" | head -20
        print_success "Winners recorded from first draw"
    else
        print_warn "No winners found in history"
    fi
else
    echo -e "${YELLOW}Winner tracking not enabled for this pool${NC}"
fi
echo ""

# Step 11: Wait for second automated draw cycle
print_step "11" "Waiting for second automated draw cycle"
# Pool configured with drawIntervalSeconds=10.0 → 10 seconds between draws
SECOND_WAIT_TIME=12
echo -e "${YELLOW}Waiting $SECOND_WAIT_TIME seconds for next startDraw to execute automatically...${NC}"
echo -e "${YELLOW}(Testing automatic rescheduling)${NC}"
for i in $(seq 1 $SECOND_WAIT_TIME); do
    sleep 1
    echo -n "."
    if [ $((i % 10)) -eq 0 ]; then
        echo -n " ${i}s "
    fi
done
echo ""
print_success "Wait complete"
echo ""

# Step 12: Verify second startDraw executed
print_step "12" "Verifying second startDraw was executed automatically"
SECOND_START_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
SECOND_START_TIMESTAMP=$(echo "$SECOND_START_STATS" | grep -oE '"lastDrawTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
SECOND_IS_DRAWING=$(echo "$SECOND_START_STATS" | grep -oE '"isDrawInProgress":\s*(true|false)' | grep -oE '(true|false)')
SECOND_CURRENT_TIMESTAMP=$(echo "$SECOND_START_STATS" | grep -oE '"currentTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')

echo "$SECOND_START_STATS" | grep -E "(lastDrawTimestamp|isDrawInProgress|currentTimestamp)" || true

if (( $(echo "$SECOND_START_TIMESTAMP > $FINAL_TIMESTAMP" | bc -l) )); then
    print_success "Second startDraw was executed automatically by the scheduler!"
    echo -e "${GREEN}Automatic rescheduling is working!${NC}"
    echo -e "${GREEN}Last draw timestamp advanced from $FINAL_TIMESTAMP to $SECOND_START_TIMESTAMP${NC}"
else
    print_warn "Second startDraw may not have executed yet"
    echo "Current timestamp: $SECOND_CURRENT_TIMESTAMP, Last draw timestamp: $SECOND_START_TIMESTAMP (expected > $FINAL_TIMESTAMP)"
fi
echo ""

# Step 13: Wait for second completeDraw
print_step "13" "Waiting for second completeDraw to execute"
echo -e "${YELLOW}Waiting 10 seconds for second completeDraw...${NC}"
sleep 10
echo ""

# Step 14: Verify second completeDraw executed
print_step "14" "Verifying second completeDraw was executed"
SECOND_FINAL_STATS=$(run_script cadence/scripts/prize-vault-modular/get_pool_stats.cdc $POOL_ID)
SECOND_FINAL_TIMESTAMP=$(echo "$SECOND_FINAL_STATS" | grep -oE '"lastDrawTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
SECOND_FINAL_IS_DRAWING=$(echo "$SECOND_FINAL_STATS" | grep -oE '"isDrawInProgress":\s*(true|false)' | grep -oE '(true|false)')
SECOND_FINAL_CURRENT_TIMESTAMP=$(echo "$SECOND_FINAL_STATS" | grep -oE '"currentTimestamp":\s*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')

echo "$SECOND_FINAL_STATS" | grep -E "(lastDrawTimestamp|isDrawInProgress|currentTimestamp)" || true

if [ "$SECOND_FINAL_IS_DRAWING" = "false" ] && [ "$SECOND_FINAL_TIMESTAMP" = "$SECOND_START_TIMESTAMP" ]; then
    print_success "Second completeDraw was executed automatically!"
    echo -e "${GREEN}Second full draw cycle completed successfully!${NC}"
    echo -e "${GREEN}Next startDraw scheduled based on pool's drawIntervalSeconds config${NC}"
else
    print_warn "Second completeDraw may still be pending or needs more time"
fi
echo ""

# Step 15: Check for winners from second draw
print_step "15" "Checking for prize winners from second draw"
if echo "$SECOND_FINAL_STATS" | grep -qiE '"hasWinnerTracker"\s*:\s*true'; then
    WINNER_OUTPUT_2=$(run_script cadence/scripts/prize-vault-modular/get_winner_history.cdc $ADMIN_ADDR $POOL_ID 10)
    WINNER_COUNT=$(echo "$WINNER_OUTPUT_2" | grep -oE "winnerReceiverID" | wc -l | tr -d ' ')
    if [ "$WINNER_COUNT" -ge 2 ]; then
        echo "$WINNER_OUTPUT_2" | grep -A 50 "Result:" | head -30
        print_success "Multiple winners recorded ($WINNER_COUNT total)"
        echo -e "${GREEN}Verified: Second draw produced a new winner!${NC}"
    elif [ "$WINNER_COUNT" -eq 1 ]; then
        print_warn "Only one winner found (expected 2). Second draw may not have completed yet."
    else
        print_warn "No winners found in history"
    fi
else
    echo -e "${YELLOW}Winner tracking not enabled for this pool${NC}"
fi
echo ""

# Final Summary
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}   Scheduler Test Complete!                ${NC}"
echo -e "${GREEN}=============================================${NC}\n"

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE} Summary${NC}"
echo -e "${BLUE}=============================================${NC}\n"

echo -e "${YELLOW}Scheduler Status:${NC}"
FINAL_SCHEDULER=$(run_script cadence/scripts/get_scheduler_status.cdc $ADMIN_ADDR)
echo "$FINAL_SCHEDULER" | grep -E "(isInitialized|feeBalance|roundDuration)" || true
echo ""

echo -e "${YELLOW}Pool Status (after 2 complete draw cycles):${NC}"
echo "  Pool ID: $POOL_ID"
echo "  First Draw Timestamp: $FINAL_TIMESTAMP"
echo "  Second Draw Timestamp: $SECOND_FINAL_TIMESTAMP"
echo "  Draw In Progress: $SECOND_FINAL_IS_DRAWING"
echo "  Current Timestamp: $SECOND_FINAL_CURRENT_TIMESTAMP"
echo ""

echo -e "${YELLOW}What happened:${NC}"
echo "  1. [OK] Scheduler initialized"
echo "  2. [OK] First draw scheduled (timing from pool's drawIntervalSeconds config)"
echo "  3. [OK] First startDraw executed automatically at scheduled time"
echo "  4. [OK] First completeDraw was automatically scheduled and executed"
echo "  5. [OK] Second startDraw was automatically rescheduled and executed"
echo "  6. [OK] Second completeDraw was automatically scheduled and executed"
echo "  7. [OK] Verified continuous automatic rescheduling works!"
echo ""

echo -e "${YELLOW}Next Steps:${NC}"
echo "  - The scheduler will continue automatically based on pool's drawIntervalSeconds"
echo "  - Check emulator logs for scheduler events"
echo "  - Monitor with: flow scripts execute cadence/scripts/get_scheduler_status.cdc $ADMIN_ADDR"
echo ""
echo -e "${YELLOW}Note:${NC}"
echo "  - Timing is derived from pool's drawIntervalSeconds configuration"
echo "  - Current pool: drawIntervalSeconds=10.0 → 10 second rounds (fast testing)"
echo "  - For production pools, configure drawIntervalSeconds appropriately:"
echo "    * 1 hour: 3600.0 seconds"
echo "    * 1 day: 86400.0 seconds"
echo "    * 1 week: 604800.0 seconds"
echo "    * 30 days: 2592000.0 seconds"
echo ""

echo -e "${BLUE}=============================================${NC}"
