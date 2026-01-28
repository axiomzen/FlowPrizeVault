#!/usr/bin/env python3
"""
PrizeLinkedAccounts completeDraw Computation Benchmark

Measures computation units (CUs) consumed by the completeDraw phase with varying
numbers of winners to find the maximum winners per draw within Flow's 9,999 CU limit.

Usage:
    # Single test with specific winners/users
    python3 benchmark/benchmark_complete_draw.py --winners 50 --users 100

    # Test variability by running same config multiple times
    python3 benchmark/benchmark_complete_draw.py --winners 125 --users 175 --runs 5

    # Run with profiling to capture pprof data
    python3 benchmark/benchmark_complete_draw.py --winners 125 --users 175 --profile

    # Analyze existing profile
    python3 benchmark/benchmark_complete_draw.py --analyze-profile /path/to/profile.pprof

The completeDraw phase iterates through each winner to:
- Withdraw prize from lottery pool
- Mint shares for winner (auto-compound)
- Update TWAB in active round
- Re-deposit to yield source
- Track lifetime prizes
- Emit events

Key Finding: The selectWinners function now uses BINARY SEARCH with
rejection sampling, providing O(k * log n) complexity. This should
result in consistent computation across runs.
"""

import subprocess
import json
import time
import sys
import os
import signal
import argparse
import re
from pathlib import Path
from datetime import datetime
from typing import Optional, Tuple, List, Dict, Any

# ============================================================
# CONFIGURATION
# ============================================================

NETWORK = "emulator"
ADMIN_ACCOUNT = "emulator-account"
FLOW_FLAGS = ["--skip-version-check"]
COMPUTE_LIMIT = 9999
EMULATOR_PORT = 8080

PROJECT_ROOT = Path(__file__).parent.parent
RESULTS_DIR = PROJECT_ROOT / "benchmark" / "results"
PROFILES_DIR = PROJECT_ROOT / "benchmark" / "profiles"

# Transaction paths
TX_SETUP_YIELD_VAULT = "cadence/transactions/prize-linked-accounts/setup_test_yield_vault.cdc"
TX_SETUP_COLLECTION = "cadence/transactions/prize-linked-accounts/setup_collection.cdc"
TX_CREATE_MULTI_WINNER_POOL = "benchmark/transactions/create_multi_winner_pool.cdc"
TX_START_DRAW = "cadence/transactions/prize-linked-accounts/start_draw.cdc"
TX_PROCESS_BATCH = "cadence/transactions/test/process_draw_batch.cdc"
TX_REQUEST_RANDOMNESS = "cadence/transactions/test/request_draw_randomness.cdc"
TX_COMPLETE_DRAW = "cadence/transactions/prize-linked-accounts/complete_draw.cdc"
TX_SETUP_USERS = "benchmark/transactions/setup_benchmark_users.cdc"
TX_FUND_LOTTERY = "cadence/transactions/test/fund_prize_pool.cdc"

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
    NC = '\033[0m'

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

def print_warning(msg: str):
    print(f"{Colors.YELLOW}⚠ {msg}{Colors.NC}")

# ============================================================
# EMULATOR MANAGEMENT
# ============================================================

emulator_process: Optional[subprocess.Popen] = None

def kill_existing_emulator():
    """Kill any existing emulator processes"""
    print_step("Killing any existing emulator...")
    subprocess.run(["pkill", "-f", "flow emulator"], capture_output=True)
    result = subprocess.run(["lsof", "-ti", f":{EMULATOR_PORT}"], capture_output=True, text=True)
    if result.stdout.strip():
        for pid in result.stdout.strip().split('\n'):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ValueError, ProcessLookupError):
                pass
    time.sleep(2)
    print_success("Existing emulator killed")

