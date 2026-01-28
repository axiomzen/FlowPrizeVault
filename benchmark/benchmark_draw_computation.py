#!/usr/bin/env python3
"""
PrizeLinkedAccounts Draw Computation Benchmark

Measures computation units (CUs) consumed by each phase of the lottery draw process
to determine optimal batch sizes for the Flow blockchain's 9,999 CU transaction limit.

Usage:
    # Basic benchmark (computation reporting only)
    python3 benchmark/benchmark_draw_computation.py --users 100 --batch-size 100

    # With computation profiling (saves pprof files for analysis)
    python3 benchmark/benchmark_draw_computation.py --users 500 --batch-size 500 --profile

    # Multiple runs for variability analysis
    python3 benchmark/benchmark_draw_computation.py --users 1000 --batch-size 1000 --runs 3 --profile

    # Analyze an existing profile
    python3 benchmark/benchmark_draw_computation.py --analyze-profile benchmark/profiles/profile.pprof

Output:
    - Terminal summary with computation per phase
    - benchmark/results/benchmark_results.csv
    - benchmark/results/benchmark_results.json
    - benchmark/profiles/*.pprof (if --profile enabled)

Prerequisites:
    - Flow CLI installed
    - No emulator running (script will start its own)
    - go tool pprof (for profile analysis)

Session 2 Updates:
    - Improved Flow CLI output parsing (JSON mode)
    - Better error handling and logging
    - Fixed draw status parsing
    - Added computation extraction from transaction results

Session 4 Updates:
    - Added --profile flag for computation profiling
    - Added --analyze-profile for analyzing pprof files
    - Added --runs for variability testing
    - Profile download and storage to benchmark/profiles/
"""

import subprocess
import json
import time
import sys
import os
import signal
import argparse
import csv
from dataclasses import dataclass, asdict
from typing import Optional, Tuple, List, Dict, Any, Union
from pathlib import Path
from datetime import datetime

# ============================================================
# CONFIGURATION
# ============================================================

NETWORK = "emulator"
ADMIN_ACCOUNT = "emulator-account"
FLOW_FLAGS = ["--skip-version-check"]
COMPUTE_LIMIT = 9999  # Max computation units per transaction
EMULATOR_PORT = 8080
EMULATOR_GRPC_PORT = 3569

# Paths
PROJECT_ROOT = Path(__file__).parent.parent
RESULTS_DIR = PROJECT_ROOT / "benchmark" / "results"
PROFILES_DIR = PROJECT_ROOT / "benchmark" / "profiles"
FLOW_JSON_PATH = PROJECT_ROOT / "flow.json"

# Transaction paths
TX_SETUP_YIELD_VAULT = "cadence/transactions/prize-linked-accounts/setup_test_yield_vault.cdc"
TX_SETUP_COLLECTION = "cadence/transactions/prize-linked-accounts/setup_collection.cdc"
TX_CREATE_POOL = "cadence/transactions/prize-linked-accounts/create_test_pool.cdc"
TX_CREATE_MULTI_WINNER_POOL = "cadence/transactions/test/create_multi_winner_pool.cdc"
TX_FUND_LOTTERY = "cadence/transactions/test/fund_lottery_pool.cdc"
TX_DEPOSIT = "cadence/transactions/prize-linked-accounts/deposit.cdc"
TX_START_DRAW = "cadence/transactions/prize-linked-accounts/start_draw.cdc"
TX_PROCESS_BATCH = "cadence/transactions/test/process_draw_batch.cdc"
TX_REQUEST_RANDOMNESS = "cadence/transactions/test/request_draw_randomness.cdc"
TX_COMPLETE_DRAW = "cadence/transactions/prize-linked-accounts/complete_draw.cdc"

# ============================================================
# TERMINAL COLORS
# ============================================================

class Colors:
    GREEN = '\033[0;32m'
    BLUE = '\033[0;34m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    CYAN = '\033[0;36m'
    BOLD = '\033[1m'
    NC = '\033[0m'  # No Color

def print_header(msg: str):
    print(f"\n{Colors.BLUE}{'═' * 70}{Colors.NC}")
    print(f"{Colors.BLUE}  {msg}{Colors.NC}")
    print(f"{Colors.BLUE}{'═' * 70}{Colors.NC}")

def print_step(msg: str):
    print(f"\n{Colors.YELLOW}▶ {msg}{Colors.NC}")

def print_success(msg: str):
    print(f"{Colors.GREEN}✓ {msg}{Colors.NC}")

def print_error(msg: str):
    print(f"{Colors.RED}✗ {msg}{Colors.NC}")

def print_info(msg: str):
    print(f"  {msg}")

def print_metric(label: str, value: Any, unit: str = ""):
    print(f"  {Colors.CYAN}{label}:{Colors.NC} {value} {unit}")

# ============================================================
# DATA STRUCTURES
# ============================================================

@dataclass
class ComputationResult:
    """Result from a single transaction execution"""
    tx_name: str
    success: bool
    computation: int
    memory: int
    tx_id: str
    error: Optional[str] = None

@dataclass
class PhaseResult:
    """Aggregated result for a draw phase"""
    phase_name: str
    total_computation: int
    total_memory: int
    tx_count: int
    avg_computation_per_tx: float
    items_processed: int = 0
    computation_per_item: float = 0.0

@dataclass
class BenchmarkRun:
    """Complete benchmark run results"""
    timestamp: str
    user_count: int
    batch_size: int
    phases: List[PhaseResult]
    total_computation: int
    total_memory: int
    total_tx_count: int

# ============================================================
# EMULATOR MANAGEMENT
# ============================================================

emulator_process: Optional[subprocess.Popen] = None

def kill_existing_emulator():
    """Kill any existing Flow emulator process"""
    print_step("Killing any existing emulator...")

    # Try to kill by port
    subprocess.run(["pkill", "-f", "flow emulator"], capture_output=True)

    # Also try lsof approach
    result = subprocess.run(
        ["lsof", "-ti", f":{EMULATOR_PORT}"],
        capture_output=True,
        text=True
    )
    if result.stdout.strip():
        for pid in result.stdout.strip().split('\n'):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ValueError, ProcessLookupError):
                pass

    # Wait for port to be free
    time.sleep(2)
    print_success("Existing emulator killed")

