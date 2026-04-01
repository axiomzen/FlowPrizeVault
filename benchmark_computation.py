#!/usr/bin/env python3
"""
Flow PrizeSavings Computation Benchmark

Measures the computational units (CUs) consumed by draw operations
with configurable user counts.

Uses the emulator's HTTP computation reporting endpoint to get accurate CU data.
See: https://developers.flow.com/build/cadence/advanced-concepts/computation-profiling

Prerequisites:
1. Flow CLI installed
2. Run: flow emulator --block-time 1s --computation-reporting (in a separate terminal)
3. This script will deploy contracts and run benchmarks

Usage:
    python3 benchmark_computation.py --quick             # Quick single-user benchmark
    python3 benchmark_computation.py --users 100         # 100 users (uses batch deposits)
    python3 benchmark_computation.py --users 100 --batch-size 50  # Custom batch size
    python3 benchmark_computation.py --scale             # Scaling test (1, 5, 10, 25, 50 users)
    python3 benchmark_computation.py --find-limit        # Find max users per batch transaction
"""

import subprocess
import re
import time
import argparse
import sys
import urllib.request
import urllib.error
import json
from dataclasses import dataclass, field
from typing import Optional, List
from datetime import datetime


# ============================================================================
# CONFIGURATION
# ============================================================================

FLOW_JSON_PATH = "flow.json"
DEPLOYER_ACCOUNT = "emulator-account"
SERVICE_ACCOUNT = "emulator-account"

# Emulator admin API endpoint for computation reporting
EMULATOR_ADMIN_URL = "http://localhost:8080"

# Transaction paths
TX_PATH = "cadence/transactions/test"
SCRIPT_PATH = "cadence/scripts/test"

# Default values
DEFAULT_DEPOSIT_AMOUNT = 10.0
DEFAULT_PRIZE_AMOUNT = 100.0
DEFAULT_BATCH_SIZE = 100

# Draw interval is 60 seconds in the medium interval pool
DRAW_WAIT_TIMEOUT = 180


# ============================================================================
# DATA CLASSES
# ============================================================================

@dataclass
class TransactionResult:
    """Result of a Flow transaction."""
    success: bool
    computation: Optional[int] = None
    tx_id: Optional[str] = None
    output: str = ""
    error: str = ""


@dataclass
class BenchmarkResult:
    """Result of a single benchmark run."""
    user_count: int
    batch_size: int

    # Individual transaction costs
    create_pool_cu: int = 0
    setup_users_total_cu: int = 0
    deposit_cus: List[int] = field(default_factory=list)
    fund_lottery_cu: int = 0
    start_draw_cu: int = 0
    batch_cus: List[int] = field(default_factory=list)
    request_randomness_cu: int = 0
    complete_draw_cu: int = 0

    @property
    def total_deposit_cu(self) -> int:
        return sum(self.deposit_cus)

    @property
    def avg_deposit_cu(self) -> float:
        return self.total_deposit_cu / len(self.deposit_cus) if self.deposit_cus else 0

    @property
    def total_batch_cu(self) -> int:
        return sum(self.batch_cus)

    @property
    def avg_batch_cu(self) -> float:
        return self.total_batch_cu / len(self.batch_cus) if self.batch_cus else 0

    @property
    def per_user_batch_cu(self) -> float:
        return self.total_batch_cu / self.user_count if self.user_count > 0 else 0

    @property
    def total_draw_cu(self) -> int:
        """Total CUs for entire draw process (excluding setup)."""
        return (self.start_draw_cu +
                self.total_batch_cu +
                self.request_randomness_cu +
                self.complete_draw_cu)


# ============================================================================
# COMPUTATION REPORTING (HTTP API)
# ============================================================================

def get_computation_report() -> dict:
    """
    Fetch computation report from the emulator's admin API.

    Returns JSON with structure:
    {
        "transactions": {
            "<tx-id>": {
                "computation": 123,
                "intensities": {...},
                "memory": 456
            }
        },
        "scripts": {...}
    }
    """
    url = f"{EMULATOR_ADMIN_URL}/emulator/computationReport"
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return json.loads(response.read().decode())
    except urllib.error.URLError as e:
        print(f"    → Warning: Could not fetch computation report: {e}")
        return {}
    except json.JSONDecodeError:
        return {}


def get_transaction_computation(tx_id: str) -> Optional[int]:
    """Get computation for a specific transaction from the emulator report."""
    if not tx_id:
        return None

    report = get_computation_report()
    transactions = report.get("transactions", {})

    # Try exact match first
    if tx_id in transactions:
        return transactions[tx_id].get("computation")

    # Try partial match (transaction IDs might be formatted differently)
    for key, data in transactions.items():
        if tx_id.lower() in key.lower() or key.lower() in tx_id.lower():
            return data.get("computation")

    return None


