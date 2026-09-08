/// Revokes a key on the signer's account by index. Irreversible.
/// Refuses to run if it would leave the account with no unrevoked full-weight key.
transaction(keyIndex: Int) {
    prepare(signer: auth(RevokeKey) &Account) {
        var remainingWeight: UFix64 = 0.0
        signer.keys.forEach(fun (key: AccountKey): Bool {
            if !key.isRevoked && key.keyIndex != keyIndex {
                remainingWeight = remainingWeight + key.weight
            }
            return true
        })
        assert(remainingWeight >= 1000.0, message: "refusing: revoking key would leave account without a full-weight key")

        let revoked = signer.keys.revoke(keyIndex: keyIndex)
            ?? panic("no key at index ".concat(keyIndex.toString()))
        assert(revoked.isRevoked, message: "key not marked revoked")
        log("revoked key index ".concat(keyIndex.toString()))
    }
}
