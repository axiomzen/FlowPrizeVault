import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Update Prize Distribution (Single Winner) - One winner takes the entire prize
///
/// Parameters:
/// - poolID: The pool ID to update
transaction(poolID: UInt64) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }

    execute {
        let newDistribution = PrizeLinkedAccounts.SingleWinnerPrize(nftIDs: [])

        self.adminRef.updatePoolPrizeDistribution(
            poolID: poolID,
            newDistribution: newDistribution
        )

        log("Updated pool ".concat(poolID.toString()).concat(" to SingleWinner"))
    }
}
