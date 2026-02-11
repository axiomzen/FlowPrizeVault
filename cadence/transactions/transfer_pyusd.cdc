import FungibleToken from 0xf233dcee88fe0abe
import FungibleTokenMetadataViews from 0xf233dcee88fe0abe
import EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750 from 0x1e4aa0b87d10b141

/// Transfer pyUSD tokens from the signer to a recipient
///
/// Parameters:
/// - recipient: The address to send pyUSD tokens to
/// - amount: The amount of pyUSD to send
transaction(recipient: Address, amount: UFix64) {

    let senderVault: auth(FungibleToken.Withdraw) &EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(Storage) &Account) {
        // Resolve vault paths from the token contract's metadata
        let vaultData = EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.resolveContractView(
            resourceType: nil,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData for pyUSD")

        // Borrow the sender's vault with withdraw entitlement
        self.senderVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault>(
            from: vaultData.storagePath
        ) ?? panic("Could not borrow sender's pyUSD vault. Does the sender have a pyUSD vault?")

        // Borrow the recipient's receiver capability
        self.receiverRef = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(vaultData.receiverPath)
            ?? panic("Could not borrow receiver's pyUSD receiver. Does the recipient have a pyUSD vault set up?")
    }

    execute {
        let tokens <- self.senderVault.withdraw(amount: amount)
        self.receiverRef.deposit(from: <- tokens)

        log("Transferred ".concat(amount.toString()).concat(" pyUSD to ").concat(recipient.toString()))
    }
}
