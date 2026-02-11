import FungibleToken from 0xf233dcee88fe0abe
import FungibleTokenMetadataViews from 0xf233dcee88fe0abe
import EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750 from 0x1e4aa0b87d10b141

/// Set up a pyUSD vault on the signer's account.
/// Creates an empty vault, saves it to storage, and publishes receiver + balance capabilities.
transaction {

    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Resolve vault paths from the token contract's metadata
        let vaultData = EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.resolveContractView(
            resourceType: nil,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData for pyUSD")

        // Check if vault already exists
        if signer.storage.borrow<&EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault>(from: vaultData.storagePath) != nil {
            log("pyUSD vault already set up")
            return
        }

        // Create and save an empty vault
        let vault <- EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.createEmptyVault(vaultType: Type<@EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault>())
        signer.storage.save(<-vault, to: vaultData.storagePath)

        // Publish receiver capability
        let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultData.storagePath)
        signer.capabilities.publish(receiverCap, at: vaultData.receiverPath)

        // Publish balance capability
        let balanceCap = signer.capabilities.storage.issue<&{FungibleToken.Balance}>(vaultData.storagePath)
        signer.capabilities.publish(balanceCap, at: vaultData.metadataPath)

        log("pyUSD vault set up successfully")
    }
}
