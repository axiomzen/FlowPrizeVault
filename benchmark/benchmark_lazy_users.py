#!/usr/bin/env python3
"""
PrizeLinkedAccounts Lazy User Benchmark

Compares computation costs between:
1. Active users: Deposited during the current round (have TWAB entries)
2. Lazy users: Deposited in previous round, no activity in current round (no TWAB entries)

This tests whether processDrawBatch is more expensive for lazy users who don't have
TWAB dictionary entries in the current round.

Usage:
    python3 benchmark/benchmark_lazy_users.py --users 100
"""

import subprocess
import json
import time
import sys
import os
import re
from pathlib import Path
from typing import Optional, Tuple
from dataclasses import dataclass

# Project paths
PROJECT_ROOT = Path(__file__).parent.parent
os.chdir(PROJECT_ROOT)

# Transaction paths
TX_SETUP_YIELD_VAULT = "cadence/transactions/prize-linked-accounts/setup_test_yield_vault.cdc"
TX_SETUP_COLLECTION = "cadence/transactions/prize-linked-accounts/setup_collection.cdc"
TX_CREATE_POOL = "cadence/transactions/prize-linked-accounts/create_test_pool.cdc"
TX_START_DRAW = "cadence/transactions/prize-linked-accounts/start_draw.cdc"
TX_PROCESS_BATCH = "cadence/transactions/test/process_draw_batch.cdc"
TX_REQUEST_RANDOMNESS = "cadence/transactions/test/request_draw_randomness.cdc"
TX_COMPLETE_DRAW = "cadence/transactions/test/complete_draw.cdc"
TX_FUND_PRIZE_POOL = "cadence/transactions/test/fund_prize_pool.cdc"

BENCHMARK_USERS_TX = PROJECT_ROOT / "benchmark" / "transactions" / "setup_benchmark_users.cdc"

EMULATOR_PORT = 8080
COMPUTE_LIMIT = 99999

# Script paths
SCRIPT_GET_RECEIVER_COUNT = "cadence/scripts/test/get_registered_receiver_count.cdc"
SCRIPT_GET_POOL_STATS = "cadence/scripts/prize-linked-accounts/get_pool_stats.cdc"

# Terminal colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
NC = '\033[0m'

def print_step(msg): print(f"{YELLOW}▶ {msg}{NC}")
def print_success(msg): print(f"{GREEN}✓ {msg}{NC}")
def print_error(msg): print(f"{RED}✗ {msg}{NC}")
def print_info(msg): print(f"  {msg}")
def print_header(msg):
    print(f"\n{BLUE}{'═'*70}")
    print(f"  {msg}")
    print(f"{'═'*70}{NC}\n")

emulator_process = None

def run_flow_script(script_path: str, *args) -> Tuple[bool, str]:
    """Run a Flow script and return (success, output)"""
    cmd = ["flow", "scripts", "execute", script_path, "--network", "emulator"]
    cmd.extend(str(a) for a in args)

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    return result.returncode == 0, output

def get_receiver_count(pool_id: int) -> int:
    """Get the number of registered receivers in a pool"""
    success, output = run_flow_script(SCRIPT_GET_RECEIVER_COUNT, str(pool_id))
    if success:
        # Parse the result - typically looks like "Result: 100"
        match = re.search(r'Result:\s*(\d+)', output)
        if match:
            return int(match.group(1))
        # Try parsing raw number
        try:
            return int(output.strip().split('\n')[-1])
        except:
            pass
    return -1

def download_profile(filename: str) -> bool:
    """Download computation profile from emulator and save to file"""
    try:
        result = subprocess.run(
            ["curl", "-s", f"http://localhost:{EMULATOR_PORT}/emulator/computationProfile"],
            capture_output=True, timeout=30
        )
        if result.returncode == 0 and result.stdout:
            results_dir = PROJECT_ROOT / "benchmark" / "results"
            results_dir.mkdir(exist_ok=True)
            filepath = results_dir / filename
            with open(filepath, 'wb') as f:
                f.write(result.stdout)
            print_success(f"Profile saved to {filepath}")
            return True
    except Exception as e:
        print_error(f"Failed to download profile: {e}")
    return False

def reset_profiler():
    """Reset the emulator's computation profiler"""
    try:
        subprocess.run(
            ["curl", "-s", "-X", "POST", f"http://localhost:{EMULATOR_PORT}/emulator/computationProfile/reset"],
            capture_output=True, timeout=10
        )
    except:
        pass

