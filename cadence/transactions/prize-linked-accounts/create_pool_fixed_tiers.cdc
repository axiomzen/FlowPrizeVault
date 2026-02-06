import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import MockYieldConnector from "../../contracts/mock/MockYieldConnector.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Create Pool (Fixed Tiers) - Creates a pool with multiple prize tiers
///
/// PREREQUISITE: Run setup_test_yield_vault.cdc first to create the yield vault.
///
/// Example tiers:
///   Tier 1 "Grand Prize": 1 winner gets 100.0 FLOW
///   Tier 2 "Runner Up": 2 winners each get 25.0 FLOW
///   Tier 3 "Consolation": 5 winners each get 5.0 FLOW
///
/// Parameters are parallel arrays (same index = same tier):
/// - tierAmounts: [100.0, 25.0, 5.0]
/// - tierCounts: [1, 2, 5]
/// - tierNames: ["Grand Prize", "Runner Up", "Consolation"]
///
/// This transaction uses MockYieldConnector for testing/staging.
/// For production, create a separate transaction with a real yield connector.
///
/// Parameters:
/// - minimumDeposit: Minimum deposit amount required (UFix64)
/// - drawIntervalSeconds: Time between prize draws (UFix64)
/// - rewardsPercent: Percentage of yield to savings interest (UFix64)
/// - prizePercent: Percentage of yield to prize pool (UFix64)
/// - protocolFeePercent: Percentage of yield to protocol treasury (UFix64)
/// - tierAmounts: Array of prize amounts for each tier (UFix64[])
/// - tierCounts: Array of winner counts for each tier (Int[])
/// - tierNames: Array of tier names (String[])
/// - yieldVaultPath: Storage path identifier for yield vault (String)
transaction(
    minimumDeposit: UFix64,
    drawIntervalSeconds: UFix64,
    rewardsPercent: UFix64,
    prizePercent: UFix64,
    protocolFeePercent: UFix64,
    tierAmounts: [UFix64],
    tierCounts: [Int],
    tierNames: [String],
    yieldVaultPath: String
) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin
    let treasuryReceiverCap: Capability<&{FungibleToken.Receiver}>
    let providerCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
    let receiverCap: Capability<&FlowToken.Vault>

    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Validate parallel arrays have same length
        assert(
            tierAmounts.length == tierCounts.length && tierCounts.length == tierNames.length,
            message: "Tier arrays must have the same length"
        )
        assert(tierAmounts.length > 0, message: "Must have at least one tier")

        // Borrow the Admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps, PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found. Only the contract deployer can create pools.")

        // Get the signer's FlowToken receiver for treasury
        self.treasuryReceiverCap = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        assert(self.treasuryReceiverCap.check(), message: "Signer must have a valid FlowToken receiver at /public/flowTokenReceiver")

        // Build the storage path from the identifier
        let storagePath = StoragePath(identifier: yieldVaultPath)
            ?? panic("Invalid storage path identifier: ".concat(yieldVaultPath))

        // Verify vault exists - MUST run setup_test_yield_vault.cdc first
        if signer.storage.type(at: storagePath) == nil {
            panic("Yield vault not found at /storage/".concat(yieldVaultPath).concat(". Run setup_test_yield_vault.cdc first."))
        }

        // Get existing capability controllers for this path
        let controllers = signer.capabilities.storage.getControllers(forPath: storagePath)

        // Find existing provider and receiver capabilities, or issue new ones if needed
        var foundProvider: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>? = nil
        var foundReceiver: Capability<&FlowToken.Vault>? = nil

        for controller in controllers {
            // Check if this controller's capability type matches what we need
            let capType = controller.borrowType

            // Try to use as provider capability (needs Withdraw entitlement)
            if foundProvider == nil {
                if let cap = controller.capability as? Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault> {
                    if cap.check() {
                        foundProvider = cap
                    }
                }
            }
            // Try to use as receiver capability
            if foundReceiver == nil {
                if let cap = controller.capability as? Capability<&FlowToken.Vault> {
                    if cap.check() {
                        foundReceiver = cap
                    }
                }
            }
        }

        // Use existing capabilities or issue new ones
        self.providerCap = foundProvider ?? signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(storagePath)
        self.receiverCap = foundReceiver ?? signer.capabilities.storage.issue<&FlowToken.Vault>(storagePath)
    }

    execute {
        // Create the yield connector using MockYieldConnector
        let yieldConnector = MockYieldConnector.createSimpleVaultConnector(
            providerCap: self.providerCap,
            receiverCap: self.receiverCap,
            vaultType: Type<@FlowToken.Vault>()
        )

        // Create distribution strategy
        let distributionStrategy = PrizeLinkedAccounts.FixedPercentageStrategy(
            rewards: rewardsPercent,
            prize: prizePercent,
            protocolFee: protocolFeePercent
        )

        // Build prize tiers from parallel arrays
        var tiers: [PrizeLinkedAccounts.PrizeTier] = []
        var i = 0
        while i < tierAmounts.length {
            let tier = PrizeLinkedAccounts.PrizeTier(
                amount: tierAmounts[i],
                count: tierCounts[i],
                name: tierNames[i],
                nftIDs: []  // No NFT prizes by default
            )
            tiers.append(tier)
            i = i + 1
        }

        // Create fixed tiers prize distribution
        let prizeDistribution = PrizeLinkedAccounts.FixedAmountTiers(
            tiers: tiers
        )

        // Create pool config
        let config = PrizeLinkedAccounts.PoolConfig(
            assetType: Type<@FlowToken.Vault>(),
            yieldConnector: yieldConnector,
            minimumDeposit: minimumDeposit,
            drawIntervalSeconds: drawIntervalSeconds,
            distributionStrategy: distributionStrategy,
            prizeDistribution: prizeDistribution,
            winnerTrackerCap: nil
        )

        // Create the pool
        let poolID = self.adminRef.createPool(
            config: config,
            emergencyConfig: nil
        )

        // Set the treasury recipient to the pool creator
        self.adminRef.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: self.treasuryReceiverCap
        )

        log("Created FixedTiers pool with ID: ".concat(poolID.toString()))
        log("Tier count: ".concat(tiers.length.toString()))
    }
}
