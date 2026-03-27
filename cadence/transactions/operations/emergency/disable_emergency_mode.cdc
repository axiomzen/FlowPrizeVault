import "PrizeLinkedAccounts"

/// Disable Emergency Mode (requires CriticalOps).
///
/// Returns the pool to Normal operation. Verify that the underlying issue
/// (yield source health, withdrawal failures) is resolved before calling this.
///
/// If autoRecoveryEnabled is true (default), the contract will also auto-recover
/// when yield source health normalizes — you may not need this transaction.
///
/// Signer: deployer account OR ops account with CriticalOps capability
transaction(poolID: UInt64) {

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
        self.adminRef.disableEmergencyMode(poolID: poolID)

        log("Emergency mode disabled for pool ".concat(poolID.toString()).concat(" — pool returned to normal operation"))
    }
}
