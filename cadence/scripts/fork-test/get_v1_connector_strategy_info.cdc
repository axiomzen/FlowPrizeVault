import FlowYieldVaultsConnector from 0xa092c4aab33daeda

/// Fork-test: Query the V1 connector's strategy and vault type (used by PrizeSavings).
/// Uses hardcoded address import since V1 connector has no flow.json alias.
///
/// The strategyType tells us whether it uses ERC4626 or AMM-based yield.
///
/// Look for these patterns in the output:
///   - "ERC4626VaultStrategy" → uses ERC4626 vault (direct deposit/redeem, 6-decimal truncation applies)
///   - Other strategy types → may use AMM swaps (Uniswap V3) instead
access(all) struct ConnectorInfo {
    access(all) let strategyType: String
    access(all) let vaultType: String
    access(all) let balance: UFix64

    init(strategyType: String, vaultType: String, balance: UFix64) {
        self.strategyType = strategyType
        self.vaultType = vaultType
        self.balance = balance
    }
}

access(all) fun main(): ConnectorInfo {
    let account = getAccount(0xa092c4aab33daeda)
    let managerRef = account.capabilities.borrow<&FlowYieldVaultsConnector.YieldVaultManagerWrapper>(
        FlowYieldVaultsConnector.ManagerPublicPath
    ) ?? panic("Cannot borrow V1 YieldVaultManagerWrapper from address")

    return ConnectorInfo(
        strategyType: managerRef.strategyType.identifier,
        vaultType: managerRef.vaultType.identifier,
        balance: managerRef.getYieldVaultBalance()
    )
}