def reset_computation_profile():
    """Reset the computation profile (useful between test runs)."""
    url = f"{EMULATOR_ADMIN_URL}/emulator/computationProfile/reset"
    try:
        req = urllib.request.Request(url, method='PUT')
        with urllib.request.urlopen(req, timeout=5):
            pass
    except urllib.error.URLError:
        pass  # Ignore errors


# ============================================================================
# FLOW CLI HELPERS
# ============================================================================

def run_command(cmd: List[str]) -> subprocess.CompletedProcess:
    """Run a shell command and return the result."""
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=300
    )


def parse_tx_id(output: str) -> Optional[str]:
    """Parse transaction ID from CLI output."""
    # Try "Transaction ID: xxx" format
    match = re.search(r'Transaction ID:\s*([a-f0-9]+)', output, re.IGNORECASE)
    if match:
        return match.group(1)
    # Try "id": "xxx" JSON format
    match = re.search(r'"id":\s*"([a-f0-9]+)"', output)
    if match:
        return match.group(1)
    return None


def run_transaction(tx_path: str, args: List[str] = None, signer: str = None,
                    quiet: bool = False,
                    compute_limit: int = 9999) -> TransactionResult:
    """Execute a Flow transaction and get computation from HTTP endpoint."""
    if signer is None:
        signer = DEPLOYER_ACCOUNT

    cmd = ["flow", "transactions", "send", tx_path,
           "--signer", signer,
           "--compute-limit", str(compute_limit)]
    if args:
        cmd.extend([str(a) for a in args])

    if not quiet:
        print(f"  Running: {tx_path.split('/')[-1]} "
              f"{' '.join(str(a) for a in (args or []))}")

    result = run_command(cmd)
    combined_output = result.stdout + result.stderr

    # Parse transaction ID
    tx_id = parse_tx_id(combined_output)
    success = result.returncode == 0

    # Check for errors
    if "error" in combined_output.lower() and "error:" in combined_output.lower():
        success = False
    if "panic" in combined_output.lower() or "revert" in combined_output.lower():
        success = False

    computation = None

    # Get computation from the emulator's HTTP endpoint
    if tx_id and success:
        time.sleep(0.3)  # Brief wait for transaction to be indexed
        computation = get_transaction_computation(tx_id)

    tx_result = TransactionResult(
        success=success,
        computation=computation,
        tx_id=tx_id,
        output=result.stdout,
        error=result.stderr
    )

    if not quiet:
        if computation is not None:
            print(f"    → Computation: {computation} CUs")
        elif success:
            print(f"    → Success (TX: {tx_id[:8] if tx_id else 'N/A'}...)")
        else:
            # Check for specific error types
            is_cu_limit = ("computation limit" in combined_output.lower() or
                           "out of computation" in combined_output.lower())
            is_memory_limit = "memory limit" in combined_output.lower()

            if is_cu_limit:
                print(f"    → FAILED: Computation limit exceeded!")
            elif is_memory_limit:
                print(f"    → FAILED: Memory limit exceeded!")
            else:
                # Find and print the actual error message
                err_lines = [ln.strip() for ln in combined_output.split('\n')
                             if 'error' in ln.lower() or 'panic' in ln.lower()]
                if err_lines:
                    print(f"    → FAILED: {err_lines[0][:150]}")
                    # Print additional error context if available
                    if len(err_lines) > 1:
                        print(f"             {err_lines[1][:150]}")
                else:
                    # No specific error found - print more output
                    print(f"    → FAILED (exit code {result.returncode})")
                    # Print the last few lines of output for context
                    lines = [l.strip()
                             for l in combined_output.split('\n') if l.strip()]
                    for line in lines[-5:]:
                        print(f"       {line[:120]}")

    return tx_result


def run_script(script_path: str, args: List[str] = None) -> dict:
    """Execute a Flow script and return the result."""
    cmd = ["flow", "scripts", "execute", script_path]
    if args:
        cmd.extend([str(a) for a in args])

    result = run_command(cmd)

    return {
        "success": result.returncode == 0,
        "output": result.stdout,
        "error": result.stderr
    }


def get_draw_status(pool_id: int) -> dict:
    """Get the draw status for a pool."""
    result = run_script(f"{SCRIPT_PATH}/get_draw_status.cdc", [str(pool_id)])

    if not result["success"]:
        return {"error": result["error"]}

    output = result["output"]
    status = {}

    if '"canDrawNow": true' in output:
        status["canDrawNow"] = True
    elif '"canDrawNow": false' in output:
        status["canDrawNow"] = False

    if '"isBatchComplete": true' in output:
        status["isBatchComplete"] = True
    elif '"isBatchComplete": false' in output:
        status["isBatchComplete"] = False

    match = re.search(r'"timeUntilNextDraw":\s*([\d.]+)', output)
    if match:
        status["timeUntilNextDraw"] = float(match.group(1))

    return status


