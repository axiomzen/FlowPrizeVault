import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Update Prize Distribution (Percentage Split) - Changes how prizes are split among winners
///
/// Example: [0.6, 0.4] = 2 winners getting 60% and 40% of prize
///          [0.5, 0.3, 0.2] = 3 winners getting 50%, 30%, 20%
///
/// Parameters:
/// - poolID: The pool ID to update
/// - prizeSplits: Array of percentages for each winner position (must sum to 1.0)
transaction(poolID: UInt64, prizeSplits: [UFix64]) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }

    execute {
        // Create percentage split prize distribution
        let newDistribution = PrizeLinkedAccounts.PercentageSplit(
            prizeSplits: prizeSplits,
            nftIDs: []  // No NFT prizes
        )

        self.adminRef.updatePoolPrizeDistribution(
            poolID: poolID,
            newDistribution: newDistribution
        )

        log("Updated pool ".concat(poolID.toString()).concat(" to PercentageSplit with ").concat(prizeSplits.length.toString()).concat(" winners"))
    }
}
