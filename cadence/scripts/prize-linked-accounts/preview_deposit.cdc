import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Preview deposit information structure
access(all) struct DepositPreview {
    access(all) let depositAmount: UFix64
    access(all) let sharesReceived: UFix64
    access(all) let currentSharePrice: UFix64
    access(all) let minimumDeposit: UFix64
    access(all) let meetsMinimum: Bool
    
    init(
        depositAmount: UFix64,
        sharesReceived: UFix64,
        currentSharePrice: UFix64,
        minimumDeposit: UFix64,
        meetsMinimum: Bool
    ) {
        self.depositAmount = depositAmount
        self.sharesReceived = sharesReceived
        self.currentSharePrice = currentSharePrice
        self.minimumDeposit = minimumDeposit
        self.meetsMinimum = meetsMinimum
    }
}

/// Preview how many shares would be received for a deposit amount
/// This is useful for UI display before making a deposit
///
/// Parameters:
/// - poolID: The pool ID to query
/// - amount: The deposit amount to preview
///
/// Returns: DepositPreview struct with share calculation
access(all) fun main(poolID: UInt64, amount: UFix64): DepositPreview {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    let config = poolRef.getConfig()
    
    return DepositPreview(
        depositAmount: amount,
        sharesReceived: poolRef.previewDeposit(amount: amount),
        currentSharePrice: poolRef.getRewardsSharePrice(),
        minimumDeposit: config.minimumDeposit,
        meetsMinimum: amount >= config.minimumDeposit
    )
}

