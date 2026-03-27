import "PrizeLinkedAccounts"
import FungibleToken from "FungibleToken"

/// Set Protocol Fee Recipient (requires OwnerOnly — deployer account only).
///
/// Once set, protocol fees are automatically forwarded to the recipient on every
/// syncWithYieldSource call (deposits, withdrawals, draw start).
///
/// The recipient must have a valid FungibleToken.Receiver capability at the
/// specified public path before calling this transaction.
///
/// To stop auto-forwarding, run fees/clear_protocol_fee_recipient.cdc.
/// To withdraw accumulated unclaimed fees, run fees/withdraw_protocol_fee.cdc.
///
/// Parameters:
///   poolID           — the pool to configure
///   recipientAddress — address to receive protocol fees
///   receiverPath     — public path of the FungibleToken.Receiver capability
///                      e.g., /public/flowTokenReceiver
///
/// Signer: deployer account ONLY (OwnerOnly cannot be delegated)
transaction(poolID: UInt64, recipientAddress: Address, receiverPath: PublicPath) {

    let adminRef: auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("OwnerOnly access required — this transaction must be signed by the deployer account")
    }

    execute {
        let recipientAccount = getAccount(recipientAddress)
        let receiverCap = recipientAccount.capabilities.get<&{FungibleToken.Receiver}>(receiverPath)

        assert(receiverCap.check(), message: "Invalid receiver capability at ".concat(recipientAddress.toString()).concat(" path ").concat(receiverPath.toString()))

        self.adminRef.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: receiverCap
        )

        log("Protocol fee recipient set for pool ".concat(poolID.toString()).concat(" → ").concat(recipientAddress.toString()))
    }
}
