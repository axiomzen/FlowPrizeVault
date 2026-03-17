import "PrizeLinkedAccounts"

/// Per-user stats for a pool
access(all) struct UserStats {
    access(all) let receiverID: UInt64
    access(all) let address: Address?
    access(all) let shares: UFix64
    access(all) let shareValue: UFix64
    access(all) let totalBalance: UFix64
    access(all) let totalEarnedPrizes: UFix64
    access(all) let entries: UFix64
    access(all) let timeWeightedShares: UFix64
    access(all) let bonusWeight: UFix64
    access(all) let isSponsor: Bool

    init(
        receiverID: UInt64,
        address: Address?,
        shares: UFix64,
        shareValue: UFix64,
        totalBalance: UFix64,
        totalEarnedPrizes: UFix64,
        entries: UFix64,
        timeWeightedShares: UFix64,
        bonusWeight: UFix64,
        isSponsor: Bool
    ) {
        self.receiverID = receiverID
        self.address = address
        self.shares = shares
        self.shareValue = shareValue
        self.totalBalance = totalBalance
        self.totalEarnedPrizes = totalEarnedPrizes
        self.entries = entries
        self.timeWeightedShares = timeWeightedShares
        self.bonusWeight = bonusWeight
        self.isSponsor = isSponsor
    }
}

/// Get stats for all users registered in a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: Array of UserStats for every registered receiver
access(all) fun main(poolID: UInt64): [UserStats] {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")

    let receiverIDs = poolRef.getRegisteredReceiverIDs()
    let results: [UserStats] = []

    for receiverID in receiverIDs {
        let address = poolRef.getReceiverOwnerAddress(receiverID: receiverID)
        let isSponsor = poolRef.isSponsor(receiverID: receiverID)

        results.append(UserStats(
            receiverID: receiverID,
            address: address,
            shares: poolRef.getUserRewardsShares(receiverID: receiverID),
            shareValue: poolRef.getUserRewardsValue(receiverID: receiverID),
            totalBalance: poolRef.getReceiverTotalBalance(receiverID: receiverID),
            totalEarnedPrizes: poolRef.getReceiverTotalEarnedPrizes(receiverID: receiverID),
            entries: poolRef.getUserEntries(receiverID: receiverID),
            timeWeightedShares: poolRef.getUserTimeWeightedShares(receiverID: receiverID),
            bonusWeight: poolRef.getBonusWeight(receiverID: receiverID),
            isSponsor: isSponsor
        ))
    }

    return results
}
