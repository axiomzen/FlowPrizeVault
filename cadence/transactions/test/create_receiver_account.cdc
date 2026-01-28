import "FungibleToken"
import "FlowToken"
import "PrizeLinkedAccounts"

/// Creates a new account with a PoolPositionCollection and deposits into a pool.
/// Each new account = 1 new unique receiver in the lottery.
///
/// The admin/payer pays for account creation and initial funding.
transaction(poolID: UInt64, depositAmount: UFix64, accountKey: String) {
    
    prepare(payer: auth(Storage, BorrowValue) &Account) {
        // Create a new account - payer covers creation cost
        let newAccount = Account(payer: payer)
        
        // Add a key to the new account (required for it to be usable)
        let key = PublicKey(
            publicKey: accountKey.decodeHex(),
            signatureAlgorithm: SignatureAlgorithm.ECDSA_P256
        )
        newAccount.keys.add(
            publicKey: key,
            hashAlgorithm: HashAlgorithm.SHA3_256,
            weight: 1000.0
        )
        
        // Set up FlowToken vault for the new account
        let vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        newAccount.storage.save(<-vault, to: /storage/flowTokenVault)
        
        // Create capabilities for the new account's vault
        let receiverCap = newAccount.capabilities.storage.issue<&{FungibleToken.Receiver}>(
            /storage/flowTokenVault
        )
        newAccount.capabilities.publish(receiverCap, at: /public/flowTokenReceiver)
        
        // Fund the new account from payer
        let payerVault = payer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow payer's vault")
        
        let funding <- payerVault.withdraw(amount: depositAmount + 0.1)
        
        // Deposit to new account's vault
        let newVaultRef = newAccount.storage.borrow<&{FungibleToken.Receiver}>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow new account's vault")
        newVaultRef.deposit(from: <-funding)
        
        // Create PoolPositionCollection for the new account
        let collection <- PrizeLinkedAccounts.createPoolPositionCollection()
        newAccount.storage.save(<-collection, to: PrizeLinkedAccounts.PoolPositionCollectionStoragePath)
        
        // Publish collection capability
        let collectionCap = newAccount.capabilities.storage.issue<&PrizeLinkedAccounts.PoolPositionCollection>(
            PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        )
        newAccount.capabilities.publish(collectionCap, at: PrizeLinkedAccounts.PoolPositionCollectionPublicPath)
        
        // Borrow the collection and make a deposit
        let collectionRef = newAccount.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("Could not borrow collection")
        
        // Withdraw from new account's vault for deposit
        let newAccountVault = newAccount.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow new account's vault for withdrawal")
        
        let payment <- newAccountVault.withdraw(amount: depositAmount)
        collectionRef.deposit(poolID: poolID, from: <-payment)
        
        log("Created receiver account: ".concat(newAccount.address.toString()))
    }
}
