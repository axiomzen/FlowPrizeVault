import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// User shares information structure
access(all) struct UserSharesInfo {
    access(all) let userAddress: Address
    access(all) let shares: UFix64
    access(all) let shareValue: UFix64
    access(all) let timeWeightedStake: UFix64
    access(all) let totalEarnedPrizes: UFix64
    access(all) let totalBalance: UFix64
    access(all) let bonusWeight: UFix64
    
    init(
        userAddress: Address,
        shares: UFix64,
        shareValue: UFix64,
        timeWeightedStake: UFix64,
        totalEarnedPrizes: UFix64,
        totalBalance: UFix64,
        bonusWeight: UFix64
    ) {
        self.userAddress = userAddress
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
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    // Check if user is registered in pool
    if !poolRef.isUserRegistered(userAddress: address) {
        // User not found in pool
        return UserSharesInfo(
            userAddress: address,
            shares: 0.0,
            shareValue: 0.0,
            timeWeightedStake: 0.0,
            totalEarnedPrizes: 0.0,
            totalBalance: 0.0,
            bonusWeight: 0.0
        )
    }
    
    return UserSharesInfo(
        userAddress: address,
        shares: poolRef.getUserSavingsShares(userAddress: address),
        shareValue: poolRef.getUserSavingsValue(userAddress: address),
        timeWeightedStake: poolRef.getUserTimeWeightedShares(userAddress: address),
        totalEarnedPrizes: poolRef.getUserTotalEarnedPrizes(userAddress: address),
        totalBalance: poolRef.getUserTotalBalance(userAddress: address),
        bonusWeight: poolRef.getBonusWeight(userAddress: address)
    )
}
