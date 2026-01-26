import "FungibleToken"
import "FlowToken"
import "PrizeLinkedAccounts"

/// Set the protocol fee recipient for a pool (requires OwnerOnly entitlement)
transaction(poolID: UInt64, recipientAddress: Address) {
    let admin: auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference with OwnerOnly entitlement")
    }

    execute {
        // Get the recipient's FLOW receiver capability
        let recipientCap = getAccount(recipientAddress)
            .capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)

        self.admin.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: recipientCap
        )
        log("Set protocol fee recipient to ".concat(recipientAddress.toString()))
    }
}
