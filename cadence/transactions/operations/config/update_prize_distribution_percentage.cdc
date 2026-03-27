import "PrizeLinkedAccounts"

/// Update Prize Distribution — Percentage Split (requires CriticalOps).
///
/// Switches the pool to a multi-winner distribution where each winner receives
/// a fixed percentage of the prize pool. prizeSplits must sum to 1.0.
///
/// Examples:
///   [0.6, 0.4]       → 2 winners: 60% and 40%
///   [0.5, 0.3, 0.2]  → 3 winners: 50%, 30%, 20%
///
/// WARNING: Distribution changes take effect on the next syncWithYieldSource call.
/// Changing mid-round alters the split for the current draw without retroactive adjustment.
///
/// Signer: deployer account OR ops account with CriticalOps capability
transaction(poolID: UInt64, prizeSplits: [UFix64]) {

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
        let newDistribution = PrizeLinkedAccounts.PercentageSplit(
            prizeSplits: prizeSplits,
            nftIDs: []
        )

        self.adminRef.updatePoolPrizeDistribution(
            poolID: poolID,
            newDistribution: newDistribution
        )

        log("Pool ".concat(poolID.toString()).concat(" updated to PercentageSplit with ")
            .concat(prizeSplits.length.toString()).concat(" winner(s)"))
    }
}