def start_emulator(enable_profiling: bool = False) -> bool:
    """Start the Flow emulator with computation reporting/profiling"""
    global emulator_process
    print_step("Starting emulator...")
    os.chdir(PROJECT_ROOT)

    cmd = ["flow", "emulator", "--computation-reporting", "--verbose=false"]
    if enable_profiling:
        cmd.append("--computation-profiling")
        print_info("Profiling enabled - pprof data will be available")

    try:
        emulator_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        for i in range(30):
            time.sleep(1)
            if check_emulator_health():
                print_success(f"Emulator started (PID: {emulator_process.pid})")
                return True
            if i % 5 == 4:
                print_info(f"Waiting for emulator... ({i+1}/30)")

        print_error("Emulator failed to start")
        return False
    except Exception as e:
        print_error(f"Failed to start emulator: {e}")
        return False

def check_emulator_health() -> bool:
    """Check if the emulator is responding"""
    try:
        result = subprocess.run(
            ["curl", "-s", f"http://localhost:{EMULATOR_PORT}/health"],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0
    except:
        return False

def reset_computation_profile() -> bool:
    """Reset the computation profiler for isolated measurements"""
    try:
        result = subprocess.run(
            ["curl", "-s", "-X", "PUT",
             f"http://localhost:{EMULATOR_PORT}/emulator/computationProfile/reset"],
            capture_output=True, text=True, timeout=5
        )
        return result.returncode == 0
    except:
        return False

def get_computation_report() -> Dict[str, Any]:
    """Fetch the computation report from the emulator"""
    try:
        result = subprocess.run(
            ["curl", "-s", f"http://localhost:{EMULATOR_PORT}/emulator/computationReport"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout:
            return json.loads(result.stdout)
    except Exception as e:
        print_error(f"Failed to get computation report: {e}")
    return {}

def download_computation_profile(output_path: Path) -> bool:
    """Download the pprof computation profile from the emulator"""
    try:
        result = subprocess.run(
            ["curl", "-s", "-o", str(output_path),
             f"http://localhost:{EMULATOR_PORT}/emulator/computationProfile"],
            capture_output=True, timeout=30
        )
        if result.returncode == 0 and output_path.exists():
            size = output_path.stat().st_size
            if size > 100:  # Non-empty profile
                return True
    except Exception as e:
        print_error(f"Failed to download profile: {e}")
    return False

def analyze_profile(profile_path: Path, top_n: int = 20) -> Optional[str]:
    """Analyze a pprof profile and return top functions"""
    try:
        result = subprocess.run(
            ["go", "tool", "pprof", "-top", str(profile_path)],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            return '\n'.join(lines[:top_n + 5])  # Include header
    except Exception as e:
        print_error(f"Failed to analyze profile: {e}")
    return None

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

# ============================================================
# FLOW CLI HELPERS
# ============================================================

def run_command(cmd: List[str], timeout: int = 120) -> Tuple[int, str, str]:
    """Run a shell command and return exit code, stdout, stderr"""
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=timeout, cwd=PROJECT_ROOT
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
    compute_limit: int = COMPUTE_LIMIT,
    measure_computation: bool = False
) -> Tuple[bool, str, Optional[str], int]:
    """
    Run a Flow transaction and optionally measure computation.

    Returns: (success, output, tx_id, computation)
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
    tx_id = None
    computation = 0

    try:
        result = json.loads(stdout)
        tx_id = result.get('id', result.get('transactionId'))
        success = result.get('status') == 'SEALED' or result.get('statusString') == 'SEALED'
        if not success:
            error = result.get('error', result.get('errorMessage', ''))
            if error:
                return False, str(error), tx_id, 0
    except json.JSONDecodeError:
        output = stdout + stderr
        success = code == 0 and 'error' not in output.lower() and 'panic' not in output.lower()
        return success, output, tx_id, 0

    # Get computation from HTTP API if measuring
    if measure_computation and tx_id:
        time.sleep(0.2)  # Ensure report is updated
        report = get_computation_report()
        if report and 'transactions' in report:
            if tx_id in report['transactions']:
                computation = report['transactions'][tx_id].get('computation', 0)

    return True, stdout, tx_id, computation

def run_flow_script(script_path: str, *args) -> Tuple[bool, str]:
    """Run a Flow script and return success status and output"""
    cmd = [
        "flow", "scripts", "execute", script_path
    ] + list(args) + [
        "--network", NETWORK
    ] + FLOW_FLAGS

    code, stdout, stderr = run_command(cmd)
    output = stdout + stderr
    success = code == 0 and 'error' not in output.lower() and 'panic' not in output.lower()
    return success, output

# ============================================================
# SETUP FUNCTIONS
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
        print_error("Contract deployment failed")
        print_info(output[:500])
        return False

    print_success("Contracts deployed")
    return True

def setup_base_infrastructure() -> bool:
    """Setup yield vault and admin collection (one-time per emulator)"""
    print_step("Setting up test yield vault...")
    success, output, _, _ = run_flow_tx(TX_SETUP_YIELD_VAULT)
    if not success and 'already' not in str(output).lower():
        print_error("Failed to setup yield vault")
        return False

    print_step("Setting up admin collection...")
    success, output, _, _ = run_flow_tx(TX_SETUP_COLLECTION)
    if not success and 'already' not in str(output).lower():
        print_error("Failed to setup admin collection")
        return False

    return True

def create_multi_winner_pool(winner_count: int) -> Optional[int]:
    """Create a pool configured for multiple winners"""
    print_step(f"Creating multi-winner pool ({winner_count} winners)...")
    success, output, _, _ = run_flow_tx(
        TX_CREATE_MULTI_WINNER_POOL,
        str(winner_count),  # winnerCount
        "1.0",              # minimumDeposit
        "1.0"               # drawIntervalSeconds (short for testing)
    )
    if not success:
        print_error(f"Failed to create pool: {output[:300]}")
        return None

    # Get pool ID
    success, output = run_flow_script("cadence/scripts/prize-linked-accounts/get_all_pools.cdc")
    if success:
        match = re.search(r'\[([0-9,\s]+)\]', str(output))
        if match:
            pools = [int(x.strip()) for x in match.group(1).split(',') if x.strip()]
            if pools:
                pool_id = max(pools)
                print_success(f"Pool created with ID: {pool_id}")
                return pool_id

    print_error("Could not determine pool ID")
    return None

def create_users(pool_id: int, user_count: int, start_index: int = 0) -> bool:
    """
    Create simulated users for a pool.

    Args:
        pool_id: The pool to add users to
        user_count: Number of users to create
        start_index: Starting index for storage paths (use unique values per pool
                     to avoid storage path collisions)
    """
    print_step(f"Creating {user_count} users (starting at index {start_index})...")

    batch_size = 50
    for batch_start in range(0, user_count, batch_size):
        current_batch = min(batch_size, user_count - batch_start)
        actual_start = start_index + batch_start

        success, output, _, _ = run_flow_tx(
            TX_SETUP_USERS,
            str(pool_id),
            str(current_batch),
            "10.0",              # depositAmount
            str(actual_start),   # startIndex - unique per pool!
            compute_limit=99999
        )

        if not success:
            print_error(f"Failed to create users: {output[:300]}")
            return False

        total = batch_start + current_batch
        if total % 100 == 0 or total == user_count:
            print_info(f"Created {total}/{user_count} users")

    print_success(f"Created {user_count} users")
    return True

def get_draw_status(pool_id: int) -> Dict[str, Any]:
    """Query draw status for a pool"""
    success, output = run_flow_script(
        "cadence/scripts/prize-linked-accounts/get_draw_status.cdc",
        str(pool_id)
    )

    output_str = str(output)
    return {
        'isBatchComplete': 'isBatchComplete: true' in output_str,
        'isReadyForCompletion': 'isReadyForCompletion: true' in output_str,
    }

def fund_lottery_pool(pool_id: int, amount: float) -> bool:
    """Fund the lottery pool with tokens for prize distribution"""
    print_step(f"Funding lottery pool with {amount} FLOW...")
    success, output, _, _ = run_flow_tx(TX_FUND_LOTTERY, str(pool_id), str(amount))
    if not success:
        print_error(f"Failed to fund lottery pool: {output[:200]}")
        return False
    print_success(f"Funded lottery pool with {amount} FLOW")
    return True

# ============================================================
# BENCHMARK EXECUTION
# ============================================================

def run_draw_phases_1_to_3(pool_id: int, user_count: int, winner_count: int) -> Dict[str, int]:
    """
    Run draw phases 1-3 (setup for completeDraw).

    Returns dict with computation for each phase.
    """
    results = {}

    # Fund lottery pool
    prize_amount = winner_count * 10.0
    if not fund_lottery_pool(pool_id, prize_amount):
        return results

    # Wait for round to end
    print_step("Waiting for round to end...")
    time.sleep(2)

    # Phase 1: Start Draw
    print_step("Phase 1: startPoolDraw")
    success, output, tx_id, comp = run_flow_tx(
        TX_START_DRAW, str(pool_id), measure_computation=True
    )
    if not success:
        print_error(f"startPoolDraw failed: {output[:200]}")
        return results
    print_metric("Computation", comp, "units")
    results['startPoolDraw'] = comp

    # Phase 2: Process Batches
    print_step("Phase 2: processPoolDrawBatch")
    batch_comp_total = 0
    batch_count = 0

    while batch_count < 100:
        batch_count += 1
        success, output, tx_id, comp = run_flow_tx(
            TX_PROCESS_BATCH, str(pool_id), str(user_count),
            measure_computation=True
        )
        if not success:
            print_error(f"processDrawBatch failed: {output[:200]}")
            break
        batch_comp_total += comp

        status = get_draw_status(pool_id)
        if status.get('isBatchComplete'):
            break

    print_metric("Batches", batch_count)
    print_metric("Total computation", batch_comp_total, "units")
    results['processDrawBatch'] = batch_comp_total

    # Phase 3: Request Randomness
    print_step("Phase 3: requestDrawRandomness")
    success, output, tx_id, comp = run_flow_tx(
        TX_REQUEST_RANDOMNESS, str(pool_id), measure_computation=True
    )
    if not success:
        print_error(f"requestDrawRandomness failed: {output[:200]}")
        return results
    print_metric("Computation", comp, "units")
    results['requestDrawRandomness'] = comp

    # Wait for randomness to be available
    print_info("Waiting for next block...")
    time.sleep(3)

    return results

def run_complete_draw_with_profiling(
    pool_id: int,
    winner_count: int,
    save_profile: bool = False,
    profile_path: Optional[Path] = None
) -> Tuple[int, Optional[str], Optional[Path]]:
    """
    Run completeDraw with optional profiling.

    Returns: (computation, tx_id, profile_path if saved)
    """
    # Reset profile for isolated measurement
    if save_profile:
        reset_computation_profile()

    # Run completeDraw
    print_step(f"Phase 4: completePoolDraw ({winner_count} winners)")
    success, output, tx_id, comp = run_flow_tx(
        TX_COMPLETE_DRAW, str(pool_id),
        measure_computation=True,
        compute_limit=99999  # High limit to avoid failures
    )

    saved_profile = None
    if not success:
        print_error(f"completePoolDraw failed: {output[:200]}")
        return 0, tx_id, None

    print_metric("Computation", comp, "units")
    if winner_count > 0:
        print_metric("Computation per winner", f"{comp / winner_count:.2f}", "units")

    # Save profile if requested and computation is notable
    if save_profile and profile_path:
        profile_path.parent.mkdir(parents=True, exist_ok=True)
        if download_computation_profile(profile_path):
            print_success(f"Profile saved to {profile_path}")
            saved_profile = profile_path

    return comp, tx_id, saved_profile

def run_single_benchmark(
    winner_count: int,
    user_count: int,
    pool_id: int,
    user_start_index: int,
    enable_profiling: bool = False,
    run_number: int = 1
) -> Dict[str, Any]:
    """
    Run a single completeDraw benchmark.

    Args:
        winner_count: Number of winners for the pool
        user_count: Number of users to create
        pool_id: Pool ID (already created)
        user_start_index: Starting index for user storage paths
        enable_profiling: Whether to save pprof profile
        run_number: Run number for naming profiles
    """
    print_header(f"BENCHMARK: {winner_count} winners, {user_count} users (Run #{run_number})")

    result = {
        'winner_count': winner_count,
        'user_count': user_count,
        'pool_id': pool_id,
        'run_number': run_number,
        'timestamp': datetime.now().isoformat(),
        'phases': {},
        'profile_path': None
    }

    # Create users with unique start index
    if not create_users(pool_id, user_count, start_index=user_start_index):
        result['error'] = "Failed to create users"
        return result

    # Run phases 1-3
    phase_results = run_draw_phases_1_to_3(pool_id, user_count, winner_count)
    if not phase_results:
        result['error'] = "Failed in phases 1-3"
        return result
    result['phases'].update(phase_results)

    # Run phase 4 (completeDraw) with optional profiling
    profile_path = None
    if enable_profiling:
        PROFILES_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        profile_path = PROFILES_DIR / f"completedraw_w{winner_count}_run{run_number}_{timestamp}.pprof"

    comp, tx_id, saved_profile = run_complete_draw_with_profiling(
        pool_id, winner_count,
        save_profile=enable_profiling,
        profile_path=profile_path
    )

    result['phases']['completePoolDraw'] = comp
    result['computation_per_winner'] = comp / winner_count if winner_count > 0 else 0
    result['tx_id'] = tx_id
    result['exceeded_limit'] = comp > 9999

    if saved_profile:
        result['profile_path'] = str(saved_profile)

    # Classify computation level
    if comp > 5000:
        result['computation_level'] = 'HIGH'
        print_warning(f"HIGH computation detected: {comp} units")
    elif comp > 1000:
        result['computation_level'] = 'MEDIUM'
    else:
        result['computation_level'] = 'LOW'

    return result

def run_variability_test(
    winner_count: int,
    user_count: int,
    num_runs: int,
    enable_profiling: bool = False
) -> List[Dict[str, Any]]:
    """
    Run multiple tests with same config to measure variability.

    This helps identify the impact of random number generation on
    the selectWinners algorithm.
    """
    print_header(f"VARIABILITY TEST: {winner_count} winners, {num_runs} runs")

    all_results = []

    for run_num in range(1, num_runs + 1):
        # Create new pool for each run
        pool_id = create_multi_winner_pool(winner_count)
        if pool_id is None:
            continue

        # Use unique user start index per pool to avoid storage collisions
        user_start_index = (pool_id * 1000)

        result = run_single_benchmark(
            winner_count=winner_count,
            user_count=user_count,
            pool_id=pool_id,
            user_start_index=user_start_index,
            enable_profiling=enable_profiling,
            run_number=run_num
        )
        all_results.append(result)

    return all_results

# ============================================================
# ANALYSIS AND REPORTING
# ============================================================

def print_variability_summary(results: List[Dict[str, Any]]):
    """Print summary of variability test results"""
    print_header("VARIABILITY ANALYSIS")

    computations = [r['phases'].get('completePoolDraw', 0) for r in results if 'phases' in r]

    if not computations:
        print_error("No valid results to analyze")
        return

    low_count = sum(1 for c in computations if c < 1000)
    high_count = sum(1 for c in computations if c > 5000)

    print(f"\n{'Run':<6} {'Computation':<15} {'Per Winner':<12} {'Level'}")
    print("-" * 50)

    for r in results:
        run = r.get('run_number', '?')
        comp = r.get('phases', {}).get('completePoolDraw', 'N/A')
        per_winner = r.get('computation_per_winner', 0)
        level = r.get('computation_level', '?')
        print(f"{run:<6} {comp:<15} {per_winner:<12.2f} {level}")

    print(f"\n{Colors.CYAN}Statistics:{Colors.NC}")
    print(f"  Min:     {min(computations)}")
    print(f"  Max:     {max(computations)}")
    print(f"  Mean:    {sum(computations) / len(computations):.1f}")
    print(f"  Range:   {max(computations) - min(computations)}")
    print(f"  Ratio:   {max(computations) / max(min(computations), 1):.1f}x")
    print(f"\n  LOW runs (<1000):   {low_count}/{len(computations)}")
    print(f"  HIGH runs (>5000):  {high_count}/{len(computations)}")

    if high_count > 0:
        print_warning(
            f"\n{high_count} HIGH computation runs detected!"
            f"\nWith binary search, this should be rare. Check for:"
            f"\n- High retry rates from rejection sampling"
            f"\n- Unusual weight distributions"
        )

def analyze_profile_file(profile_path: Path):
    """Analyze and print profile information"""
    print_header(f"PROFILE ANALYSIS: {profile_path.name}")

    if not profile_path.exists():
        print_error(f"Profile not found: {profile_path}")
        return

    analysis = analyze_profile(profile_path, top_n=25)
    if analysis:
        print(analysis)
        print(f"\n{Colors.CYAN}To view interactive flame graph:{Colors.NC}")
        print(f"  go tool pprof -http=:8081 {profile_path}")
    else:
        print_error("Failed to analyze profile")

def save_results(results: List[Dict[str, Any]], filename: str = "complete_draw_benchmark.json"):
    """Save benchmark results to JSON file"""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    results_file = RESULTS_DIR / filename

    with open(results_file, 'w') as f:
        json.dump(results, f, indent=2, default=str)

    print_success(f"Results saved to {results_file}")
    return results_file

# ============================================================
# MAIN
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description='Benchmark completeDraw computation with multiple winners',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Single test
  python3 benchmark/benchmark_complete_draw.py --winners 50 --users 100

  # Variability test (multiple runs with same config)
  python3 benchmark/benchmark_complete_draw.py --winners 125 --users 175 --runs 5

  # With profiling (saves pprof files)
  python3 benchmark/benchmark_complete_draw.py --winners 125 --users 175 --runs 3 --profile

  # Analyze existing profile
  python3 benchmark/benchmark_complete_draw.py --analyze-profile benchmark/profiles/profile.pprof
        """
    )
    parser.add_argument('--winners', type=int, default=10,
                        help='Number of winners to test (default: 10)')
    parser.add_argument('--users', type=int, default=100,
                        help='Number of users (default: 100, must be >= winners)')
    parser.add_argument('--runs', type=int, default=1,
                        help='Number of test runs for variability analysis (default: 1)')
    parser.add_argument('--profile', action='store_true',
                        help='Enable profiling and save pprof files')
    parser.add_argument('--analyze-profile', type=str, metavar='PATH',
                        help='Analyze an existing pprof profile file')

    args = parser.parse_args()

    # Handle profile analysis mode
    if args.analyze_profile:
        analyze_profile_file(Path(args.analyze_profile))
        return 0

    # Validate inputs
    if args.users < args.winners:
        args.users = args.winners + 50
        print_info(f"Adjusted users to {args.users} (must be > winners)")

    all_results = []

    try:
        kill_existing_emulator()

        if not start_emulator(enable_profiling=args.profile):
            return 1

        if not deploy_contracts():
            return 1

        if not setup_base_infrastructure():
            return 1

        # Run variability test
        results = run_variability_test(
            winner_count=args.winners,
            user_count=args.users,
            num_runs=args.runs,
            enable_profiling=args.profile
        )
        all_results.extend(results)

        # Print summary
        if args.runs > 1:
            print_variability_summary(results)
        else:
            print_header("RESULTS SUMMARY")
            for r in results:
                comp = r.get('phases', {}).get('completePoolDraw', 'N/A')
                per_winner = r.get('computation_per_winner', 0)
                level = r.get('computation_level', '?')
                print(f"  completeDraw: {comp} units ({per_winner:.2f} per winner) [{level}]")

        # Save results
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        save_results(all_results, f"complete_draw_w{args.winners}_r{args.runs}_{timestamp}.json")

        # Print profile locations if profiling was enabled
        if args.profile:
            print(f"\n{Colors.CYAN}Saved profiles:{Colors.NC}")
            for r in results:
                if r.get('profile_path'):
                    level = r.get('computation_level', '?')
                    print(f"  [{level}] {r['profile_path']}")

        return 0

    except KeyboardInterrupt:
        print("\nBenchmark interrupted")
        return 1
    finally:
        stop_emulator()

if __name__ == "__main__":
    sys.exit(main())
