# Configure where you want CSV files dumped to. 
# By default, it dump to the user's Documents folder.
$csvPath = "$env:USERPROFILE\Documents\" 

# Connect to Azure Subscription (preferably with an account that has rights to all subscriptions)
# This will prompt you to login via browser and code
Connect-AzAccount

# Get all the subscriptions
$subscriptions = Get-AzSubscription | ? State -EQ "Enabled" | Sort Name
Write-Host "----------------------------------------------------------------------------"
Write-Host "Found $($subscriptions.count) total Subscriptions, looping thru them all now" -ForegroundColor Green
Write-Host "----------------------------------------------------------------------------"

# Create a collection to keep track of all public IP address
$publicIPsTotal = @()

# Loop thru each subscription...
ForEach ($s in $subscriptions) {
    Write-Host " Subscription: $($s.Name)" -ForegroundColor Cyan

    # Set context to working subscrioption
    Get-AzSubscription -SubscriptionId $s.Id | Set-AzContext | Out-Null

    # Get all public IPs for subscription
    Try {
        $publicIPs = Get-AzPublicIpAddress | ? IpAddress -notlike "*Not Assigned*" | Select Name, ResourceGroupName, Location, IpAddress
        $publicIPsTotal += $publicIPs
        Write-Host " - Found Public IPs: $($publicIPs.Count)"
    }
    Catch {
        Write-Error "Unable to search for Public IPs on this subscription. Perhaps the user you're running as does not have permission?"
    }
}

# Output some final stats
Write-Host "-------------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
Write-Host " Total Public IPs: $($publicIPsTotal.Count)" -ForegroundColor Green
Write-Host "-------------------------------------------------------------------------------------------------------------------" -ForegroundColor Green

# Dump to CSV
If ($publicIPsTotal.Count -gt 0) {
    $path = $csvPath + "all-publicIPs.csv"
    Write-Host " - Dumping to CSV to $path"
    $publicIPsTotal | Export-Csv -Path $path
}