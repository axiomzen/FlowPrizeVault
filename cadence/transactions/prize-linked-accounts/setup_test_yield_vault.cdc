import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Setup Test Yield Vault - Creates a dedicated FlowToken vault for yield testing
/// This vault will receive deposits and can provide withdrawals (simulating a yield source)
/// The admin will fund this vault to simulate yield generation
///
/// Parameters:
/// - vaultPath: Storage path identifier (e.g., "testYieldVault", "testYieldVault2")
///
/// Stores at: /storage/<vaultPath>
/// Receiver published at: /public/<vaultPath>Receiver
transaction(vaultPath: String) {

    prepare(signer: auth(Storage, Capabilities) &Account) {
        let storagePath = StoragePath(identifier: vaultPath)
            ?? panic("Invalid storage path identifier: ".concat(vaultPath))
        let publicPath = PublicPath(identifier: vaultPath.concat("Receiver"))
            ?? panic("Invalid public path identifier: ".concat(vaultPath).concat("Receiver"))

        if signer.storage.type(at: storagePath) != nil {
            log("Yield vault already exists at /storage/".concat(vaultPath))
            return
        }

        let vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-vault, to: storagePath)

        let providerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            storagePath
        )

        let receiverCap = signer.capabilities.storage.issue<&FlowToken.Vault>(
            storagePath
        )
        signer.capabilities.publish(receiverCap, at: publicPath)

        log("Yield vault created at /storage/".concat(vaultPath))
        log("Receiver published at /public/".concat(vaultPath).concat("Receiver"))
        log("Provider capability ID: ".concat(providerCap.id.toString()))
    }
}

