#!/bin/bash
# Simple benchmark: Create 2 receivers and measure draw processing

set -e

echo "=== Simple 2-Receiver Benchmark ==="
echo ""

# Deploy contracts
echo "1. Deploying contracts..."
flow project deploy --update > /dev/null 2>&1
echo "   ✓ Contracts deployed"

# Create pool
echo "2. Creating pool..."
flow transactions send cadence/transactions/test/create_test_pool_medium_interval.cdc \
    --signer emulator-account --compute-limit 9999 > /dev/null 2>&1
echo "   ✓ Pool created (ID: 0)"

# Setup deployer's collection and deposit
echo "3. Setting up deployer as receiver 1..."
flow transactions send cadence/transactions/test/setup_user_collection.cdc \
    --signer emulator-account --compute-limit 9999 > /dev/null 2>&1
flow transactions send cadence/transactions/test/deposit_to_pool.cdc 0 10.0 \
    --signer emulator-account --compute-limit 9999 > /dev/null 2>&1
echo "   ✓ Deployer deposited 10 FLOW"

# Create a second account
echo "4. Creating second receiver account..."
ADDR=$(flow accounts create --key "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a4500a4a6d55a41f3ef3c8d686a4841f8fd5c6db51f7eb4a7c8a6591c3b8c4e4f" 2>&1 | grep "Address" | awk '{print $2}')
echo "   Created account: $ADDR"

# Fund the second account
echo "5. Funding second account..."
flow transactions send cadence/transactions/test/fund_account.cdc $ADDR 20.0 \
    --signer emulator-account --compute-limit 9999 > /dev/null 2>&1
echo "   ✓ Funded with 20 FLOW"

# Check receiver count
echo "6. Checking pool stats..."
STATS=$(flow scripts execute cadence/scripts/prize-savings/get_pool_stats.cdc 0 2>&1)
RECEIVERS=$(echo "$STATS" | grep -o '"registeredUserCount": [0-9]*' | grep -o '[0-9]*')
echo "   Registered receivers: $RECEIVERS"

# Fund lottery
echo "7. Funding lottery pool..."
flow transactions send cadence/transactions/test/fund_lottery_pool.cdc 0 100.0 \
    --signer emulator-account --compute-limit 9999 > /dev/null 2>&1
echo "   ✓ Lottery funded with 100 FLOW"

# Wait for draw to be ready
echo "8. Waiting for draw to be ready (up to 70s)..."
for i in {1..70}; do
    STATUS=$(flow scripts execute cadence/scripts/test/get_draw_status.cdc 0 2>&1)
    if echo "$STATUS" | grep -q '"canDrawNow": true'; then
        echo "   ✓ Draw ready after ${i}s"
        break
    fi
    sleep 1
    if [ $((i % 10)) -eq 0 ]; then
        echo "   Waiting... ${i}s"
    fi
done

# Start draw
echo "9. Starting draw..."
flow transactions send cadence/transactions/test/start_draw.cdc 0 \
    --signer emulator-account --compute-limit 9999 2>&1 | grep -E "(Computation|Transaction ID)"
echo "   ✓ Draw started"

# Process batch - THIS IS WHAT WE WANT TO MEASURE
echo ""
echo "10. PROCESSING BATCH (measuring computation)..."
echo "=========================================="
flow transactions send cadence/transactions/test/process_draw_batch.cdc 0 100 \
    --signer emulator-account --compute-limit 9999 2>&1 | grep -E "(Computation|computation|CU)"

# Also check the emulator's computation report
echo ""
echo "Fetching computation report from emulator..."
curl -s http://localhost:8080/emulator/computationReport | python3 -c "
import sys, json
data = json.load(sys.stdin)
txs = data.get('transactions', {})
if txs:
    print('Recent transactions:')
    for txid, info in list(txs.items())[-3:]:
        print(f'  {txid[:16]}... : {info.get(\"computation\", \"N/A\")} CUs')
"

echo ""
echo "=== Benchmark Complete ==="
