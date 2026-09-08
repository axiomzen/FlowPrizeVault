/// Does nothing. Used to prove a signer configuration (e.g. a KMS-backed key) can sign.
transaction {
    prepare(signer: &Account) {
        log("signed by ".concat(signer.address.toString()))
    }
}
