import "PrizeLinkedAccounts"

/// Destroy the signer's PoolPositionCollection, orphaning any active pool positions.
/// WARNING: Any shares held in pools become permanently inaccessible after this call.
transaction {
    prepare(signer: auth(Storage) &Account) {
        let collection <- signer.storage.load<@PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")

        destroy collection
    }
}
