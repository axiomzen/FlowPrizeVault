import "PrizeLinkedAccounts"

/// Update Prize Distribution — Single Winner (requires CriticalOps).
///
/// Switches the pool to a winner-takes-all distribution. One address wins
/// the entire prize pool each draw.
///
/// WARNING: Distribution changes take effect on the next syncWithYieldSource call.
/// Changing mid-round alters the split for the current draw without retroactive adjustment.
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
        let newDistribution = PrizeLinkedAccounts.SingleWinnerPrize(nftIDs: [])

        self.adminRef.updatePoolPrizeDistribution(
            poolID: poolID,
            newDistribution: newDistribution
        )

        log("Pool ".concat(poolID.toString()).concat(" updated to SingleWinner distribution"))
    }
}
