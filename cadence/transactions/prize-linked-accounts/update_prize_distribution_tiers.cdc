import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Update Prize Distribution (Fixed Tiers) - Multiple tiers with fixed amounts
///
/// Example tiers:
///   Tier 1 "Grand Prize": 1 winner gets 100.0 FLOW
///   Tier 2 "Runner Up": 2 winners each get 25.0 FLOW
///
/// Parameters are parallel arrays (same index = same tier):
/// - poolID: The pool ID to update
/// - tierAmounts: [100.0, 25.0] - prize amount per tier
/// - tierCounts: [1, 2] - number of winners per tier
/// - tierNames: ["Grand Prize", "Runner Up"] - display names
transaction(
    poolID: UInt64,
    tierAmounts: [UFix64],
    tierCounts: [Int],
    tierNames: [String]
) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Validate parallel arrays have same length
        assert(
            tierAmounts.length == tierCounts.length && tierCounts.length == tierNames.length,
            message: "Tier arrays must have the same length"
        )
        assert(tierAmounts.length > 0, message: "Must have at least one tier")

        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
    }

    execute {
        // Build prize tiers from parallel arrays
        var tiers: [PrizeLinkedAccounts.PrizeTier] = []
        var i = 0
        while i < tierAmounts.length {
            let tier = PrizeLinkedAccounts.PrizeTier(
                amount: tierAmounts[i],
                count: tierCounts[i],
                name: tierNames[i],
                nftIDs: []
            )
            tiers.append(tier)
            i = i + 1
        }

        let newDistribution = PrizeLinkedAccounts.FixedAmountTiers(tiers: tiers)

        self.adminRef.updatePoolPrizeDistribution(
            poolID: poolID,
            newDistribution: newDistribution
        )

        log("Updated pool ".concat(poolID.toString()).concat(" to FixedTiers with ").concat(tiers.length.toString()).concat(" tiers"))
    }
}