def wait_for_draw_ready(pool_id: int, timeout: int = DRAW_WAIT_TIMEOUT) -> bool:
    """Wait until canDrawNow returns true."""
    print(f"\n--- Waiting for draw to be ready (timeout: {timeout}s) ---")
    print(f"    Pool has 60s draw interval. Please wait...")

    start_time = time.time()
    last_status_time = 0
    last_time_until = None

    while time.time() - start_time < timeout:
        status = get_draw_status(pool_id)

        if status.get("canDrawNow"):
            elapsed = time.time() - start_time
            print(f"  ✓ Draw ready after {elapsed:.1f}s")
            return True

        elapsed = time.time() - start_time
        if elapsed - last_status_time >= 5:
            time_until = status.get("timeUntilNextDraw", "?")
            progress = ""
            if last_time_until is not None and time_until != "?":
                if time_until < last_time_until:
                    progress = " ↓"
                elif time_until == last_time_until:
                    progress = " (not advancing!)"

            print(f"  Waiting... ({elapsed:.0f}s real, "
                  f"~{time_until}s blockchain time){progress}")
            last_status_time = elapsed
            last_time_until = time_until if time_until != "?" else last_time_until

        time.sleep(1)

    print(f"  ✗ Timeout after {timeout}s")
    return False


def is_batch_complete(pool_id: int) -> bool:
    """Check if batch processing is complete."""
    status = get_draw_status(pool_id)
    return status.get("isBatchComplete", False)


def batch_deposit(pool_id: int, amount: float, count: int,
                  quiet: bool = False) -> TransactionResult:
    """
    Make multiple deposits in a single transaction.
    This is much faster than individual deposits for large user counts.
    """
    if not quiet:
        print(f"  Batch depositing {count} positions of {amount} FLOW...")

    result = run_transaction(
        f"{TX_PATH}/batch_deposit_to_pool.cdc",
        [str(pool_id), str(amount), str(count)],
        quiet=quiet
    )

    if not quiet:
        if result.success:
            print(f"    → Created {count} positions in one transaction")
        else:
            print(f"    → Batch deposit failed!")

    return result


def run_batch_test(pool_id: int, batch_size: int,
                   quiet: bool = False) -> TransactionResult:
    """
    Run a batch processing transaction to measure CUs.

    Note: This CONSUMES receivers, so make sure you have enough users
    in the pool to run multiple tests.

    Returns the transaction result with computation measured.
    """
    if not quiet:
        print(f"  Testing batch: {batch_size} receivers...")

    result = run_transaction(
        f"{TX_PATH}/process_draw_batch.cdc",
        [str(pool_id), str(batch_size)],
        quiet=quiet
    )

    return result


# ============================================================================
# BENCHMARK FUNCTIONS
# ============================================================================

def deploy_contracts() -> bool:
    """Deploy all contracts to the emulator."""
    print("\n=== Deploying Contracts ===")
    result = run_command(["flow", "project", "deploy", "--update"])

    if result.returncode != 0:
        print(f"Deployment failed: {result.stderr}")
        return False

    print("✓ Contracts deployed successfully")
    return True


def print_benchmark_summary(results: List[BenchmarkResult]):
    """Print a summary table of benchmark results."""

    print("\n" + "=" * 90)
    print("BENCHMARK SUMMARY")
    print("=" * 90)

    print(f"\n{'Users':<8} {'Batch':<8} {'AvgDeposit':<12} {'StartDraw':<12} "
          f"{'TotalBatch':<12} {'PerUser':<10} {'Complete':<12} {'TotalDraw':<12}")
    print("-" * 90)

    for r in results:
        print(f"{r.user_count:<8} {r.batch_size:<8} {r.avg_deposit_cu:<12.0f} "
              f"{r.start_draw_cu:<12} {r.total_batch_cu:<12} "
              f"{r.per_user_batch_cu:<10.1f} {r.complete_draw_cu:<12} "
              f"{r.total_draw_cu:<12}")

    print("\n" + "=" * 90)
    print("KEY INSIGHTS")
    print("=" * 90)

    if len(results) > 1:
        base = results[0]
        for r in results[1:]:
            if base.user_count > 0 and r.user_count > 0 and base.total_batch_cu > 0:
                user_scale = r.user_count / base.user_count
                cu_scale = r.total_batch_cu / base.total_batch_cu
                print(f"  {base.user_count} → {r.user_count} users: "
                      f"{user_scale:.1f}x users = {cu_scale:.1f}x batch CUs")

    valid_results = [r for r in results if r.per_user_batch_cu > 0]
    if valid_results:
        avg_per_user = sum(
            r.per_user_batch_cu for r in valid_results) / len(valid_results)
        max_users = int(9999 / avg_per_user) if avg_per_user > 0 else "N/A"
        print(f"\n  Average per-user batch cost: ~{avg_per_user:.1f} CUs")
        print(f"  Estimated max users per batch transaction: ~{max_users}")
        print(f"  (Based on 9,999 CU limit)")
    else:
        print("\n  No valid computation data collected.")
        print("  Make sure emulator is running with: "
              "flow emulator --block-time 1s --computation-reporting")


