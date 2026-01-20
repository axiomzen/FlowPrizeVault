import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// User shares information structure
access(all) struct UserSharesInfo {
    access(all) let receiverID: UInt64
    access(all) let shares: UFix64
    access(all) let shareValue: UFix64
    access(all) let timeWeightedStake: UFix64
    access(all) let totalEarnedPrizes: UFix64
    access(all) let totalBalance: UFix64
    access(all) let bonusWeight: UFix64
    
    init(
        receiverID: UInt64,
        shares: UFix64,
        shareValue: UFix64,
        timeWeightedStake: UFix64,
        totalEarnedPrizes: UFix64,
        totalBalance: UFix64,
        bonusWeight: UFix64
    ) {
        self.receiverID = receiverID
        self.shares = shares
        self.shareValue = shareValue
        self.timeWeightedStake = timeWeightedStake
        self.totalEarnedPrizes = totalEarnedPrizes
        self.totalBalance = totalBalance
        self.bonusWeight = bonusWeight
    }
}

/// Get detailed shares information for a user in a pool
///
/// Parameters:
/// - address: The account address
/// - poolID: The pool ID to query
///
/// Returns: UserSharesInfo struct with detailed share information
access(all) fun main(address: Address, poolID: UInt64): UserSharesInfo {
    // Get the user's collection to find their receiverID
    let collectionRef = getAccount(address)
        .capabilities.borrow<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found at address")
    
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get the balance info
    let balance = collectionRef.getPoolBalance(poolID: poolID)
    
    // Get receiverID from the collection
    let receiverID = collectionRef.getReceiverID()
    
    // Check if user is registered in pool
    let registeredIDs = poolRef.getRegisteredReceiverIDs()
    var isRegistered = false
    for id in registeredIDs {
        if id == receiverID {
            isRegistered = true
            break
        }
    }
    
    if !isRegistered {
        // User not found in pool
        return UserSharesInfo(
            receiverID: 0,
            shares: 0.0,
            shareValue: 0.0,
            timeWeightedStake: 0.0,
            totalEarnedPrizes: 0.0,
            totalBalance: 0.0,
            bonusWeight: 0.0
        )
    }
    
    return UserSharesInfo(
        receiverID: receiverID,
        shares: poolRef.getUserRewardsShares(receiverID: receiverID),
        shareValue: poolRef.getUserSavingsValue(receiverID: receiverID),
        timeWeightedStake: poolRef.getUserTimeWeightedShares(receiverID: receiverID),
        totalEarnedPrizes: poolRef.getReceiverTotalEarnedPrizes(receiverID: receiverID),
        totalBalance: poolRef.getReceiverTotalBalance(receiverID: receiverID),
        bonusWeight: poolRef.getBonusWeight(receiverID: receiverID)
    )
}
