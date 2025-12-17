import PrizeSavings from "../../contracts/PrizeSavings.cdc"

/// Treasury statistics structure
/// Note: Treasury auto-forwards to recipient during reward processing, so there's no balance held
access(all) struct TreasuryStats {
    access(all) let totalForwarded: UFix64
    access(all) let recipient: Address?
    access(all) let hasRecipient: Bool
    
    init(
        totalForwarded: UFix64,
        recipient: Address?,
        hasRecipient: Bool
    ) {
        self.totalForwarded = totalForwarded
        self.recipient = recipient
        self.hasRecipient = hasRecipient
    }
}

/// Get treasury statistics for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: TreasuryStats struct with treasury information
access(all) fun main(poolID: UInt64): TreasuryStats {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return TreasuryStats(
        totalForwarded: poolRef.getTotalTreasuryForwarded(),
        recipient: poolRef.getTreasuryRecipient(),
        hasRecipient: poolRef.hasTreasuryRecipient()
    )
}