# ============================================================================
# QUICK BENCHMARK (Single User)
# ============================================================================

def quick_benchmark_single_user() -> BenchmarkResult:
    """Quick benchmark with a single user (deployer account)."""
    print("\n" + "=" * 60)
    print("QUICK BENCHMARK: Single User (Deployer Account)")
    print("=" * 60)
    print("\nThis benchmark will:")
    print("  1. Create a pool with 60s draw interval")
    print("  2. Deposit 10 FLOW as a single user")
    print("  3. Wait for the round to end (~60s with --block-time 1s)")
    print("  4. Run the full draw and measure computation")

    result = BenchmarkResult(user_count=1, batch_size=100)

    # Step 1: Create pool
    print("\n--- Creating Pool ---")
    pool_result = run_transaction(
        f"{TX_PATH}/create_test_pool_medium_interval.cdc")
    result.create_pool_cu = pool_result.computation or 0
    pool_id = 0

    script_result = run_script(f"{SCRIPT_PATH}/get_pool_count.cdc")
    if script_result["success"]:
        match = re.search(r'Result:\s*(\d+)', script_result["output"])
        if match:
            pool_id = int(match.group(1)) - 1
            print(f"  Pool ID: {pool_id}")

    # Step 2: Setup user collection
    print("\n--- Setting Up User Collection ---")
    setup_result = run_transaction(f"{TX_PATH}/setup_user_collection.cdc")
    result.setup_users_total_cu = setup_result.computation or 0

    # Step 3: Deposit to pool
    print("\n--- Depositing to Pool ---")
    deposit_result = run_transaction(
        f"{TX_PATH}/deposit_to_pool.cdc",
        [str(pool_id), str(DEFAULT_DEPOSIT_AMOUNT)]
    )
    if deposit_result.computation:
        result.deposit_cus.append(deposit_result.computation)

    # Step 4: Fund lottery pool
    print("\n--- Funding Lottery Pool ---")
    fund_result = run_transaction(
        f"{TX_PATH}/fund_lottery_pool.cdc",
        [str(pool_id), str(DEFAULT_PRIZE_AMOUNT)]
    )
    result.fund_lottery_cu = fund_result.computation or 0

    # Step 5: Wait for draw to be ready
    if not wait_for_draw_ready(pool_id):
        print("\n⚠️  Draw not ready - benchmark may fail")

    # Step 6: Start draw
    print("\n--- Starting Draw ---")
    start_result = run_transaction(f"{TX_PATH}/start_draw.cdc", [str(pool_id)])
    result.start_draw_cu = start_result.computation or 0

    if not start_result.success:
        print("  ⚠️  startDraw failed!")
        return result

    # Step 7: Process batch
    print("\n--- Processing Draw Batch ---")
    batch_result = run_transaction(
        f"{TX_PATH}/process_draw_batch.cdc",
        [str(pool_id), "100"]
    )
    if batch_result.computation:
        result.batch_cus.append(batch_result.computation)

    # Step 8: Request randomness
    print("\n--- Requesting Randomness ---")
    random_result = run_transaction(
        f"{TX_PATH}/request_draw_randomness.cdc",
        [str(pool_id)]
    )
    result.request_randomness_cu = random_result.computation or 0

    # Step 9: Wait and complete
    print("\n--- Waiting for randomness block ---")
    time.sleep(3)

    print("\n--- Completing Draw ---")
    complete_result = run_transaction(
        f"{TX_PATH}/complete_draw.cdc", [str(pool_id)])
    result.complete_draw_cu = complete_result.computation or 0

    if complete_result.success:
        print("\n✓ Draw completed successfully!")
    else:
        print("\n⚠️  completeDraw failed - randomness may not be available yet")

    return result


# ============================================================================
# MULTI-USER BENCHMARK
# ============================================================================