def start_emulator_with_profiling(enable_profiling: bool = False) -> bool:
    """
    Start Flow emulator with computation reporting enabled.

    Args:
        enable_profiling: If True, also enable --computation-profiling for pprof output
    """
    global emulator_process

    profile_mode = "profiling" if enable_profiling else "reporting"
    print_step(f"Starting emulator with computation {profile_mode}...")

    # Change to project root for emulator to find flow.json
    os.chdir(PROJECT_ROOT)

    cmd = [
        "flow", "emulator",
        "--block-time", "1s",
        "--computation-reporting",
        "--verbose=false"
    ]

    if enable_profiling:
        cmd.append("--computation-profiling")
        print_info("Computation profiling enabled - pprof profiles will be available")

    try:
        emulator_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        # Wait for emulator to be ready
        max_attempts = 30
        for i in range(max_attempts):
            time.sleep(1)
            if check_emulator_health():
                print_success(f"Emulator started (PID: {emulator_process.pid})")
                return True
            if i % 5 == 4:
                print_info(f"Waiting for emulator... ({i+1}/{max_attempts})")

        print_error("Emulator failed to start within timeout")
        return False

    except Exception as e:
        print_error(f"Failed to start emulator: {e}")
        return False

def check_emulator_health() -> bool:
    """Check if emulator is running and healthy"""
    try:
        # Use flow CLI to check if emulator is responsive
        result = subprocess.run(
            ["flow", "accounts", "get", "f8d6e0586b0a20c7", "--network", "emulator"],
            capture_output=True,
            text=True,
            timeout=10
        )
        return result.returncode == 0
    except:
        return False

def stop_emulator():
    """Stop the emulator process"""
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

def reset_computation_profile():
    """
    Reset the computation profiler to get fresh measurements.

    NOTE: The emulator's reset API has a bug that causes nil pointer panic
    in some versions. We disable this and instead use transaction ID matching
    from the computation report.
    """
    # Disabled due to emulator bug - see WORK_LOG.md Session 4
    # The reset API causes: "runtime error: invalid memory address or nil pointer dereference"
    # try:
    #     subprocess.run(
    #         ["curl", "-s", "-X", "PUT",
    #          f"http://localhost:{EMULATOR_PORT}/emulator/computationProfile/reset"],
    #         capture_output=True,
    #         timeout=5
    #     )
    # except:
    #     pass
    pass


def download_computation_profile(output_path: Path) -> bool:
    """
    Download the pprof computation profile from the emulator.

    Args:
        output_path: Path where the .pprof file will be saved

    Returns:
        True if successful, False otherwise
    """
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)

        result = subprocess.run(
            ["curl", "-s", "-o", str(output_path),
             f"http://localhost:{EMULATOR_PORT}/emulator/computationProfile"],
            capture_output=True,
            timeout=30
        )

        if result.returncode == 0 and output_path.exists():
            size = output_path.stat().st_size
            if size > 100:  # Valid pprof files are at least 100 bytes
                print_success(f"Profile saved to {output_path} ({size} bytes)")
                return True
            else:
                print_error(f"Profile file too small ({size} bytes) - may be empty")
                return False
        else:
            print_error(f"Failed to download profile: curl returned {result.returncode}")
            return False
    except Exception as e:
        print_error(f"Failed to download profile: {e}")
        return False


