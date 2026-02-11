import "FlowYieldVaultsClosedBeta"

/// Check if a beta badge capability exists in the account's inbox or storage
access(all) fun main(account: Address, adminAddr: Address): {String: AnyStruct} {
    let acct = getAccount(account)
    let result: {String: AnyStruct} = {}

    // Check if there's already a beta cap in storage
    let storagePath = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
    result["storagePath"] = storagePath.toString()

    // Check if the account has a published capability at the public path (if any)
    // We can't directly inspect inbox from a script, but we can check storage
    let authAcct = getAuthAccount<auth(Storage) &Account>(account)

    let storageType = authAcct.storage.type(at: storagePath)
    if storageType != nil {
        result["hasCapInStorage"] = true
        result["storageType"] = storageType!.identifier
    } else {
        result["hasCapInStorage"] = false
    }

    return result
}
