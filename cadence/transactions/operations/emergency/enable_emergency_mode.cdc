import "PrizeLinkedAccounts"

/// Enable Emergency Mode (requires CriticalOps).
///
/// Immediately halts deposits and draws. Withdrawals remain available so users
/// can exit safely. The pool enters EmergencyMode (state 2).
///
/// Emergency states:
///   Normal (0)        — all operations enabled
///   Paused (1)        — no operations (use only if EmergencyMode is insufficient)
///   EmergencyMode (2) — withdrawals only, no deposits or draws
///   PartialMode (3)   — limited deposits, withdrawals only, no draws
///
/// The contract also auto-triggers EmergencyMode if:
///   - Consecutive withdrawal failures exceed maxWithdrawFailures (default: 3)
///   - Yield source health drops below minYieldSourceHealth
///
/// Signer: deployer account OR ops account with CriticalOps capability
transaction(poolID: UInt64, reason: String) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        if let directRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) {
            self.adminRef = directRef
        } else {
            let cap = signer.storage.copy<Capability<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
                from: /storage/PrizeLinkedAccountsAdminCriticalOps
            ) ?? panic("No CriticalOps access. Sign with deployer or run setup/claim_critical_ops_capability.cdc first.")
            self.adminRef = cap.borrow()
                ?? panic("CriticalOps capability is invalid or has been revoked.")
        }
    }

    execute {
        self.adminRef.enableEmergencyMode(poolID: poolID, reason: reason)

        log("Emergency mode enabled for pool ".concat(poolID.toString()).concat(". Reason: ").concat(reason))
    }
}
