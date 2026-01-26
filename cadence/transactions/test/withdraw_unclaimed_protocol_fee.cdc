import "FungibleToken"
import "FlowToken"
import "PrizeLinkedAccounts"

/// Withdraw unclaimed protocol fee from a pool
transaction(poolID: UInt64, amount: UFix64, recipientAddress: Address) {
    let admin: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference with CriticalOps entitlement")
    }

    execute {
        // Get the recipient's FLOW receiver capability
        let recipientCap = getAccount(recipientAddress)
            .capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)

        let actualAmount = self.admin.withdrawUnclaimedProtocolFee(
            poolID: poolID,
            amount: amount,
            recipient: recipientCap
        )
        log("Withdrew ".concat(actualAmount.toString()).concat(" protocol fee to ").concat(recipientAddress.toString()))
    }
}
