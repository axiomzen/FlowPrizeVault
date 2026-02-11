/// Iterate over all storage paths in an account and print the type at each path
access(all) fun main(account: Address): {String: String} {
    let authAcct = getAuthAccount<auth(Storage) &Account>(account)
    let result: {String: String} = {}

    authAcct.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        result[path.toString()] = type.identifier
        return true
    })

    return result
}
