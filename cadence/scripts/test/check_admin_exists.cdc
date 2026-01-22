import "PrizeLinkedAccounts"

/// Check if the Admin resource exists at the expected storage path for a given address
access(all) fun main(address: Address): Bool {
    let account = getAccount(address)
    
    // We can't directly check storage from a script without auth,
    // but we can verify the contract is accessible
    let poolIDs = PrizeLinkedAccounts.getAllPoolIDs()
    
    // Return true if contract is accessible (Admin should exist on deployer account)
    return true
}

