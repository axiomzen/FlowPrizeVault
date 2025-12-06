import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// User shares information structure
access(all) struct UserSharesInfo {
    access(all) let receiverID: UInt64
    access(all) let shares: UFix64
    access(all) let shareValue: UFix64
    access(all) let timeWeightedStake: UFix64
    access(all) let pendingSavingsInterest: UFix64
    access(all) let principalDeposits: UFix64
    access(all) let totalEarnedPrizes: UFix64
    access(all) let totalBalance: UFix64
    access(all) let bonusWeight: UFix64
    
    init(
        receiverID: UInt64,
        shares: UFix64,
        shareValue: UFix64,
        timeWeightedStake: UFix64,
        pendingSavingsInterest: UFix64,
        principalDeposits: UFix64,
        totalEarnedPrizes: UFix64,
        totalBalance: UFix64,
        bonusWeight: UFix64
    ) {
        self.receiverID = receiverID
        self.shares = shares
        self.shareValue = shareValue
        self.timeWeightedStake = timeWeightedStake
        self.pendingSavingsInterest = pendingSavingsInterest
        self.principalDeposits = principalDeposits
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
        .capabilities.borrow<&{PrizeSavings.PoolPositionCollectionPublic}>(
            PrizeSavings.PoolPositionCollectionPublicPath
        ) ?? panic("No collection found at address")
    
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Get the balance info which includes the receiverID implicitly through the collection
    let balance = collectionRef.getPoolBalance(poolID: poolID)
    
    // We need to get the receiverID - the collection's uuid
    // Since we can't directly access it, we'll use the pool's registered receivers
    let registeredIDs = poolRef.getRegisteredReceiverIDs()
    
    // Find the receiverID that matches this address by checking balances
    var receiverID: UInt64 = 0
    for id in registeredIDs {
        if poolRef.getReceiverDeposit(receiverID: id) == balance.deposits &&
           poolRef.getReceiverTotalEarnedPrizes(receiverID: id) == balance.totalEarnedPrizes {
            receiverID = id
            break
        }
    }
    
    if receiverID == 0 {
        // User not found in pool
        return UserSharesInfo(
            receiverID: 0,
            shares: 0.0,
            shareValue: 0.0,
            timeWeightedStake: 0.0,
            pendingSavingsInterest: 0.0,
            principalDeposits: 0.0,
            totalEarnedPrizes: 0.0,
            totalBalance: 0.0,
            bonusWeight: 0.0
        )
    }
    
    return UserSharesInfo(
        receiverID: receiverID,
        shares: poolRef.getUserSavingsShares(receiverID: receiverID),
        shareValue: poolRef.getUserSavingsValue(receiverID: receiverID),
        timeWeightedStake: poolRef.getUserTimeWeightedBalance(receiverID: receiverID),
        pendingSavingsInterest: poolRef.getPendingSavingsInterest(receiverID: receiverID),
        principalDeposits: poolRef.getReceiverDeposit(receiverID: receiverID),
        totalEarnedPrizes: poolRef.getReceiverTotalEarnedPrizes(receiverID: receiverID),
        totalBalance: poolRef.getReceiverTotalBalance(receiverID: receiverID),
        bonusWeight: poolRef.getBonusWeight(receiverID: receiverID)
    )
}

