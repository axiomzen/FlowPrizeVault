import Test

/// Unit tests for PrizeSavings shares model math
/// These tests verify the ERC4626-style accounting without requiring full contract deployment

// ============== SHARES MODEL MATH TESTS ==============

/// Simulates the shares model math to verify correctness
access(all) struct SharesModel {
    access(all) var totalShares: UFix64
    access(all) var totalAssets: UFix64
    access(all) var userShares: {String: UFix64}
    
    init() {
        self.totalShares = 0.0
        self.totalAssets = 0.0
        self.userShares = {}
    }
    
    access(all) fun deposit(_ user: String, _ amount: UFix64) {
        let shares = self.convertToShares(amount)
        self.userShares[user] = (self.userShares[user] ?? 0.0) + shares
        self.totalShares = self.totalShares + shares
        self.totalAssets = self.totalAssets + amount
    }
    
    access(all) fun withdraw(_ user: String, _ amount: UFix64): UFix64 {
        let userShareBal = self.userShares[user] ?? 0.0
        let sharesToBurn = (amount * self.totalShares) / self.totalAssets
        self.userShares[user] = userShareBal - sharesToBurn
        self.totalShares = self.totalShares - sharesToBurn
        self.totalAssets = self.totalAssets - amount
        return amount
    }
    
    access(all) fun distributeInterest(_ amount: UFix64) {
        // O(1) - just increase totalAssets, share price goes up
        self.totalAssets = self.totalAssets + amount
    }
    
    access(all) fun convertToShares(_ assets: UFix64): UFix64 {
        if self.totalShares == 0.0 || self.totalAssets == 0.0 {
            return assets  // 1:1 for first deposit
        }
        return (assets * self.totalShares) / self.totalAssets
    }
    
    access(all) fun convertToAssets(_ shares: UFix64): UFix64 {
        if self.totalShares == 0.0 {
            return 0.0
        }
        return (shares * self.totalAssets) / self.totalShares
    }
    
    access(all) fun getUserValue(_ user: String): UFix64 {
        let shares = self.userShares[user] ?? 0.0
        return self.convertToAssets(shares)
    }
    
    access(all) fun getSharePrice(): UFix64 {
        if self.totalShares == 0.0 { return 1.0 }
        return self.totalAssets / self.totalShares
    }
}

access(all) fun assertClose(_ actual: UFix64, _ expected: UFix64, _ tolerance: UFix64, _ msg: String) {
    let diff = actual > expected ? actual - expected : expected - actual
    Test.assert(diff <= tolerance, message: msg.concat(": expected ").concat(expected.toString()).concat(", got ").concat(actual.toString()))
}

// ============== TESTS ==============

access(all) fun testBasicDeposit() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    
    Test.assertEqual(model.totalShares, 100.0)
    Test.assertEqual(model.totalAssets, 100.0)
    Test.assertEqual(model.getUserValue("userA"), 100.0)
    
    log("✅ testBasicDeposit: First deposit mints 1:1 shares")
}

access(all) fun testInterestDistribution() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.distributeInterest(10.0)  // 10 FLOW interest
    
    // Shares unchanged, assets increased
    Test.assertEqual(model.totalShares, 100.0)
    Test.assertEqual(model.totalAssets, 110.0)
    
    // User value increased
    Test.assertEqual(model.getUserValue("userA"), 110.0)
    
    // Share price increased
    assertClose(model.getSharePrice(), 1.1, 0.0001, "Share price")
    
    log("✅ testInterestDistribution: O(1) interest increases share value")
}

access(all) fun testTwoUsersProportional() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)  // 100 shares
    model.deposit("userB", 200.0)  // 200 shares
    
    Test.assertEqual(model.totalShares, 300.0)
    Test.assertEqual(model.totalAssets, 300.0)
    
    // Distribute 30 FLOW interest
    model.distributeInterest(30.0)
    
    // User A: 100/300 = 33.3% → gets 10 FLOW
    // User B: 200/300 = 66.7% → gets 20 FLOW
    assertClose(model.getUserValue("userA"), 110.0, 0.01, "User A value")
    assertClose(model.getUserValue("userB"), 220.0, 0.01, "User B value")
    
    log("✅ testTwoUsersProportional: Interest distributed proportionally")
}

