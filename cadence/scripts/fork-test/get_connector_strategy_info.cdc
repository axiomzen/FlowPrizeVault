import "FlowYieldVaultsConnectorV2"

/// Fork-test: Query the V2 connector's strategy and vault type.
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

access(all) fun main(managerAddress: Address): ConnectorInfo {
    let account = getAccount(managerAddress)
    let managerRef = account.capabilities.borrow<&FlowYieldVaultsConnectorV2.YieldVaultManagerWrapper>(
        FlowYieldVaultsConnectorV2.ManagerPublicPath
    ) ?? panic("Cannot borrow V2 YieldVaultManagerWrapper from address")

    return ConnectorInfo(
        strategyType: managerRef.strategyType.identifier,
        vaultType: managerRef.vaultType.identifier,
        balance: managerRef.getYieldVaultBalance()
    )
}
