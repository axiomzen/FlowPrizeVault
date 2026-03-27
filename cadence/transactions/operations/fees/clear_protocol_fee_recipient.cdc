import "PrizeLinkedAccounts"

/// Clear Protocol Fee Recipient (requires OwnerOnly — deployer account only).
///
/// Stops automatic fee forwarding. Protocol fees continue to accumulate in the
/// unclaimed vault and can be withdrawn later via fees/withdraw_protocol_fee.cdc.
///
/// Signer: deployer account ONLY (OwnerOnly cannot be delegated)
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("OwnerOnly access required — this transaction must be signed by the deployer account")
    }

    execute {
        self.adminRef.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: nil
        )

        log("Protocol fee recipient cleared for pool ".concat(poolID.toString()).concat(" — fees will accumulate in unclaimed vault"))
    }
}
