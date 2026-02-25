import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Add Yield to Pool - Simulates yield generation by adding funds to a test yield vault
/// This is for testing purposes - the funds added will be available as "yield"
/// when syncWithYieldSource is called
///
/// Parameters:
/// - amount: Amount of FLOW to add as simulated yield
/// - yieldVaultPath: Storage path identifier of the yield vault (e.g., "testYieldVault", "testYieldVault2")
transaction(amount: UFix64, yieldVaultPath: String) {

    let senderVault: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(Storage) &Account) {
        self.senderVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow sender's FlowToken vault")

        let storagePath = StoragePath(identifier: yieldVaultPath)
            ?? panic("Invalid storage path identifier: ".concat(yieldVaultPath))

        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: storagePath
        ) ?? panic("Could not borrow yield vault at /storage/".concat(yieldVaultPath).concat(" - run setup_test_yield_vault.cdc first"))
    }

    execute {
        let tokens <- self.senderVault.withdraw(amount: amount)
        self.receiverRef.deposit(from: <- tokens)

        log("Added ".concat(amount.toString()).concat(" FLOW as simulated yield to /storage/").concat(yieldVaultPath))
    }
}