def get_computation_for_tx(tx_id: str) -> int:
    """Get computation for a specific transaction from emulator report"""
    try:
        result = subprocess.run(
            ["curl", "-s", f"http://localhost:{EMULATOR_PORT}/emulator/computationReport"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout:
            report = json.loads(result.stdout)
            tx_data = report.get('transactions', {}).get(tx_id, {})
            return tx_data.get('computation', 0)
    except:
        pass
    return 0

def run_flow_tx(tx_path: str, *args, compute_limit: int = COMPUTE_LIMIT) -> Tuple[bool, str, Optional[str], int]:
    """Run a Flow transaction and return (success, output, tx_id, computation)"""
    cmd = ["flow", "transactions", "send", tx_path, "--network", "emulator",
           "--compute-limit", str(compute_limit), "--output", "json"]
    cmd.extend(str(a) for a in args)

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    output = result.stdout + result.stderr

    tx_id = None
    computation = 0

    # Parse JSON output to get transaction ID and check for errors
    try:
        data = json.loads(result.stdout)
        tx_id = data.get('id') or data.get('transactionId')
        # Check if there's an error in the JSON response
        if data.get('error') or data.get('status') == 'FAILED':
            return False, output, tx_id, computation
    except json.JSONDecodeError:
        # Fallback to regex parsing
        tx_match = re.search(r'ID\s+([a-f0-9]{64})', output)
        if tx_match:
            tx_id = tx_match.group(1)

    # Get computation from emulator report using tx_id
    if tx_id:
        computation = get_computation_for_tx(tx_id)

    # Also check for error patterns in output
    success = result.returncode == 0 and '"error"' not in output.lower()
    return success, output, tx_id, computation

def kill_existing_emulator():
    print_step("Killing any existing emulator...")
    subprocess.run(["pkill", "-f", "flow emulator"], capture_output=True)
    time.sleep(2)
    print_success("Existing emulator killed")

def start_emulator(enable_profiling: bool = False) -> bool:
    global emulator_process
    print_step("Starting emulator...")

    cmd = ["flow", "emulator", "--block-time", "1s", "--computation-reporting", "--verbose=false"]
    if enable_profiling:
        cmd.append("--computation-profiling")
        print_info("Computation profiling enabled")
    emulator_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    # Wait for emulator
    for i in range(30):
        time.sleep(1)
        result = subprocess.run(
            ["flow", "accounts", "get", "f8d6e0586b0a20c7", "--network", "emulator"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            print_success(f"Emulator started (PID: {emulator_process.pid})")
            return True
        if i % 5 == 4:
            print_info(f"Waiting for emulator... ({i+1}/30)")

    print_error("Emulator failed to start")
    return False

def stop_emulator():
    global emulator_process
    if emulator_process:
        print_step("Stopping emulator...")
        emulator_process.terminate()
        try:
            emulator_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            emulator_process.kill()
        emulator_process = None
        print_success("Emulator stopped")

def deploy_contracts() -> bool:
    print_step("Deploying contracts...")
    result = subprocess.run(
        ["flow", "deploy", "--network", "emulator", "--update"],
        capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        print_error("Failed to deploy contracts")
        print_info(result.stderr[:500])
        return False
    print_success("Contracts deployed")
    return True

def setup_pool() -> Optional[int]:
    """Setup yield vault, collection, and create pool. Return pool ID."""
    print_step("Setting up test yield vault...")
    success, output, _, _ = run_flow_tx(TX_SETUP_YIELD_VAULT)
    if not success and 'already' not in output.lower():
        print_error("Failed to setup yield vault")
        return None

    print_step("Setting up admin collection...")
    success, output, _, _ = run_flow_tx(TX_SETUP_COLLECTION)
    if not success and 'already' not in output.lower():
        print_error("Failed to setup collection")
        return None

    print_step("Creating test pool...")
    # create_test_pool args: minimumDeposit, drawIntervalSeconds, rewardsPercent, prizePercent, protocolFeePercent
    success, output, _, _ = run_flow_tx(TX_CREATE_POOL, "1.0", "1.0", "0.5", "0.4", "0.1")
    if not success:
        print_error("Failed to create pool")
        print_info(output[:300])
        return None

    # Extract pool ID
    match = re.search(r'Created pool with ID:\s*(\d+)', output)
    if match:
        pool_id = int(match.group(1))
        print_success(f"Pool created with ID: {pool_id}")
        return pool_id

    print_success("Pool created (assuming ID: 0)")
    return 0

def create_users(pool_id: int, user_count: int) -> bool:
    """Create users and deposit into pool."""
    print_step(f"Creating {user_count} users with deposits...")

    batch_size = 50
    for batch_start in range(0, user_count, batch_size):
        current_batch = min(batch_size, user_count - batch_start)
        success, output, _, comp = run_flow_tx(
            str(BENCHMARK_USERS_TX),
            str(pool_id), str(current_batch), "10.0", str(batch_start),
            compute_limit=99999
        )
        if not success:
            print_error(f"Failed to create batch at {batch_start}")
            return False

    print_success(f"Created {user_count} users")
    return True

def run_complete_draw(pool_id: int) -> bool:
    """Run a complete draw cycle (all 4 phases)."""
    # Phase 1: startDraw
    success, _, _, _ = run_flow_tx(TX_START_DRAW, str(pool_id))
    if not success:
        return False

    # Phase 2: processDrawBatch (loop until complete)
    for _ in range(100):
        success, output, _, _ = run_flow_tx(TX_PROCESS_BATCH, str(pool_id), "9999")
        if not success:
            return False
        if "remaining: 0" in output.lower() or "batch complete" in output.lower():
            break

    # Phase 3: requestDrawRandomness
    success, _, _, _ = run_flow_tx(TX_REQUEST_RANDOMNESS, str(pool_id))
    if not success:
        return False

    time.sleep(2)  # Wait for next block

    # Phase 4: completeDraw
    success, _, _, _ = run_flow_tx(TX_COMPLETE_DRAW, str(pool_id))
    return success

def benchmark_process_draw_batch(pool_id: int, user_count: int, batch_size: int, debug: bool = True, profile: bool = False, profile_name: str = "") -> Optional[int]:
    """Run startDraw and processDrawBatch, return total computation for batch processing."""

    if profile:
        reset_profiler()

    if debug:
        receiver_count = get_receiver_count(pool_id)
        print_info(f"[DEBUG] Registered receivers before startDraw: {receiver_count}")

    # Start the draw
    success, output, _, start_comp = run_flow_tx(TX_START_DRAW, str(pool_id))
    if not success:
        print_error("Failed to start draw")
        print_info(output[:500])
        return None
    print_info(f"startDraw computation: {start_comp} CU")

    if debug:
        receiver_count = get_receiver_count(pool_id)
        print_info(f"[DEBUG] Registered receivers after startDraw: {receiver_count}")

    # Process batch - loop until complete
    total_batch_comp = 0
    batch_count = 0
    for _ in range(100):  # Max iterations to prevent infinite loop
        success, output, tx_id, batch_comp = run_flow_tx(TX_PROCESS_BATCH, str(pool_id), str(batch_size))

        if not success:
            # Check if it's "batch already complete" error - this is expected and means we're done
            if "batch processing already complete" in output.lower() or "already complete" in output.lower():
                if debug:
                    print_info(f"[DEBUG] Batch processing complete (detected via error)")
                break
            # Other errors are real failures
            print_error("Failed to process batch")
            print_info(output[:500])
            return None

        total_batch_comp += batch_comp
        batch_count += 1

        if debug and batch_count == 1:
            # Check if batch processing output has useful info (but not error keyword from events)
            print_info(f"[DEBUG] processDrawBatch output snippet: {output[:300]}")

        # Check if batch is complete (remaining: 0 or similar in events)
        if '"remaining":0' in output.replace(' ', '') or 'remaining: 0' in output.lower():
            if debug:
                print_info(f"[DEBUG] Batch processing complete (remaining: 0)")
            break

    print_info(f"processDrawBatch computation: {total_batch_comp} CU ({batch_count} batch(es))")

    if profile and profile_name:
        download_profile(f"{profile_name}.pprof")

    return total_batch_comp

def main():
    import argparse
    parser = argparse.ArgumentParser(
        description='Compare processDrawBatch computation for active vs lazy users',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
This benchmark tests the hypothesis that users who deposited in a previous round
(lazy users) have different computation costs than users who deposited in the
current round (active users).

Active users: Have TWAB dictionary entries from deposit
Lazy users: No TWAB entries, uses default values (nil coalescing)
        """
    )
    parser.add_argument('--users', type=int, default=100, help='Number of users (default: 100)')
    parser.add_argument('--debug', action='store_true', help='Enable debug output')
    parser.add_argument('--profile', action='store_true', help='Enable computation profiling (saves pprof files)')
    args = parser.parse_args()

    debug = args.debug
    profile = args.profile

    user_count = args.users

    try:
        kill_existing_emulator()
        if not start_emulator(enable_profiling=profile):
            return 1

        subprocess.run(["flow", "deps", "install"], capture_output=True, timeout=60)

        if not deploy_contracts():
            return 1

        pool_id = setup_pool()
        if pool_id is None:
            return 1

        # Create users (they deposit in Round 0)
        if not create_users(pool_id, user_count):
            return 1

        # Fund the prize pool so draws can complete
        print_step("Funding prize pool...")
        success, output, _, _ = run_flow_tx(TX_FUND_PRIZE_POOL, str(pool_id), "100.0")
        if not success:
            print_error("Failed to fund prize pool")
            print_info(output[:300])
            return 1
        print_success("Prize pool funded with 100 FLOW")

        print_header(f"TEST 1: ACTIVE USERS ({user_count} users)")
        print_info("Users deposited THIS round - have TWAB dictionary entries")
        print_info("Waiting for round to end...")
        time.sleep(3)

        active_comp = benchmark_process_draw_batch(pool_id, user_count, user_count, debug=debug, profile=profile, profile_name=f"active_users_{user_count}")
        if active_comp is None:
            print_error("Failed to benchmark active users")
            return 1

        active_per_user = active_comp / user_count
        print_success(f"processDrawBatch computation: {active_comp} CU")
        print_info(f"Per user: {active_per_user:.2f} CU")

        # Complete the draw so we can start Round 1
        print_info("Completing Round 0 draw...")
        if debug:
            receiver_count = get_receiver_count(pool_id)
            print_info(f"[DEBUG] Registered receivers before completeDraw: {receiver_count}")

        success, output, _, req_comp = run_flow_tx(TX_REQUEST_RANDOMNESS, str(pool_id))
        if not success:
            print_error("Failed requestDrawRandomness")
            print_info(output[:1000])
            return 1
        if debug:
            print_info(f"[DEBUG] requestDrawRandomness computation: {req_comp} CU")

        # Wait for next block (randomness isn't available until different block)
        if debug:
            print_info("[DEBUG] Waiting for randomness to be available (3 blocks)...")
        time.sleep(4)

        # Try completeDraw with retries
        for attempt in range(3):
            success, output, _, complete_comp = run_flow_tx(TX_COMPLETE_DRAW, str(pool_id))
            if success:
                if debug:
                    print_info(f"[DEBUG] completeDraw computation: {complete_comp} CU")
                break
            else:
                if debug:
                    print_info(f"[DEBUG] completeDraw attempt {attempt+1} failed, waiting...")
                    print_info(f"[DEBUG] Error: {output[:300]}")
                time.sleep(2)
        else:
            print_error("Failed completeDraw after 3 attempts")
            return 1

        if debug:
            receiver_count = get_receiver_count(pool_id)
            print_info(f"[DEBUG] Registered receivers after completeDraw: {receiver_count}")

        print_header(f"TEST 2: LAZY USERS ({user_count} users)")
        print_info("Users deposited in PREVIOUS round - NO TWAB dictionary entries")
        print_info("(Same users, but they didn't interact in Round 1)")
        print_info("Waiting for round to end...")
        time.sleep(3)

        lazy_comp = benchmark_process_draw_batch(pool_id, user_count, user_count, debug=debug, profile=profile, profile_name=f"lazy_users_{user_count}")
        if lazy_comp is None:
            print_error("Failed to benchmark lazy users")
            return 1

        lazy_per_user = lazy_comp / user_count
        print_success(f"processDrawBatch computation: {lazy_comp} CU")
        print_info(f"Per user: {lazy_per_user:.2f} CU")

        # Summary
        print_header("COMPARISON RESULTS")
        print(f"{'Scenario':<25} {'Total CU':<15} {'Per User':<15}")
        print("-" * 55)
        print(f"{'Active Users (Round 0)':<25} {active_comp:<15} {active_per_user:<15.2f}")
        print(f"{'Lazy Users (Round 1)':<25} {lazy_comp:<15} {lazy_per_user:<15.2f}")
        print("-" * 55)

        diff = lazy_comp - active_comp
        diff_pct = (diff / active_comp) * 100 if active_comp > 0 else 0

        if diff > 0:
            print(f"{'Difference':<25} {'+' + str(diff):<15} {'+' + f'{diff_pct:.1f}%':<15}")
            print(f"\n{YELLOW}Lazy users are MORE expensive by {diff_pct:.1f}%{NC}")
        elif diff < 0:
            print(f"{'Difference':<25} {str(diff):<15} {f'{diff_pct:.1f}%':<15}")
            print(f"\n{GREEN}Lazy users are LESS expensive by {abs(diff_pct):.1f}%{NC}")
        else:
            print(f"\n{GREEN}No significant difference{NC}")

        return 0

    finally:
        stop_emulator()

if __name__ == "__main__":
    sys.exit(main())
