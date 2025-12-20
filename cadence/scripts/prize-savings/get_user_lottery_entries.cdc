import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Lottery entries (share-seconds) information for a user
access(all) struct UserLotteryEntries {
    access(all) let receiverID: UInt64
    access(all) let currentBalance: UFix64
    access(all) let projectedEntries: UFix64
    access(all) let bonusWeight: UFix64
    access(all) let scaledBonusAtDraw: UFix64
    access(all) let totalWeightAtDraw: UFix64
    access(all) let roundID: UInt64
    access(all) let roundStartTime: UFix64
    access(all) let roundElapsedSeconds: UFix64
    access(all) let secondsUntilDraw: UFix64
    access(all) let roundEndTime: UFix64
    access(all) let isRoundEnded: Bool
    
    init(
        receiverID: UInt64,
        currentBalance: UFix64,
        projectedEntries: UFix64,
        bonusWeight: UFix64,
        scaledBonusAtDraw: UFix64,
        totalWeightAtDraw: UFix64,
        roundID: UInt64,
        roundStartTime: UFix64,
        roundElapsedSeconds: UFix64,
        secondsUntilDraw: UFix64,
        roundEndTime: UFix64,
        isRoundEnded: Bool
    ) {
        self.receiverID = receiverID
        self.currentBalance = currentBalance
        self.projectedEntries = projectedEntries
        self.bonusWeight = bonusWeight
        self.scaledBonusAtDraw = scaledBonusAtDraw
        self.totalWeightAtDraw = totalWeightAtDraw
        self.roundID = roundID
        self.roundStartTime = roundStartTime
        self.roundElapsedSeconds = roundElapsedSeconds
        self.secondsUntilDraw = secondsUntilDraw
        self.roundEndTime = roundEndTime
        self.isRoundEnded = isRoundEnded
    }
}

/// Get lottery entries (share-seconds) information for a user
///
/// Parameters:
/// - address: The account address
/// - poolID: The pool ID to query
///
/// Returns: UserLotteryEntries struct with current and projected lottery weight
access(all) fun main(address: Address, poolID: UInt64): UserLotteryEntries {
    // Get the user's collection
    let collectionRef = getAccount(address)
        .capabilities.borrow<&PrizeSavings.PoolPositionCollection>(
            PrizeSavings.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found at address")
    
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get balance info to find the receiverID
    let balance = collectionRef.getPoolBalance(poolID: poolID)
    let registeredIDs = poolRef.getRegisteredReceiverIDs()
    
    // Find the receiverID by matching deposits
    var receiverID: UInt64 = 0
    for id in registeredIDs {
        if poolRef.getReceiverDeposit(receiverID: id) == balance.deposits &&
           poolRef.getReceiverTotalEarnedPrizes(receiverID: id) == balance.totalEarnedPrizes {
            receiverID = id
            break
        }
    }
    
    if receiverID == 0 {
        return UserLotteryEntries(
            receiverID: 0,
            currentBalance: 0.0,
            projectedEntries: 0.0,
            bonusWeight: 0.0,
            scaledBonusAtDraw: 0.0,
            totalWeightAtDraw: 0.0,
            roundID: poolRef.getCurrentRoundID(),
            roundStartTime: poolRef.getRoundStartTime(),
            roundElapsedSeconds: poolRef.getRoundElapsedTime(),
            secondsUntilDraw: 0.0,
            roundEndTime: poolRef.getRoundEndTime(),
            isRoundEnded: poolRef.isRoundEnded()
        )
    }
    
    let roundStartTime = poolRef.getRoundStartTime()
    let roundDuration = poolRef.getRoundDuration()
    let roundEndTime = poolRef.getRoundEndTime()
    let secondsUntilDraw = poolRef.getTimeUntilNextDraw()
    
    // Current lottery entries (projected share-seconds)
    let currentBalance = poolRef.getReceiverTotalBalance(receiverID: receiverID)
    
    // Projected entries at draw time (normalized by round duration)
    let projectedEntries = poolRef.getUserEntries(receiverID: receiverID)
    
    // Get raw TWAB for bonus calculation
    let projectedTwab = poolRef.getUserTimeWeightedShares(receiverID: receiverID)
    
    // Bonus weight info
    let bonusWeight = poolRef.getBonusWeight(receiverID: receiverID)
    let scaledBonusAtDraw = bonusWeight * roundDuration
    let totalWeightAtDraw = projectedTwab + scaledBonusAtDraw
    
    return UserLotteryEntries(
        receiverID: receiverID,
        currentBalance: currentBalance,
        projectedEntries: projectedEntries,
        bonusWeight: bonusWeight,
        scaledBonusAtDraw: scaledBonusAtDraw,
        totalWeightAtDraw: totalWeightAtDraw,
        roundID: poolRef.getCurrentRoundID(),
        roundStartTime: roundStartTime,
        roundElapsedSeconds: poolRef.getRoundElapsedTime(),
        secondsUntilDraw: secondsUntilDraw,
        roundEndTime: roundEndTime,
        isRoundEnded: poolRef.isRoundEnded()
    )
}