def run_multi_user_benchmark(user_count: int, batch_size: int) -> BenchmarkResult:
    """Benchmark with multiple users."""
    print(f"\n{'=' * 60}")
    print(f"MULTI-USER BENCHMARK: {user_count} users, batch size {batch_size}")
    print(f"{'=' * 60}")

    result = BenchmarkResult(user_count=user_count, batch_size=batch_size)

    # Step 1: Create pool
    print("\n--- Creating Pool (60s draw interval) ---")
    pool_result = run_transaction(
        f"{TX_PATH}/create_test_pool_medium_interval.cdc")
    result.create_pool_cu = pool_result.computation or 0

    pool_id = 0
    script_result = run_script(f"{SCRIPT_PATH}/get_pool_count.cdc")
    if script_result["success"]:
        match = re.search(r'Result:\s*(\d+)', script_result["output"])
        if match:
            pool_id = int(match.group(1)) - 1
            print(f"  Pool ID: {pool_id}")

    # Step 2: Setup deployer's collection
    print("\n--- Setting Up Deployer Collection ---")
    setup_result = run_transaction(f"{TX_PATH}/setup_user_collection.cdc")
    result.setup_users_total_cu = setup_result.computation or 0

    # Step 3: Make deposits using batch transaction for speed
    print(f"\n--- Creating {user_count} User Positions ---")

    # Use batch deposits for efficiency (chunks of 50 to stay safe)
    batch_deposit_size = 50
    remaining = user_count
    total_deposit_cu = 0

    while remaining > 0:
        chunk = min(batch_deposit_size, remaining)
        deposit_result = batch_deposit(
            pool_id, DEFAULT_DEPOSIT_AMOUNT, chunk, quiet=(
                remaining != user_count)
        )
        if deposit_result.computation:
            result.deposit_cus.append(deposit_result.computation)
            total_deposit_cu += deposit_result.computation
        remaining -= chunk

    print(f"  ✓ Created {user_count} positions")
    if total_deposit_cu > 0:
        print(f"  Total deposit CU: {total_deposit_cu}")

    # Step 4: Fund lottery pool
    print("\n--- Funding Lottery Pool ---")
    fund_result = run_transaction(
        f"{TX_PATH}/fund_lottery_pool.cdc",
        [str(pool_id), str(DEFAULT_PRIZE_AMOUNT)]
    )
    result.fund_lottery_cu = fund_result.computation or 0

    # Step 5: Wait for draw to be ready
    if not wait_for_draw_ready(pool_id):
        print("\n⚠️  Draw not ready - benchmark may fail")
        return result

    # Step 6: Start draw
    print("\n--- Starting Draw ---")
    start_result = run_transaction(f"{TX_PATH}/start_draw.cdc", [str(pool_id)])
    result.start_draw_cu = start_result.computation or 0

    if not start_result.success:
        print("  ⚠️  startDraw failed!")
        return result

    # Step 7: Process batches
    print("\n--- Processing Draw Batches ---")
    batch_num = 0
    max_batches = (user_count // batch_size) + 10

    while batch_num < max_batches:
        batch_result = run_transaction(
            f"{TX_PATH}/process_draw_batch.cdc",
            [str(pool_id), str(batch_size)]
        )

        if batch_result.computation:
            result.batch_cus.append(batch_result.computation)

        batch_num += 1

        if is_batch_complete(pool_id):
            print(f"  ✓ Batch processing complete after {batch_num} batches")
            break

    # Step 8: Request randomness
    print("\n--- Requesting Randomness ---")
    random_result = run_transaction(
        f"{TX_PATH}/request_draw_randomness.cdc",
        [str(pool_id)]
    )
    result.request_randomness_cu = random_result.computation or 0

    # Step 9: Wait and complete
    print("\n--- Waiting for randomness block ---")
    time.sleep(3)

    print("\n--- Completing Draw ---")
    complete_result = run_transaction(
        f"{TX_PATH}/complete_draw.cdc", [str(pool_id)])
    result.complete_draw_cu = complete_result.computation or 0

    if complete_result.success:
        print("\n✓ Draw completed successfully!")

    return result


# ============================================================================
# FIND BATCH LIMIT (Dry-Run Mode)
# ============================================================================

def find_batch_limit(start_users: int = 100,
                     step: int = 100,
                     max_users: int = 2000) -> dict:
    """
    Find the maximum number of users that can be processed in a single
    batch transaction before hitting the computation limit.

    Uses batch deposits to create receiver positions quickly.
    processDrawBatch iterates through receiver IDs, so multiple positions
    from the same account still get processed individually.

    Returns a dict with the limit info.
    """
    print("\n" + "=" * 70)
    print("FINDING BATCH PROCESSING LIMIT")
    print("=" * 70)
    print(f"\nStrategy: Create receiver positions via batch deposit")
    print(f"Starting at {start_users} users, incrementing by {step}")
    print(f"Maximum to test: {max_users}")
    print(f"CU limit per transaction: 9,999")

    # Step 1: Create pool
    print("\n--- Setting Up Test Environment ---")
    run_transaction(f"{TX_PATH}/create_test_pool_medium_interval.cdc")

    pool_id = 0
    script_result = run_script(f"{SCRIPT_PATH}/get_pool_count.cdc")
    if script_result["success"]:
        match = re.search(r'Result:\s*(\d+)', script_result["output"])
        if match:
            pool_id = int(match.group(1)) - 1
            print(f"  Pool ID: {pool_id}")

    # Setup collection for deployer
    print("  Setting up user collection...")
    setup_result = run_transaction(f"{TX_PATH}/setup_user_collection.cdc")
    if not setup_result.success:
        print("  ⚠️  Collection setup failed - trying to continue anyway")

    # Step 2: Create ACTUAL receiver accounts
    # Each account has its own collection = unique receiver ID
    print(f"\n--- Creating {max_users} Receiver Accounts ---")
    print("  Each account = 1 unique receiver in lottery")

    created = 0
    failed = 0
    for i in range(max_users):
        # Generate a unique public key for each account (128 hex chars for P256)
        key_hex = format(i + 1, '064x') + format(i + 0x1000, '064x')

        result = run_transaction(
            f"{TX_PATH}/create_receiver_account.cdc",
            [str(pool_id), str(DEFAULT_DEPOSIT_AMOUNT), key_hex],
            quiet=True
        )

        if result.success:
            created += 1
        else:
            failed += 1
            if failed == 1:
                print(f"  ⚠️  First failure at account {i+1}")
                combined = (result.output or "") + (result.error or "")
                err = [ln for ln in combined.split('\n')
                       if 'error' in ln.lower()][:2]
                for ln in err:
                    print(f"      {ln.strip()[:100]}")
            if failed > 3:
                print(f"  ⚠️  Too many failures, stopping")
                break

        if (i + 1) % 10 == 0:
            print(f"    Created {created}/{max_users} accounts...")

    print(f"  ✓ Created {created} unique receiver accounts")

    # Verify receiver count
    stats_result = run_script(
        "cadence/scripts/prize-savings/get_pool_stats.cdc",
        [str(pool_id)]
    )
    actual_receivers = created
    if stats_result["success"]:
        match = re.search(r'"registeredUserCount":\s*(\d+)',
                          stats_result["output"])
        if match:
            actual_receivers = int(match.group(1))
    print(f"  → Verified receiver count: {actual_receivers}")

    if created == 0:
        print("\n⚠️  No receivers created")
        return {"error": "Failed to create receivers"}

    # Fund lottery
    run_transaction(
        f"{TX_PATH}/fund_lottery_pool.cdc",
        [str(pool_id), str(DEFAULT_PRIZE_AMOUNT)],
        quiet=True
    )

    # Wait for draw to be ready
    if not wait_for_draw_ready(pool_id):
        print("\n⚠️  Could not start draw - aborting")
        return {"error": "Draw not ready"}

    # Start the draw (this commits - needed for batch processing)
    print("\n--- Starting Draw ---")
    start_result = run_transaction(f"{TX_PATH}/start_draw.cdc", [str(pool_id)])
    if not start_result.success:
        print("  ⚠️  Could not start draw")
        return {"error": "Start draw failed"}

    # Test a few batch sizes to measure per-user cost
    # Note: Each batch CONSUMES receivers, so we test strategically
    print("\n--- Testing Batch Sizes ---")
    print("  Testing a few batch sizes to measure per-user cost")
    print("  Then extrapolating the theoretical maximum")
    print()

    # Check actual receiver count from draw status after startDraw
    status = get_draw_status(pool_id)
    # The receiver count will be determined by actually running a batch

    results = []
    # Test with large batch sizes to measure scaling
    # Will process however many receivers actually exist
    test_sizes = [max_users]  # Use the max_users parameter as batch size

    total_processed = 0

    for batch_size in test_sizes:
        print(f"  Testing batch size: {batch_size}")

        batch_result = run_batch_test(pool_id, batch_size)
        cu = batch_result.computation

        if cu is not None and cu > 0 and batch_result.success:
            pct = (cu / 9999) * 100
            per_user = cu / batch_size

            results.append({
                "batch_size": batch_size,
                "computation": cu,
                "percent": pct,
                "per_user": per_user
            })

            print(f"    → {cu} CUs ({pct:.1f}% of limit, "
                  f"{per_user:.2f} CU/user)")

            # Estimate max batch size
            est_max = int(9999 / per_user) if per_user > 0 else 0
            print(f"    → Estimated max batch: ~{est_max} users")

            total_processed += batch_size

        elif not batch_result.success:
            # Hit a limit or error - show full details
            print(f"    → FAILED at {batch_size} users")
            combined = (batch_result.output or "") + (batch_result.error or "")

            # Check for specific errors
            if "computation" in combined.lower() and "limit" in combined.lower():
                print(f"    → Hit computation limit!")
            elif "batch processing already complete" in combined.lower():
                print(f"    → Batch was already complete!")
                # This means all users were processed in previous batch
                break
            elif "no draw in progress" in combined.lower():
                print(f"    → No draw in progress - may need to restart")
            else:
                # Show the actual error
                error_lines = [ln for ln in combined.split('\n')
                               if 'error' in ln.lower() or 'panic' in ln.lower()
                               or 'failed' in ln.lower()]
                if len(error_lines) > 2:
                    print(
                        f"    → Error: {error_lines[2][:200] if len(error_lines) > 2 else 'Unknown'}")
            break
        else:
            print(f"    → Could not measure CU (got: {cu})")

    # Check if batch is complete and process remaining if needed
    if not is_batch_complete(pool_id):
        print(f"\n  Processing remaining receivers...")
        while not is_batch_complete(pool_id):
            batch_result = run_transaction(
                f"{TX_PATH}/process_draw_batch.cdc",
                [str(pool_id), "500"],
                quiet=True
            )
            if not batch_result.success:
                break

    # Print summary
    print("\n" + "=" * 70)
    print("BATCH LIMIT RESULTS")
    print("=" * 70)

    if results:
        # Calculate average per-user cost from all tests
        avg_per_user = sum(r["per_user"] for r in results) / len(results)
        theoretical_max = int(9999 / avg_per_user) if avg_per_user > 0 else 0
        safe_max = int(theoretical_max * 0.9)  # 90% safety margin

        print("\n  Test Results:")
        for r in results:
            print(f"    {r['batch_size']:>5} users: {r['computation']:>5} CUs "
                  f"({r['per_user']:.2f} CU/user)")

        print(f"\n  Average per-user cost: {avg_per_user:.2f} CUs")
        print(f"\n  Theoretical maximum: ~{theoretical_max} users per batch")
        print(f"  Recommended safe limit: ~{safe_max} users per batch")
        print(f"  (with 10% safety margin)")
        print(f"\n  CU Limit: 9,999 per transaction")

        return {
            "avg_per_user_cu": avg_per_user,
            "theoretical_max": theoretical_max,
            "recommended_max": safe_max,
            "results": results
        }
    else:
        print("\n  No successful batch tests - check setup")
        return {"error": "No successful batches"}


# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Benchmark PrizeSavings computation costs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 benchmark_computation.py --quick           # Single user benchmark
  python3 benchmark_computation.py --users 100       # 100 users (batch deposits)
  python3 benchmark_computation.py --scale           # 1, 5, 10, 25, 50 users
  python3 benchmark_computation.py --find-limit      # Find max batch size
  python3 benchmark_computation.py --find-limit --limit-max 3000  # Test up to 3000

Before running, start the emulator with:
  flow emulator --block-time 1s --computation-reporting
        """
    )
    parser.add_argument("--users", type=int, default=1,
                        help="Number of users to simulate (default: 1)")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE,
                        help="Batch size for processDrawBatch (default: 100)")
    parser.add_argument("--scale", action="store_true",
                        help="Run scaling test with multiple user counts")
    parser.add_argument("--quick", action="store_true",
                        help="Quick single-user benchmark using deployer account")
    parser.add_argument("--find-limit", action="store_true",
                        help="Find the maximum batch size before hitting CU limit")
    parser.add_argument("--simple", type=int, nargs='?', const=5, default=None,
                        help="Simple N-receiver test (default: 5 receivers)")
    parser.add_argument("--limit-start", type=int, default=100,
                        help="Starting batch size for --find-limit (default: 100)")
    parser.add_argument("--limit-step", type=int, default=100,
                        help="Step size for --find-limit (default: 100)")
    parser.add_argument("--limit-max", type=int, default=200,
                        help="Max users for --find-limit (default: 200, each is a new account)")
    parser.add_argument("--skip-deploy", action="store_true",
                        help="Skip contract deployment (if already deployed)")

    args = parser.parse_args()

    print("=" * 60)
    print("Flow PrizeSavings Computation Benchmark")
    print("=" * 60)
    print(f"Started at: {datetime.now().isoformat()}")
    print("\n⚠️  IMPORTANT: Start the emulator with these flags:")
    print("   flow emulator --block-time 1s --computation-reporting")
    print()
    print("   Computation data is fetched via HTTP from:")
    print(f"   {EMULATOR_ADMIN_URL}/emulator/computationReport")
    print()

    # Test HTTP endpoint connectivity
    try:
        report = get_computation_report()
        if report is not None:
            print("   ✓ Emulator computation reporting endpoint is accessible")
    except Exception:
        print("   ⚠️  Could not connect to emulator - is it running?")

    # Deploy contracts
    if not args.skip_deploy:
        if not deploy_contracts():
            print("Failed to deploy contracts. Exiting.")
            sys.exit(1)

    results = []

    if args.simple is not None:
        # Simple N-receiver test
        simple_two_receiver_test(num_accounts=args.simple)
        print(f"\nCompleted at: {datetime.now().isoformat()}")
        return

    elif args.find_limit:
        # Find the maximum batch size
        find_batch_limit(
            start_users=args.limit_start,
            step=args.limit_step,
            max_users=args.limit_max
        )
        print(f"\nCompleted at: {datetime.now().isoformat()}")
        return  # find_batch_limit prints its own summary

    elif args.quick:
        result = quick_benchmark_single_user()
        results.append(result)

    elif args.scale:
        user_counts = [1, 5, 10, 25, 50]
        print(f"\nRunning scaling test with user counts: {user_counts}")
        for count in user_counts:
            result = run_multi_user_benchmark(count, args.batch_size)
            results.append(result)

    else:
        if args.users == 1:
            result = quick_benchmark_single_user()
        else:
            result = run_multi_user_benchmark(args.users, args.batch_size)
        results.append(result)

    print_benchmark_summary(results)
    print(f"\nCompleted at: {datetime.now().isoformat()}")


def simple_two_receiver_test(num_accounts: int = 5):
    """
    Simple test with multiple receivers to verify batch processing works.
    Uses Flow CLI to create additional accounts.
    """
    print("\n" + "=" * 60)
    print(f"SIMPLE {num_accounts}-RECEIVER TEST")
    print("=" * 60)

    # Step 1: Create pool
    print("\n--- Step 1: Create Pool ---")
    pool_result = run_transaction(
        f"{TX_PATH}/create_test_pool_medium_interval.cdc")
    if not pool_result.success:
        print("  ✗ Failed to create pool")
        return

    pool_id = 0
    script_result = run_script(f"{SCRIPT_PATH}/get_pool_count.cdc")
    if script_result["success"]:
        match = re.search(r'Result:\s*(\d+)', script_result["output"])
        if match:
            pool_id = int(match.group(1)) - 1
    print(f"  Pool ID: {pool_id}")

    # Step 2: Setup deployer as receiver 1
    print("\n--- Step 2: Setup Deployer as Receiver 1 ---")
    setup_result = run_transaction(f"{TX_PATH}/setup_user_collection.cdc")
    if not setup_result.success:
        print("  ✗ Failed to setup collection")
        return

    deposit_result = run_transaction(
        f"{TX_PATH}/deposit_to_pool.cdc",
        [str(pool_id), "10.0"]
    )
    if not deposit_result.success:
        print("  ✗ Failed to deposit")
        return
    print("  ✓ Deployer registered as receiver 1")

    # Step 3: Create additional receiver accounts
    # Use create_receiver_account.cdc which creates account + collection + deposit
    additional_accounts = num_accounts - 1
    print(
        f"\n--- Step 3: Create {additional_accounts} More Receiver Accounts ---")

    receivers_created = 1  # deployer is already receiver 1

    for i in range(additional_accounts):
        # Generate a valid key pair
        keygen_result = run_command(["flow", "keys", "generate"])
        if keygen_result.returncode != 0:
            print(f"  ✗ Failed to generate key {i+1}")
            continue

        pub_key_match = re.search(
            r'Public Key\s+([a-fA-F0-9]+)',
            keygen_result.stdout
        )
        if not pub_key_match:
            print(f"  ✗ Could not parse public key {i+1}")
            continue

        pub_key = pub_key_match.group(1)

        # Create receiver account (creates account + collection + deposits)
        result = run_transaction(
            f"{TX_PATH}/create_receiver_account.cdc",
            [str(pool_id), "10.0", pub_key],
            quiet=True
        )

        if result.success:
            receivers_created += 1
            print(f"  ✓ Created receiver {receivers_created}")
        else:
            print(f"  ✗ Failed to create receiver {i+2}")
            # Show error for first failure
            if receivers_created == 1:
                combined = (result.output or "") + (result.error or "")
                err = [ln for ln in combined.split('\n')
                       if 'error' in ln.lower()][:2]
                for ln in err:
                    print(f"      {ln.strip()[:100]}")

    print(f"  Total receivers: {receivers_created}")

    # Step 5: Check receiver count
    print("\n--- Step 5: Check Receiver Count ---")
    stats = run_script(
        "cadence/scripts/prize-savings/get_pool_stats.cdc",
        [str(pool_id)]
    )
    if stats["success"]:
        match = re.search(r'"registeredUserCount":\s*(\d+)', stats["output"])
        if match:
            print(f"  Receiver count: {match.group(1)}")
        else:
            print(f"  Stats output: {stats['output'][:300]}")

    # Step 6: Fund lottery
    print("\n--- Step 6: Fund Lottery ---")
    fund_lottery = run_transaction(
        f"{TX_PATH}/fund_lottery_pool.cdc",
        [str(pool_id), "100.0"]
    )

    # Step 7: Wait for draw
    print("\n--- Step 7: Wait for Draw ---")
    if not wait_for_draw_ready(pool_id):
        print("  ✗ Draw not ready")
        return

    # Step 8: Start draw
    print("\n--- Step 8: Start Draw ---")
    start_result = run_transaction(
        f"{TX_PATH}/start_draw.cdc",
        [str(pool_id)]
    )
    if not start_result.success:
        print("  ✗ Failed to start draw")
        return

    # Step 9: Process batch - THE KEY MEASUREMENT
    print("\n--- Step 9: Process Batch (KEY MEASUREMENT) ---")
    batch_result = run_transaction(
        f"{TX_PATH}/process_draw_batch.cdc",
        [str(pool_id), "100"]
    )

    print("\n" + "=" * 60)
    print("RESULT")
    print("=" * 60)
    if batch_result.computation:
        print(
            f"  Batch processing computation: {batch_result.computation} CUs")
    else:
        print("  Could not measure computation")
        print(f"  TX success: {batch_result.success}")
        print(f"  TX ID: {batch_result.tx_id}")


if __name__ == "__main__":
    main()
