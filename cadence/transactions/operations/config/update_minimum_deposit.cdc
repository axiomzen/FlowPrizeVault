import "PrizeLinkedAccounts"

/// Update Minimum Deposit (requires ConfigOps).
///
/// Sets the minimum token amount required for a new deposit. Existing positions
/// are not affected — only new deposits must meet the new minimum.
///
/// Signer: deployer account OR ops/automation account with ConfigOps capability
transaction(poolID: UInt64, newMinimum: UFix64) {

    let adminRef: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        if let directRef = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) {
            self.adminRef = directRef
        } else {
            let cap = signer.storage.copy<Capability<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>>(
                from: /storage/PrizeLinkedAccountsAdminConfigOps
            ) ?? panic("No ConfigOps access. Sign with deployer or run setup/claim_config_ops_capability.cdc first.")
            self.adminRef = cap.borrow()
                ?? panic("ConfigOps capability is invalid or has been revoked.")
        }
    }

    execute {
        self.adminRef.updatePoolMinimumDeposit(
            poolID: poolID,
            newMinimum: newMinimum
        )

        log("Minimum deposit updated for pool ".concat(poolID.toString())
            .concat(" to ").concat(newMinimum.toString()))
    }
}
