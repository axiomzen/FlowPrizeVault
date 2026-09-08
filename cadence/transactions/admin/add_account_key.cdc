/// Adds an ECDSA_P256 / SHA2_256 public key to the signer's account.
/// Used to attach a Google Cloud KMS-backed key (KMS only offers P256 with SHA-256).
///
/// publicKeyHex: raw 64-byte public key as hex (output of `flow keys decode pem ...`)
/// weight:       1000.0 for a full-weight key
transaction(publicKeyHex: String, weight: UFix64) {
    prepare(signer: auth(AddKey) &Account) {
        let key = PublicKey(
            publicKey: publicKeyHex.decodeHex(),
            signatureAlgorithm: SignatureAlgorithm.ECDSA_P256
        )
        signer.keys.add(
            publicKey: key,
            hashAlgorithm: HashAlgorithm.SHA2_256,
            weight: weight
        )
        log("added key, total keys: ".concat(signer.keys.count.toString()))
    }
}
