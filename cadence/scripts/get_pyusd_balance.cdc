import FungibleToken from 0xf233dcee88fe0abe
import FungibleTokenMetadataViews from 0xf233dcee88fe0abe
import EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750 from 0x1e4aa0b87d10b141

/// Query the pyUSD balance of an account
///
/// Parameters:
/// - address: The account address to query
///
/// Returns: The pyUSD balance (UFix64)
access(all) fun main(address: Address): UFix64 {
    let vaultData = EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.resolveContractView(
        resourceType: nil,
        viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
    ) as! FungibleTokenMetadataViews.FTVaultData?
        ?? panic("Could not resolve FTVaultData for pyUSD")

    let balanceRef = getAccount(address)
        .capabilities.borrow<&{FungibleToken.Balance}>(vaultData.metadataPath)
        ?? panic("No pyUSD vault found at address. Run setup_pyusd_vault.cdc first.")

    return balanceRef.balance
}
