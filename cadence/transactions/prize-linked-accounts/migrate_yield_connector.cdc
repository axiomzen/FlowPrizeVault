import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import DeFiActions from "../../imports/92195d814edf9cb0/DeFiActions.cdc"

/// Migrate Yield Connector transaction - Migrates a pool's yield connector to a new one
///
/// This operation atomically withdraws all funds from the old connector and deposits
/// them to the new connector.
///
/// FAILS IF:
/// - Active draw is in progress
/// - Old connector doesn't have full liquidity
/// - New connector cannot accept the full deposit
/// - Asset types don't match
///
/// Parameters:
/// - poolID: The ID of the pool to migrate
///
/// NOTE: This is a template transaction. In practice, you'll need to construct
/// the newConnector based on your specific yield source implementation.
/// The connector must implement both DeFiActions.Sink and DeFiActions.Source.
transaction(poolID: UInt64 /*, params for new connector */) {

    let admin: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage, BorrowValue) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow admin reference")
    }

    execute {
        // Create new connector (implementation-specific)
        // Example: For a mock yield connector, you would create it like:
        // let newConnector = MockYieldConnector(...)
        //
        // For production, this would be something like:
        // let newConnector = IncrementFiConnector(vaultCap: ...)
        //
        // let newConnector: {DeFiActions.Sink, DeFiActions.Source} = ...

        // TODO: Uncomment and modify the following once you have your connector:
        // let result = self.admin.migratePoolYieldConnector(
        //     poolID: poolID,
        //     newConnector: newConnector
        // )
        //
        // log("Migration complete: "
        //     .concat(result.fundsDeposited.toString())
        //     .concat(" tokens migrated from ")
        //     .concat(result.oldConnectorType)
        //     .concat(" to ")
        //     .concat(result.newConnectorType))

        panic("This is a template transaction. Implement the newConnector creation for your specific use case.")
    }
}
