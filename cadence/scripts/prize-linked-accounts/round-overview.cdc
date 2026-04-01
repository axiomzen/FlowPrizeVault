// flow scripts execute cadence/scripts/prize-linked-accounts/get_current_round_odds_mainnet.cdc 1 --network mainnet

import PrizeLinkedAccounts from 0xa092c4aab33daeda

/// Per-user lottery odds for the current round.
/// Only lottery-eligible users (non-sponsors) are included; odds sum to 1e6 (100%).
access(all) struct UserOdds {
    access(all) let receiverID: UInt64
    access(all) let ownerAddress: Address?
    access(all) let shares: UFix64
    access(all) let balance: UFix64
    access(all) let entries: UFix64
    access(all) let bonusWeight: UFix64
    access(all) let totalWeight: UFix64
    /// Odds in parts per million (e.g. 50_000 = 5%)
    access(all) let oddsPartsPerMillion: UFix64
    /// Odds as percentage (0.0–100.0). Same as oddsPartsPerMillion / 10_000.
    access(all) let oddsPercent: UFix64
    /// entries / balance ratio (0.0–1.0). Indicates how much of the round the user has been deposited for.
    /// Early depositors match round progress (~0.45 at 45% of round); late depositors are lower.
    access(all) let entriesPerBalance: UFix64

    init(
        receiverID: UInt64,
        ownerAddress: Address?,
        shares: UFix64,
        balance: UFix64,
        entries: UFix64,
        bonusWeight: UFix64,
        totalWeight: UFix64,
        oddsPartsPerMillion: UFix64,
        oddsPercent: UFix64,
        entriesPerBalance: UFix64
    ) {
        self.receiverID = receiverID
        self.ownerAddress = ownerAddress
        self.shares = shares
        self.balance = balance
        self.entries = entries
        self.bonusWeight = bonusWeight
        self.totalWeight = totalWeight
        self.oddsPartsPerMillion = oddsPartsPerMillion
        self.oddsPercent = oddsPercent
        self.entriesPerBalance = entriesPerBalance
    }
}

access(all) struct CurrentRoundOddsResult {
    access(all) let poolID: UInt64
    access(all) let roundID: UInt64
    access(all) let roundEndTime: UFix64
    access(all) let totalPoolWeight: UFix64
    access(all) let userCount: Int
    access(all) let users: [UserOdds]

    init(
        poolID: UInt64,
        roundID: UInt64,
        roundEndTime: UFix64,
        totalPoolWeight: UFix64,
        userCount: Int,
        users: [UserOdds]
    ) {
        self.poolID = poolID
        self.roundID = roundID
        self.roundEndTime = roundEndTime
        self.totalPoolWeight = totalPoolWeight
        self.userCount = userCount
        self.users = users
    }
}

/// Returns current round lottery odds per user (lottery-eligible only).
/// Odds are based on projected TWAB entries + bonus weight; sponsors are excluded.
///
/// Parameters:
/// - poolID: The pool ID
///
/// Returns: CurrentRoundOddsResult with totalPoolWeight and per-user odds (parts per million).
access(all) fun main(poolID: UInt64): CurrentRoundOddsResult {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    let roundID = poolRef.getCurrentRoundID()
    let roundEndTime = poolRef.getRoundEndTime()

    let receiverIDs = poolRef.getRegisteredReceiverIDs()

    // First pass: collect lottery-eligible users and their weights; compute total weight
    var totalPoolWeight: UFix64 = 0.0
    var lotteryUsers: [UserOdds] = []

    for receiverID in receiverIDs {
        if poolRef.isSponsor(receiverID: receiverID) {
            continue
        }
        let shares = poolRef.getUserRewardsShares(receiverID: receiverID)
        let balance = poolRef.getReceiverTotalBalance(receiverID: receiverID)
        let entries = poolRef.getUserEntries(receiverID: receiverID)
        let bonusWeight = poolRef.getBonusWeight(receiverID: receiverID)
        let totalWeight = entries + bonusWeight
        totalPoolWeight = totalPoolWeight + totalWeight
        let entriesPerBalance = balance > 0.0 ? entries / balance : 0.0
        lotteryUsers.append(UserOdds(
            receiverID: receiverID,
            ownerAddress: poolRef.getReceiverOwnerAddress(receiverID: receiverID),
            shares: shares,
            balance: balance,
            entries: entries,
            bonusWeight: bonusWeight,
            totalWeight: totalWeight,
            oddsPartsPerMillion: 0.0,
            oddsPercent: 0.0,
            entriesPerBalance: entriesPerBalance
        ))
    }

    // Second pass: set odds (parts per million) using totalPoolWeight
    let total = totalPoolWeight
    var result: [UserOdds] = []
    if total > 0.0 {
        for u in lotteryUsers {
            let partsPerMillion = (u.totalWeight * 1_000_000.0) / total
            let oddsPercent = partsPerMillion / 10_000.0
            result.append(UserOdds(
                receiverID: u.receiverID,
                ownerAddress: u.ownerAddress,
                shares: u.shares,
                balance: u.balance,
                entries: u.entries,
                bonusWeight: u.bonusWeight,
                totalWeight: u.totalWeight,
                oddsPartsPerMillion: partsPerMillion,
                oddsPercent: oddsPercent,
                entriesPerBalance: u.entriesPerBalance
            ))
        }
    } else {
        result = lotteryUsers
    }

    return CurrentRoundOddsResult(
        poolID: poolID,
        roundID: roundID,
        roundEndTime: roundEndTime,
        totalPoolWeight: totalPoolWeight,
        userCount: result.length,
        users: result
    )
}