def analyze_profile(profile_path: Path, top_n: int = 20) -> Optional[str]:
    """
    Analyze a pprof profile and return top functions by computation.

    Args:
        profile_path: Path to the .pprof file
        top_n: Number of top functions to show

    Returns:
        Analysis output string, or None if failed
    """
    if not profile_path.exists():
        print_error(f"Profile not found: {profile_path}")
        return None

    try:
        result = subprocess.run(
            ["go", "tool", "pprof", "-top", f"-nodecount={top_n}", str(profile_path)],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode == 0:
            return result.stdout
        else:
            print_error(f"pprof analysis failed: {result.stderr}")
            return None
    except FileNotFoundError:
        print_error("go tool pprof not found. Make sure Go is installed.")
        return None
    except Exception as e:
        print_error(f"Profile analysis failed: {e}")
        return None


def print_profile_analysis(analysis: str, title: str = "Computation Profile Analysis"):
    """Pretty-print the profile analysis results"""
    print_header(title)

    lines = analysis.strip().split('\n')
    in_data = False

    for line in lines:
        if 'flat' in line.lower() and 'cum' in line.lower():
            # Header line
            print(f"\n{Colors.CYAN}{line}{Colors.NC}")
            in_data = True
        elif in_data and line.strip():
            # Data lines - highlight high percentages
            if '%' in line:
                parts = line.split()
                if parts:
                    try:
                        # First percentage is flat %
                        pct = float(parts[1].replace('%', ''))
                        if pct > 20:
                            print(f"{Colors.RED}{line}{Colors.NC}")
                        elif pct > 10:
                            print(f"{Colors.YELLOW}{line}{Colors.NC}")
                        else:
                            print(f"  {line}")
                    except (ValueError, IndexError):
                        print(f"  {line}")
                else:
                    print(f"  {line}")
            else:
                print(f"  {line}")
        else:
            print(f"  {line}")

def get_computation_report() -> Dict[str, Any]:
    """Fetch the computation report from the emulator"""
    try:
        result = subprocess.run(
            ["curl", "-s", f"http://localhost:{EMULATOR_PORT}/emulator/computationReport"],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0 and result.stdout:
            return json.loads(result.stdout)
    except Exception as e:
        print_error(f"Failed to get computation report: {e}")
    return {}

# ============================================================
# FLOW CLI HELPERS
# ============================================================

def run_command(cmd: List[str], timeout: int = 120) -> Tuple[int, str, str]:
    """Run a command and return (returncode, stdout, stderr)"""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=PROJECT_ROOT
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)

def run_flow_tx(
    tx_path: str,
    *args,
    signer: str = ADMIN_ACCOUNT,
    compute_limit: int = COMPUTE_LIMIT
) -> Tuple[bool, str, Optional[str], int]:
    """
    Run a Flow transaction and return (success, output, tx_id, computation)
    Uses JSON output mode for reliable parsing.
    """
    cmd = [
        "flow", "transactions", "send", tx_path
    ] + list(args) + [
        "--signer", signer,
        "--network", NETWORK,
        "--compute-limit", str(compute_limit),
        "--output", "json"
    ] + FLOW_FLAGS

    code, stdout, stderr = run_command(cmd)

    # Try to parse JSON output
    tx_id = None
    computation = 0

    try:
        result = json.loads(stdout)
        tx_id = result.get('id', result.get('transactionId'))
        # Extract computation from the transaction result
        computation = result.get('computationUsed', 0)
        if not computation:
            # Try alternative field names
            computation = result.get('gasUsed', 0)
        success = result.get('status') == 'SEALED' or result.get('statusString') == 'SEALED'
        if not success:
            # Check if there was an error
            error = result.get('error', result.get('errorMessage', ''))
            if error:
                return False, str(error), tx_id, computation
    except json.JSONDecodeError:
        # Fallback to text parsing
        output = stdout + stderr
        for line in output.split('\n'):
            if 'ID' in line and '0x' in line:
                parts = line.split()
                for part in parts:
                    if part.startswith('0x') or len(part) == 64:
                        tx_id = part
                        break
            # Try to extract computation from text output
            if 'computation' in line.lower():
                import re
                match = re.search(r'computation[:\s]+(\d+)', line, re.IGNORECASE)
                if match:
                    computation = int(match.group(1))
        success = code == 0 and 'error' not in output.lower() and 'panic' not in output.lower()
        return success, stdout + stderr, tx_id, computation

    return True, stdout, tx_id, computation

def run_flow_script(script_path: str, *args, output_json: bool = False) -> Tuple[bool, Any]:
    """Run a Flow script. Returns (success, result) where result is parsed JSON if output_json=True."""
    cmd = [
        "flow", "scripts", "execute", script_path
    ] + list(args) + [
        "--network", NETWORK
    ] + FLOW_FLAGS

    if output_json:
        cmd.append("--output")
        cmd.append("json")

    code, stdout, stderr = run_command(cmd)

    if output_json:
        try:
            result = json.loads(stdout)
            return True, result
        except json.JSONDecodeError:
            return False, stdout + stderr
    else:
        output = stdout + stderr
        success = code == 0 and 'error' not in output.lower() and 'panic' not in output.lower()
        return success, output

def create_account() -> Optional[str]:
    """Create a new account on the emulator and return its address"""
    cmd = [
        "flow", "accounts", "create",
        "--network", NETWORK
    ] + FLOW_FLAGS

    code, stdout, stderr = run_command(cmd)
    output = stdout + stderr

    # Extract address from output
    for line in output.split('\n'):
        if 'Address' in line and '0x' in line:
            parts = line.split()
            for part in parts:
                if part.startswith('0x'):
                    return part
    return None

def fund_account(address: str, amount: str = "1000.0") -> bool:
    """Fund an account with FLOW tokens from the service account"""
    # Use flow CLI to transfer tokens
    cmd = [
        "flow", "transactions", "send",
        "cadence/transactions/test/fund_account.cdc" if Path(PROJECT_ROOT / "cadence/transactions/test/fund_account.cdc").exists()
        else "--code",
        address, amount,
        "--signer", ADMIN_ACCOUNT,
        "--network", NETWORK
    ] + FLOW_FLAGS

    # If fund_account.cdc doesn't exist, we need inline Cadence
    # For now, let's create a simple funding mechanism
    code, stdout, stderr = run_command(cmd)
    return code == 0

# ============================================================
# CONTRACT DEPLOYMENT
# ============================================================

def deploy_contracts() -> bool:
    """Deploy all contracts to the emulator"""
    print_step("Installing dependencies...")
    run_command(["flow", "dependencies", "install"] + FLOW_FLAGS)

    print_step("Deploying contracts...")
    code, stdout, stderr = run_command(
        ["flow", "project", "deploy", f"--network={NETWORK}", "--update"] + FLOW_FLAGS,
        timeout=180
    )
    output = stdout + stderr

    if 'error' in output.lower() and 'already' not in output.lower():
        print_error(f"Contract deployment failed")
        print_info(output[:500])
        return False

    print_success("Contracts deployed")
    return True

# ============================================================
# POOL SETUP
# ============================================================

def setup_pool(winner_count: int = 1) -> Optional[int]:
    """Setup yield vault and create a test pool, return pool ID

    Args:
        winner_count: Number of winners per draw (default 1 for single winner)
    """
    print_step("Setting up test yield vault...")
    success, output, _, _ = run_flow_tx(TX_SETUP_YIELD_VAULT)
    if not success and 'already' not in str(output).lower():
        print_error("Failed to setup yield vault")
        print_info(str(output)[:300])
        return None

    print_step("Setting up admin collection...")
    success, output, _, _ = run_flow_tx(TX_SETUP_COLLECTION)
    if not success and 'already' not in str(output).lower():
        print_error("Failed to setup admin collection")
        print_info(str(output)[:300])
        return None

    if winner_count > 1:
        print_step(f"Creating multi-winner pool ({winner_count} winners)...")
        # Parameters: minDeposit, drawInterval, savingsPercent, lotteryPercent, treasuryPercent, winnerCount
        success, output, _, _ = run_flow_tx(
            TX_CREATE_MULTI_WINNER_POOL,
            "1.0",   # minDeposit
            "1.0",   # drawInterval (1 second for fast testing)
            "0.5",   # savingsPercent
            "0.4",   # lotteryPercent
            "0.1",   # treasuryPercent
            str(winner_count)  # winnerCount
        )
    else:
        print_step("Creating test pool...")
        # Parameters: minDeposit, drawInterval, savingsPercent, lotteryPercent, treasuryPercent
        success, output, _, _ = run_flow_tx(
            TX_CREATE_POOL,
            "1.0",   # minDeposit
            "1.0",   # drawInterval (1 second for fast testing)
            "0.5",   # savingsPercent
            "0.4",   # lotteryPercent
            "0.1"    # treasuryPercent
        )
    if not success:
        print_error("Failed to create pool")
        print_info(str(output)[:300])
        return None

    # Get pool ID
    success, output = run_flow_script("cadence/scripts/prize-linked-accounts/get_all_pools.cdc")
    if success:
        import re
        match = re.search(r'\[([0-9,\s]+)\]', str(output))
        if match:
            pools = [int(x.strip()) for x in match.group(1).split(',') if x.strip()]
            if pools:
                pool_id = max(pools)
                print_success(f"Pool created with ID: {pool_id}")
                return pool_id

    print_error("Could not determine pool ID")
    return None

# ============================================================
# USER CREATION AND DEPOSITS
# ============================================================

def create_users_and_deposit(pool_id: int, user_count: int) -> int:
    """
    Create user accounts, setup collections, and deposit.
    Returns the number of successfully created users.
    """
    print_step(f"Creating {user_count} users with deposits...")

    successful_users = 0

    # For emulator testing, we'll use the admin account to simulate multiple users
    # by doing multiple deposits. Each deposit auto-registers a new position.
    #
    # Actually, the cleaner approach is to create actual accounts, but that's slower.
    # For benchmarking purposes, we can use a simpler approach:
    # Create a transaction that creates multiple "virtual" deposits from the same account
    # but with different receiver IDs.
    #
    # For now, let's create actual accounts since we want accurate benchmarks.

    # First, setup collection for admin (may already exist)
    run_flow_tx(TX_SETUP_COLLECTION)  # Ignore result - may already exist

    # Do deposits from admin account - each deposit increases receiver count
    # But wait - we need DIFFERENT receivers. The receiver ID is the UUID of the
    # PoolPositionCollection, which is per-account.

    # For accurate benchmarking, we need multiple accounts.
    # Let's create a batch of accounts and deposits.

    batch_size = 10  # Create accounts in batches of 10

    for batch_start in range(0, user_count, batch_size):
        batch_end = min(batch_start + batch_size, user_count)
        current_batch_size = batch_end - batch_start

        if batch_start % 50 == 0:
            print_info(f"Creating users {batch_start+1}-{batch_end} of {user_count}...")

        for i in range(current_batch_size):
            user_num = batch_start + i + 1

            # Create account
            address = create_account()
            if not address:
                print_error(f"Failed to create account for user {user_num}")
                continue

            # For the emulator, new accounts are auto-funded
            # Setup collection - we need to use inline transaction since we can't
            # easily sign as the new account without adding it to flow.json

            # Actually, let's use a different approach:
            # Use the admin to setup collections via a special transaction
            # that takes an address parameter

            # For simplicity in Phase 1, let's use a workaround:
            # We'll create multiple deposits from accounts we already have configured

            successful_users += 1

    # WORKAROUND for Phase 1:
    # Instead of creating real accounts, let's use a transaction that simulates
    # multiple users by creating multiple PoolPositionCollections from admin
    # This is faster and good enough for computation benchmarking.

    print_info("Using fast user simulation for benchmark...")

    # Use a bulk setup approach - we'll create a special transaction for this
    success = setup_simulated_users(pool_id, user_count)
    if success:
        successful_users = user_count
        print_success(f"Created {successful_users} simulated users")
    else:
        print_error("Failed to create simulated users")
        successful_users = 0

    return successful_users

def setup_simulated_users(pool_id: int, user_count: int) -> bool:
    """
    Create simulated users by running setup and deposit from admin account.
    For benchmarking, what matters is the number of registered receivers,
    which we can achieve by having admin deposit on behalf of multiple "virtual" users.

    Actually, the TWAB and batch processing iterate over registeredReceiverList,
    which contains unique receiver IDs (UUIDs of PoolPositionCollections).

    To properly benchmark, we need actual separate PoolPositionCollections.

    Let's create a special benchmark transaction that creates N users inline.
    """

    # Create the benchmark setup transaction
    benchmark_tx_path = PROJECT_ROOT / "benchmark" / "transactions" / "setup_benchmark_users.cdc"
    benchmark_tx_path.parent.mkdir(parents=True, exist_ok=True)

    tx_code = '''
import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"

/// Creates multiple PoolPositionCollections and deposits for benchmarking
/// Each iteration creates a new collection resource with a unique UUID
/// startIndex allows batched creation without overwriting previous users
transaction(poolID: UInt64, userCount: Int, depositAmount: UFix64, startIndex: Int) {

    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let adminStorageRef: auth(Storage, Capabilities) &Account

    prepare(signer: auth(Storage, Capabilities) &Account) {
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")

        self.adminStorageRef = signer
    }

    execute {
        var created = 0
        var userIndex = startIndex

        // Create userCount separate PoolPositionCollections
        // Store them at unique paths to simulate different users
        while created < userCount {
            // Create a new collection
            let collection <- PrizeLinkedAccounts.createPoolPositionCollection()

            // Generate a unique storage path for this "user"
            let pathStr = "benchmarkUser".concat(userIndex.toString())
            let storagePath = StoragePath(identifier: pathStr)!

            // Save the collection
            self.adminStorageRef.storage.save(<-collection, to: storagePath)

            // Borrow it back to make a deposit
            let collectionRef = self.adminStorageRef.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
                from: storagePath
            )!

            // Withdraw tokens and deposit
            let tokens <- self.vaultRef.withdraw(amount: depositAmount)
            collectionRef.deposit(poolID: poolID, from: <-tokens)

            created = created + 1
            userIndex = userIndex + 1
        }

        log("Created ".concat(userCount.toString()).concat(" benchmark users starting at index ").concat(startIndex.toString()))
    }
}
'''

    benchmark_tx_path.write_text(tx_code)

    # Run the transaction with high compute limit
    deposit_amount = "10.0"  # 10 FLOW per user

    # Split into batches to avoid hitting compute limits during setup
    batch_size = 50
    total_created = 0

    for batch_start in range(0, user_count, batch_size):
        current_batch = min(batch_size, user_count - batch_start)

        success, output, tx_id, comp = run_flow_tx(
            str(benchmark_tx_path),
            str(pool_id),
            str(current_batch),
            deposit_amount,
            str(batch_start),  # startIndex to avoid overwriting previous batches
            compute_limit=99999  # Use high limit for setup
        )

        if not success:
            print_error(f"Failed to create batch starting at {batch_start}")
            print_info(str(output)[:300])
            return False

        total_created += current_batch
        if total_created % 100 == 0 or total_created == user_count:
            print_info(f"Created {total_created}/{user_count} users... (computation: {comp})")

    return True

# ============================================================
# DRAW PHASE EXECUTION
# ============================================================

def execute_draw_phase(
    phase_name: str,
    tx_path: str,
    pool_id: int,
    *extra_args,
    compute_limit: int = COMPUTE_LIMIT
) -> ComputationResult:
    """Execute a draw phase transaction and capture computation"""

    # Reset profiler BEFORE this transaction to get clean measurement
    reset_computation_profile()

    # Execute transaction
    success, output, tx_id, _ = run_flow_tx(
        tx_path,
        str(pool_id),
        *[str(a) for a in extra_args],
        compute_limit=compute_limit
    )

    # Get computation from emulator HTTP API (primary source)
    computation = 0
    memory = 0
    report = get_computation_report()

    if report and 'transactions' in report:
        # After reset + 1 transaction, there should be exactly 1 entry
        # Get the computation from the most recent transaction
        for tid, data in report.get('transactions', {}).items():
            # Match by tx_id if available, otherwise just take the only one
            if tx_id and tid == tx_id:
                computation = data.get('computation', 0)
                memory = data.get('memory', 0)
                break
            elif len(report.get('transactions', {})) == 1:
                computation = data.get('computation', 0)
                memory = data.get('memory', 0)
                break

    return ComputationResult(
        tx_name=phase_name,
        success=success,
        computation=computation,
        memory=memory,
        tx_id=tx_id or "",
        error=None if success else str(output)[:200]
    )

def get_draw_status(pool_id: int) -> Dict[str, Any]:
    """Query draw status and return parsed result"""
    success, result = run_flow_script(
        "cadence/scripts/prize-linked-accounts/get_draw_status.cdc",
        str(pool_id),
        output_json=True
    )

    # Parse the Cadence JSON struct format
    if success and isinstance(result, dict):
        # Flow CLI JSON format: {"value": {"fields": [{"name": "fieldName", "value": {"value": true}}]}}
        fields = result.get('value', {}).get('fields', [])
        status = {}
        for field in fields:
            name = field.get('name')
            value_obj = field.get('value', {})
            value = value_obj.get('value')
            # Convert string booleans
            if value == 'true':
                value = True
            elif value == 'false':
                value = False
            status[name] = value
        if status:
            return status

    # Fallback: try text parsing
    success, output = run_flow_script(
        "cadence/scripts/prize-linked-accounts/get_draw_status.cdc",
        str(pool_id)
    )

    # Parse the text output for key fields (format: "fieldName: value")
    output_str = str(output)
    status = {
        'isBatchComplete': 'isBatchComplete: true' in output_str,
        'isReadyForCompletion': 'isReadyForCompletion: true' in output_str,
        'canDrawNow': 'canDrawNow: true' in output_str,
        'isPendingDrawInProgress': 'isPendingDrawInProgress: true' in output_str,
    }
    return status


def fund_lottery_pool(pool_id: int, amount: str = "100.0") -> bool:
    """Fund the lottery pool with FLOW tokens for prize distribution"""
    print_step(f"Funding lottery pool with {amount} FLOW...")
    success, output, _, _ = run_flow_tx(TX_FUND_LOTTERY, str(pool_id), amount)
    if not success:
        print_error(f"Failed to fund lottery pool: {str(output)[:200]}")
        return False
    print_success(f"Lottery pool funded with {amount} FLOW")
    return True


def run_full_draw_benchmark(pool_id: int, user_count: int, batch_size: int, winner_count: int = 1) -> BenchmarkRun:
    """Run a complete draw and measure each phase"""

    winner_str = f", {winner_count} winners" if winner_count > 1 else ""
    print_header(f"BENCHMARKING DRAW: {user_count} users, batch size {batch_size}{winner_str}")

    phases: List[PhaseResult] = []

    # Fund the lottery pool so there are prizes to distribute
    # More winners need more prize money to distribute
    prize_amount = str(max(100.0, winner_count * 10.0))
    if not fund_lottery_pool(pool_id, prize_amount):
        print_error("Failed to fund lottery pool - winners may not be selected")

    # Wait for round to end (we set 1 second interval)
    print_step("Waiting for round to end...")
    time.sleep(2)

    # Check draw status before starting
    status = get_draw_status(pool_id)
    print_info(f"Initial draw status: canDrawNow={status.get('canDrawNow', 'unknown')}")

    # Phase 1: Start Draw
    print_step("Phase 1: startPoolDraw")
    result = execute_draw_phase("startPoolDraw", TX_START_DRAW, pool_id)
    if not result.success:
        print_error(f"startPoolDraw failed: {result.error}")
        return None

    print_metric("Computation", result.computation, "units")
    print_metric("TX ID", result.tx_id)
    phases.append(PhaseResult(
        phase_name="startPoolDraw",
        total_computation=result.computation,
        total_memory=result.memory,
        tx_count=1,
        avg_computation_per_tx=float(result.computation)
    ))

    # Phase 2: Process Batches
    print_step(f"Phase 2: processPoolDrawBatch (batch size: {batch_size})")
    batch_computations = []
    batch_count = 0
    total_batch_computation = 0
    max_batches = (user_count // batch_size) + 5  # Safety limit

    while batch_count < max_batches:
        batch_count += 1
        result = execute_draw_phase(
            f"processDrawBatch_{batch_count}",
            TX_PROCESS_BATCH,
            pool_id,
            batch_size
        )

        if not result.success:
            print_error(f"processDrawBatch failed on batch {batch_count}: {result.error}")
            break

        batch_computations.append(result.computation)
        total_batch_computation += result.computation
        print_info(f"  Batch {batch_count}: {result.computation} computation units")

        # Check if we're done
        status = get_draw_status(pool_id)
        is_batch_complete = status.get('isBatchComplete', False)

        if is_batch_complete:
            print_success(f"Batch processing complete after {batch_count} batches")
            break

    avg_per_batch = total_batch_computation / batch_count if batch_count > 0 else 0
    avg_per_user = total_batch_computation / user_count if user_count > 0 else 0

    print_metric("Batches processed", batch_count)
    print_metric("Total computation", total_batch_computation, "units")
    print_metric("Avg per batch", f"{avg_per_batch:.1f}", "units")
    print_metric("Avg per user", f"{avg_per_user:.2f}", "units")

    phases.append(PhaseResult(
        phase_name="processDrawBatch",
        total_computation=total_batch_computation,
        total_memory=0,
        tx_count=batch_count,
        avg_computation_per_tx=avg_per_batch,
        items_processed=user_count,
        computation_per_item=avg_per_user
    ))

    # Phase 3: Request Randomness
    print_step("Phase 3: requestDrawRandomness")
    result = execute_draw_phase("requestDrawRandomness", TX_REQUEST_RANDOMNESS, pool_id)
    if not result.success:
        print_error(f"requestDrawRandomness failed: {result.error}")
        print_info("Continuing to try completeDraw anyway...")
    else:
        print_metric("Computation", result.computation, "units")
        print_metric("TX ID", result.tx_id)
        phases.append(PhaseResult(
            phase_name="requestDrawRandomness",
            total_computation=result.computation,
            total_memory=result.memory,
            tx_count=1,
            avg_computation_per_tx=float(result.computation)
        ))

    # Wait for randomness to be available (need at least 1 block)
    print_info("Waiting for next block (randomness)...")
    time.sleep(3)

    # Phase 4: Complete Draw
    print_step("Phase 4: completePoolDraw")

    # Check if ready for completion
    status = get_draw_status(pool_id)
    print_info(f"Pre-completion status: isReadyForCompletion={status.get('isReadyForCompletion', 'unknown')}")

    result = execute_draw_phase("completePoolDraw", TX_COMPLETE_DRAW, pool_id)
    if not result.success:
        print_error(f"completePoolDraw failed: {result.error}")
    else:
        print_metric("Computation", result.computation, "units")
        print_metric("TX ID", result.tx_id)
        phases.append(PhaseResult(
            phase_name="completePoolDraw",
            total_computation=result.computation,
            total_memory=result.memory,
            tx_count=1,
            avg_computation_per_tx=float(result.computation)
        ))

    # Aggregate results
    total_comp = sum(p.total_computation for p in phases)
    total_mem = sum(p.total_memory for p in phases)
    total_tx = sum(p.tx_count for p in phases)

    print_header("DRAW BENCHMARK COMPLETE")
    print_metric("Total phases completed", len(phases))
    print_metric("Total computation", total_comp, "units")
    print_metric("Total transactions", total_tx)

    return BenchmarkRun(
        timestamp=datetime.now().isoformat(),
        user_count=user_count,
        batch_size=batch_size,
        phases=phases,
        total_computation=total_comp,
        total_memory=total_mem,
        total_tx_count=total_tx
    )

# ============================================================
# OUTPUT FORMATTING
# ============================================================

def print_summary(runs: List[BenchmarkRun]):
    """Print a summary table of all benchmark runs"""

    print_header("BENCHMARK SUMMARY")

    print(f"\n{'Users':<10} {'Batch':<10} {'Batches':<10} {'Total Comp':<15} {'Comp/User':<12}")
    print("-" * 60)

    for run in runs:
        batch_phase = next((p for p in run.phases if p.phase_name == "processDrawBatch"), None)
        batches = batch_phase.tx_count if batch_phase else 0
        comp_per_user = batch_phase.computation_per_item if batch_phase else 0

        print(f"{run.user_count:<10} {run.batch_size:<10} {batches:<10} {run.total_computation:<15} {comp_per_user:<12.2f}")

    print()

def save_results_csv(runs: List[BenchmarkRun], filepath: Path):
    """Save results to CSV file"""
    filepath.parent.mkdir(parents=True, exist_ok=True)

    with open(filepath, 'w', newline='') as f:
        writer = csv.writer(f)

        # Header
        writer.writerow([
            'timestamp', 'user_count', 'batch_size', 'total_computation',
            'total_tx_count', 'phase_name', 'phase_computation', 'phase_tx_count',
            'computation_per_user'
        ])

        # Data
        for run in runs:
            for phase in run.phases:
                writer.writerow([
                    run.timestamp,
                    run.user_count,
                    run.batch_size,
                    run.total_computation,
                    run.total_tx_count,
                    phase.phase_name,
                    phase.total_computation,
                    phase.tx_count,
                    phase.computation_per_item
                ])

    print_success(f"Results saved to {filepath}")

def save_results_json(runs: List[BenchmarkRun], filepath: Path):
    """Save results to JSON file"""
    filepath.parent.mkdir(parents=True, exist_ok=True)

    data = []
    for run in runs:
        run_dict = {
            'timestamp': run.timestamp,
            'user_count': run.user_count,
            'batch_size': run.batch_size,
            'total_computation': run.total_computation,
            'total_memory': run.total_memory,
            'total_tx_count': run.total_tx_count,
            'phases': [
                {
                    'phase_name': p.phase_name,
                    'total_computation': p.total_computation,
                    'total_memory': p.total_memory,
                    'tx_count': p.tx_count,
                    'avg_computation_per_tx': p.avg_computation_per_tx,
                    'items_processed': p.items_processed,
                    'computation_per_item': p.computation_per_item
                }
                for p in run.phases
            ]
        }
        data.append(run_dict)

    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)

    print_success(f"Results saved to {filepath}")

# ============================================================
# MAIN
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description='Benchmark PrizeLinkedAccounts draw computation units (CUs)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Basic benchmark with 500 users
    python3 benchmark/benchmark_draw_computation.py --users 500 --batch-size 500

    # With profiling (saves pprof files for detailed analysis)
    python3 benchmark/benchmark_draw_computation.py --users 1000 --batch-size 1000 --profile

    # Multiple runs to measure variability
    python3 benchmark/benchmark_draw_computation.py --users 2000 --batch-size 2000 --runs 3

    # Analyze existing pprof profile
    python3 benchmark/benchmark_draw_computation.py --analyze-profile benchmark/results/profile.pprof

Output Files:
    benchmark/results/benchmark_results.json  - Detailed results (JSON)
    benchmark/results/benchmark_results.csv   - Tabular results (CSV)
    benchmark/results/*.pprof                 - Profiling data (if --profile)

Key Metrics:
    - Flow CU limit: 9,999 per transaction
    - processDrawBatch: ~3.25 CU per user
    - Max batch size: ~3,075 users (recommended: 2,500)
        """
    )
    parser.add_argument('--users', type=int, default=100,
                        help='Number of users to benchmark (default: 100)')
    parser.add_argument('--batch-size', type=int, default=50,
                        help='Batch size for processDrawBatch (default: 50). Set equal to --users for single batch.')
    parser.add_argument('--winners', type=int, default=1,
                        help='Number of winners per draw (default: 1). Higher values test winner selection performance.')
    parser.add_argument('--runs', type=int, default=1,
                        help='Number of benchmark runs (default: 1). Multiple runs help measure variability.')
    parser.add_argument('--profile', action='store_true',
                        help='Enable computation profiling and save pprof files')
    parser.add_argument('--analyze-profile', type=str, metavar='PATH',
                        help='Analyze an existing pprof profile without running benchmark')
    parser.add_argument('--skip-setup', action='store_true',
                        help='Skip emulator/contract setup (assume already running)')
    args = parser.parse_args()

    # Handle --analyze-profile mode (standalone profile analysis)
    if args.analyze_profile:
        profile_path = Path(args.analyze_profile)
        analysis = analyze_profile(profile_path)
        if analysis:
            print_profile_analysis(analysis, f"Profile Analysis: {profile_path.name}")
            return 0
        else:
            return 1

    runs: List[BenchmarkRun] = []
    all_computations = []  # Track computation values across runs for variability analysis

    try:
        if not args.skip_setup:
            # Setup emulator
            kill_existing_emulator()
            if not start_emulator_with_profiling(enable_profiling=args.profile):
                print_error("Failed to start emulator")
                return 1

            # Deploy contracts
            if not deploy_contracts():
                print_error("Failed to deploy contracts")
                return 1
        else:
            print_info("Skipping setup (--skip-setup)")
            if not check_emulator_health():
                print_error("Emulator not running. Remove --skip-setup or start emulator manually.")
                return 1

        # Run benchmark(s)
        for run_num in range(1, args.runs + 1):
            winner_str = f", {args.winners} winners" if args.winners > 1 else ""
            print_header(f"BENCHMARK RUN {run_num}/{args.runs}: {args.users} users, batch size {args.batch_size}{winner_str}")

            # Setup pool (fresh pool for each run)
            pool_id = setup_pool(winner_count=args.winners)
            if pool_id is None:
                print_error("Failed to setup pool")
                return 1

            # Create users
            created = setup_simulated_users(pool_id, args.users)
            if not created:
                print_error("Failed to create users")
                return 1

            # Run benchmark
            run = run_full_draw_benchmark(pool_id, args.users, args.batch_size, args.winners)
            if run:
                runs.append(run)

                # Track processDrawBatch computation for variability analysis
                batch_phase = next((p for p in run.phases if p.phase_name == "processDrawBatch"), None)
                if batch_phase:
                    all_computations.append(batch_phase.total_computation)

            # Download profile after each run if profiling enabled
            if args.profile:
                timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                profile_filename = f"process_batch_{args.users}users_run{run_num}_{timestamp}.pprof"
                profile_path = PROFILES_DIR / profile_filename

                if download_computation_profile(profile_path):
                    analysis = analyze_profile(profile_path)
                    if analysis:
                        print_profile_analysis(analysis, f"Profile Analysis - Run {run_num}")

        # Print summary
        if runs:
            print_summary(runs)
            save_results_csv(runs, RESULTS_DIR / "benchmark_results.csv")
            save_results_json(runs, RESULTS_DIR / "benchmark_results.json")

            # Variability analysis for multiple runs
            if len(all_computations) > 1:
                print_header("VARIABILITY ANALYSIS")
                min_comp = min(all_computations)
                max_comp = max(all_computations)
                avg_comp = sum(all_computations) / len(all_computations)
                variance_ratio = max_comp / min_comp if min_comp > 0 else 0

                print_metric("Runs", len(all_computations))
                print_metric("Min computation", min_comp, "units")
                print_metric("Max computation", max_comp, "units")
                print_metric("Avg computation", f"{avg_comp:.1f}", "units")
                print_metric("Variance ratio", f"{variance_ratio:.2f}x")

                if variance_ratio > 2:
                    print(f"\n{Colors.YELLOW}⚠ High variance detected! Computation varies by {variance_ratio:.1f}x{Colors.NC}")
                else:
                    print(f"\n{Colors.GREEN}✓ Computation is stable (variance ratio: {variance_ratio:.2f}x){Colors.NC}")

        print_header("BENCHMARK COMPLETE")
        print_info("Review the results above for optimization opportunities.")

        if args.profile:
            print_info(f"\nProfiles saved to: {PROFILES_DIR}")
            print_info("Analyze with: go tool pprof -http=:8081 <profile.pprof>")

        return 0

    except KeyboardInterrupt:
        print("\n\nBenchmark interrupted by user")
        return 1
    finally:
        if not args.skip_setup:
            stop_emulator()

if __name__ == "__main__":
    sys.exit(main())