access(all) fun testLateJoinerFairness() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)  // 100 shares at price 1.0
    model.distributeInterest(10.0)  // totalAssets = 110
    
    // User B deposits 110 FLOW after interest
    model.deposit("userB", 110.0)  // Gets (110 * 100) / 110 = 100 shares
    
    Test.assertEqual(model.userShares["userB"]!, 100.0)
    Test.assertEqual(model.totalShares, 200.0)
    Test.assertEqual(model.totalAssets, 220.0)
    
    // Both have equal shares, equal value
    Test.assertEqual(model.getUserValue("userA"), 110.0)
    Test.assertEqual(model.getUserValue("userB"), 110.0)
    
    log("✅ testLateJoinerFairness: Late joiner doesn't get past interest")
}

access(all) fun testWithdrawal() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.distributeInterest(10.0)  // Value = 110
    
    // Withdraw 55 (half)
    model.withdraw("userA", 55.0)
    
    // Should have ~50 shares left
    assertClose(model.userShares["userA"]!, 50.0, 0.01, "Shares after withdrawal")
    assertClose(model.getUserValue("userA"), 55.0, 0.01, "Value after withdrawal")
    
    log("✅ testWithdrawal: Withdrawal burns proportional shares")
}

access(all) fun testWithdrawAll() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.distributeInterest(10.0)  // Value = 110
    
    // Withdraw all
    model.withdraw("userA", 110.0)
    
    assertClose(model.userShares["userA"]!, 0.0, 0.0001, "Shares should be 0")
    assertClose(model.totalShares, 0.0, 0.0001, "Total shares should be 0")
    assertClose(model.totalAssets, 0.0, 0.0001, "Total assets should be 0")
    
    log("✅ testWithdrawAll: Can withdraw full balance including interest")
}

access(all) fun testMultipleRounds() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    
    // Round 1: 10% yield
    model.distributeInterest(10.0)
    assertClose(model.getUserValue("userA"), 110.0, 0.01, "After round 1")
    
    // Round 2: ~10% yield on 110
    model.distributeInterest(11.0)
    assertClose(model.getUserValue("userA"), 121.0, 0.01, "After round 2")
    
    // Round 3: ~10% yield on 121
    model.distributeInterest(12.1)
    assertClose(model.getUserValue("userA"), 133.1, 0.01, "After round 3")
    
    log("✅ testMultipleRounds: Compound interest accumulates correctly")
}

access(all) fun testPrizeAsNewMoney() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.distributeInterest(10.0)  // Value = 110
    
    // User A wins 50 FLOW prize (treated as new deposit)
    model.deposit("userA", 50.0)  // Gets (50 * 100) / 110 ≈ 45.45 shares
    
    assertClose(model.userShares["userA"]!, 145.45, 0.1, "Shares after prize")
    assertClose(model.getUserValue("userA"), 160.0, 0.1, "Value after prize")
    
    log("✅ testPrizeAsNewMoney: Prize mints new shares correctly")
}

access(all) fun testInvariantTotalAssets() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.deposit("userB", 150.0)
    model.distributeInterest(25.0)
    
    // Sum of user values should equal totalAssets
    let sumValues = model.getUserValue("userA") + model.getUserValue("userB")
    assertClose(sumValues, model.totalAssets, 0.01, "Sum of values == totalAssets")
    
    log("✅ testInvariantTotalAssets: Sum of user values equals totalAssets")
}

access(all) fun testNoUnderflowOnFullWithdraw() {
    let model = SharesModel()
    
    model.deposit("userA", 100.0)
    model.deposit("userB", 200.0)
    model.distributeInterest(30.0)
    
    // User A withdraws all (110)
    model.withdraw("userA", 110.0)
    
    // User B should still have correct value
    assertClose(model.getUserValue("userB"), 220.0, 0.01, "User B value unchanged")
    Test.assert(model.totalAssets >= 0.0, message: "totalAssets should not underflow")
    Test.assert(model.totalShares >= 0.0, message: "totalShares should not underflow")
    
    log("✅ testNoUnderflowOnFullWithdraw: No underflow when user withdraws all")
}

// ============== MAIN ==============

access(all) fun main() {
    log("==========================================")
    log("🧪 PrizeSavings Shares Model Math Tests")
    log("==========================================")
    
    testBasicDeposit()
    testInterestDistribution()
    testTwoUsersProportional()
    testLateJoinerFairness()
    testWithdrawal()
    testWithdrawAll()
    testMultipleRounds()
    testPrizeAsNewMoney()
    testInvariantTotalAssets()
    testNoUnderflowOnFullWithdraw()
    
    log("==========================================")
    log("✅ All 10 tests passed!")
    log("==========================================")
}
