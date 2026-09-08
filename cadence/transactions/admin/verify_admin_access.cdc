import "PrizeLinkedAccounts"

/// Proves the signing key has full administrative authority over the account,
/// without changing any state.
///
/// Borrows the Admin resource with every entitlement a real operation needs and
/// asserts it resolved. Borrowing a reference mutates nothing, so this is safe to
/// run against mainnet at any time. It costs only the transaction fee.
///
/// Use it after rotating the account key to confirm the new key can do everything
/// the old one could: authorize the transaction, reach account storage, and obtain
/// an entitled reference to Admin. A plain no-op transaction proves only the first.
transaction {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<
            auth(
                PrizeLinkedAccounts.CriticalOps,
                PrizeLinkedAccounts.ConfigOps,
                PrizeLinkedAccounts.OwnerOnly
            ) &PrizeLinkedAccounts.Admin
        >(from: PrizeLinkedAccounts.AdminStoragePath)
            ?? panic("no Admin resource at \(PrizeLinkedAccounts.AdminStoragePath)")

        log("admin reference obtained by \(signer.address)")
        log("entitlements CriticalOps + ConfigOps + OwnerOnly all resolved")
        log("admin uuid \(admin.uuid)")
    }

    execute {
        log("no state changed")
    }
}
