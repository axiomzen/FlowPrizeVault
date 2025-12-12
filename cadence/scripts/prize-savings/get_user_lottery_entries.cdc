import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Lottery entries (balance-seconds) information for a user
access(all) struct UserLotteryEntries {
    access(all) let receiverID: UInt64
    access(all) let currentBalance: UFix64
    access(all) let currentEntries: UFix64
    access(all) let projectedEntriesAtDraw: UFix64
    access(all) let bonusWeight: UFix64
    access(all) let scaledBonusAtDraw: UFix64
    access(all) let totalWeightAtDraw: UFix64
    access(all) let epochID: UInt64
    access(all) let epochStartTime: UFix64
    access(all) let epochElapsedSeconds: UFix64
    access(all) let secondsUntilDraw: UFix64
    access(all) let nextDrawTime: UFix64
    
    init(
        receiverID: UInt64,
        currentBalance: UFix64,
        currentEntries: UFix64,
        projectedEntriesAtDraw: UFix64,
        bonusWeight: UFix64,
        scaledBonusAtDraw: UFix64,
        totalWeightAtDraw: UFix64,
        epochID: UInt64,
        epochStartTime: UFix64,
        epochElapsedSeconds: UFix64,
        secondsUntilDraw: UFix64,
        nextDrawTime: UFix64
    ) {
        self.receiverID = receiverID
        self.currentBalance = currentBalance
        self.currentEntries = currentEntries
        self.projectedEntriesAtDraw = projectedEntriesAtDraw
        self.bonusWeight = bonusWeight
        self.scaledBonusAtDraw = scaledBonusAtDraw
        self.totalWeightAtDraw = totalWeightAtDraw
        self.epochID = epochID
        self.epochStartTime = epochStartTime
        self.epochElapsedSeconds = epochElapsedSeconds
        self.secondsUntilDraw = secondsUntilDraw
        self.nextDrawTime = nextDrawTime
    }
}

/// Get lottery entries (balance-seconds) information for a user
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
            currentEntries: 0.0,
            projectedEntriesAtDraw: 0.0,
            bonusWeight: 0.0,
            scaledBonusAtDraw: 0.0,
            totalWeightAtDraw: 0.0,
            epochID: poolRef.getCurrentEpochID(),
            epochStartTime: poolRef.getEpochStartTime(),
            epochElapsedSeconds: poolRef.getEpochElapsedTime(),
            secondsUntilDraw: 0.0,
            nextDrawTime: 0.0
        )
    }
    
    let config = poolRef.getConfig()
    let now = getCurrentBlock().timestamp
    let epochStartTime = poolRef.getEpochStartTime()
    let epochElapsedSeconds = poolRef.getEpochElapsedTime()
    
    // Calculate next draw time
    let lastDraw = poolRef.lastDrawTimestamp
    let nextDrawTime = lastDraw + config.drawIntervalSeconds
    let secondsUntilDraw = nextDrawTime > now ? nextDrawTime - now : 0.0
    
    // Current lottery entries (balance-seconds)
    let currentEntries = poolRef.getUserTimeWeightedBalance(receiverID: receiverID)
    let currentBalance = poolRef.getReceiverTotalBalance(receiverID: receiverID)
    
    // Projected entries at draw time
    let projectedEntries = poolRef.getUserProjectedBalanceSeconds(receiverID: receiverID, atTime: nextDrawTime)
    
    // Bonus weight info
    let bonusWeight = poolRef.getBonusWeight(receiverID: receiverID)
    let epochDurationAtDraw = nextDrawTime - epochStartTime
    let scaledBonusAtDraw = bonusWeight * epochDurationAtDraw
    let totalWeightAtDraw = projectedEntries + scaledBonusAtDraw
    
    return UserLotteryEntries(
        receiverID: receiverID,
        currentBalance: currentBalance,
        currentEntries: currentEntries,
        projectedEntriesAtDraw: projectedEntries,
        bonusWeight: bonusWeight,
        scaledBonusAtDraw: scaledBonusAtDraw,
        totalWeightAtDraw: totalWeightAtDraw,
        epochID: poolRef.getCurrentEpochID(),
        epochStartTime: epochStartTime,
        epochElapsedSeconds: epochElapsedSeconds,
        secondsUntilDraw: secondsUntilDraw,
        nextDrawTime: nextDrawTime
    )
}
