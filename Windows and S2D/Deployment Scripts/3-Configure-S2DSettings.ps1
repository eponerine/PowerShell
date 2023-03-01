param (
    [Parameter(Mandatory)]
    [string]$ServerConfigJsonPath
)

#################################################
#region SCRIPT CONFIGURATION AND GLOBAL VARIABLES

# TODO: Change the .Json files to hold all cluster node info in an array.
#       Make this script now just functional, but reusable by allowing
#       parameters to be passed to it, specifically what node we want to configure.

# Load config file
$serverConfigJSONFile = $ServerConfigJSONPath
$serverConfigJSONData = Get-Content -Path $serverConfigJSONFile | ConvertFrom-Json

# Get that specific node's data
$clusterData = $serverConfigJSONData.clusterData
$serverData = $serverConfigJSONData.serverData

# Cluster and server specific
$domainName                    = $clusterData.domainName
$domainOU                      = $clusterData.domainOU
$clusterName                   = $clusterData.clusterName
$clusterIP                     = $clusterData.clusterIP
$clusterManagementPointType    = $clusterData.clusterManagementPointType
$clusterAutoBalance            = $clusterData.clusterAutoBalance
$clusterCSVCacheSize           = $clusterData.clusterCSVCacheSize
$clusterLiveMigrationCount     = $clusterData.clusterLiveMigrationCount
$clusterQuorumSharePath        = $clusterData.quorumSharePath
$clusterQuorumCloudAcctName    = $clusterData.quorumCloudAcctName
$clusterQuorumCloudKey         = $clusterData.quorumCloudKey
$hciRegistrationTenantID       = $clusterData.hciRegistrationTenantID
$hciRegistrationSubscriptionID = $clusterData.hciRegistrationSubscriptionID
$hciRegistrationRGName         = $clusterData.hciRegistrationRGName
$hciRegistrationRegion         = $clusterData.hciRegistrationRegion
$clusterNodes                  = $serverData.serverName
$mgmtName                      = $clusterData.mgmtName
$mgmtNetwork                   = $clusterData.mgmtNetwork
$storageName                   = $clusterData.storageName
$embeddedSwitches              = $clusterData.embeddedSwitches

#endregion

####################################
#region CREATE AND CONFIGURE CLUSTER

Write-Host "Configure new cluster" -ForegroundColor Cyan

# Create the new cluster and sleep for 5 seconds after creation
Write-Host " - Create cluster" -ForegroundColor Yellow
If ($clusterManagementPointType -eq "Distributed") {
    New-Cluster -Name $clusterName -Node $clusterNodes -StaticAddress $clusterIP -ManagementPointNetworkType "Distributed" -Verbose
}
Else {
    New-Cluster -Name $clusterName -Node $clusterNodes -StaticAddress $clusterIP -Verbose
}
Start-Sleep 5
Clear-DnsClientCache

# Set the quroum
If ($clusterQuorumSharePath) {
    Write-Host " - Set quorum witness to UNC share" -ForegroundColor Yellow
    Set-ClusterQuorum -Cluster $clusterName -FileShareWitness $clusterQuorumSharePath
} 
Else {
    Write-Host " - Set quorum witness to Azure Cloud Blob" -ForegroundColor Yellow
    Set-ClusterQuorum -CloudWitness -AccountName $clusterQuorumCloudAcctName -AccessKey $clusterQuorumCloudKey
}

# Rename Management Cluster Network
(Get-ClusterNetwork -Cluster $clusterName | ? Address -Like "*$mgmtNetwork*").Name = "Cluster Network - $mgmtName"

# Rename Storage Cluster Network
ForEach ($s in $embeddedSwitches) {
    (Get-ClusterNetwork -Cluster $clusterName | ? Address -like $s.storageCIDR).Name = "Cluster Network - $($s.storageName)-$($s.storageVLAN)"
}

#endregion

#############################################
#region INDIVIDUAL CLUSTER NODE CONFIGURATION

Write-Host "Configuring cluster-specific settings on each node"
ForEach ($n in $clusterNodes) {

    Write-Host "$n - Configuring cluster-specific settings"
    Invoke-Command -ComputerName $n -ScriptBlock {

        # If Server 2019, disable the S2D kill switch
        Write-Host " - Checking if Server 2016 or 2019 for S2D kill switch" -ForegroundColor Yellow
        $serverReleaseID = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\' -Name ReleaseID

        If ($serverReleaseID -eq "1809") {
            Write-Host " - Disable S2D kill switch on Server 2019" -ForegroundColor Yellow
            New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc\Parameters" -Name "S2D" -PropertyType "DWORD" -Value 1 -Force | Out-Null
        }

        # Clean the Physical Disks (just in case)
        Write-Host " - Clean physical disks" -ForegroundColor Yellow
        Update-StorageProviderCache -DiscoveryLevel Full
        Get-StoragePool | ? IsPrimordial -eq $false | Set-StoragePool -IsReadOnly:$false -ErrorAction SilentlyContinue
        Get-StoragePool | ? IsPrimordial -eq $false | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
        Get-StoragePool | ? IsPrimordial -eq $false | Remove-StoragePool -Confirm:$false -ErrorAction SilentlyContinue
        Get-PhysicalDisk | Reset-PhysicalDisk -ErrorAction SilentlyContinue
        Get-Disk | ? Number -ne $null | ? IsBoot -ne $true | ? IsSystem -ne $true | ? PartitionStyle -ne RAW | % {
            $_ | Set-Disk -isoffline:$false
            $_ | Set-Disk -isreadonly:$false
            $_ | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
            $_ | Set-Disk -isreadonly:$true
            $_ | Set-Disk -isoffline:$true
        }
    }
}

#endregion


#####################################
#region S2D AND CLUSTER CONFIGURATION

Write-Host "Modifying default Cluster configurations." -ForegroundColor Cyan

# Configure S2D on the Cluster
Write-Host " - Enable ClusterS2D" -ForegroundColor Yellow
Enable-ClusterS2D -Confirm:$false -Verbose

# Part 2 of the Intel NVMe/SSD hardware hack
Get-StorageSubSystem clus* | Set-StorageHealthSetting -Name "System.Storage.PhysicalDisk.Unresponsive.Reset.CountAllowed" -Value 15
Get-StorageSubSystem clus* | Set-StorageHealthSetting -Name "System.Storage.PhysicalDisk.Unresponsive.Reset.CountResetIntervalSeconds" -Value 30

# Enable Cluster Live Dump
Write-Host " - Enable Cluster Live Dumps" -ForegroundColor Yellow
(Get-Cluster).DumpPolicy = 1118489

# Configure S2D Read Cache
Write-Host " - Configure CSV in-memory read cache" -ForegroundColor Yellow
(Get-Cluster).BlockCacheSize = $clusterCSVCacheSize

# Configure Live Migration count
Write-Host " - Configure Live Migration count" -ForegroundColor Yellow
(Get-Cluster).MaximumParallelMigrations = $clusterLiveMigrationCount

# Configure Cluster IP to not use NetBIOS
Write-Host " - Set Cluster IP to not use NetBIOS" -ForegroundColor Yellow
Get-ClusterResource "Cluster IP address" | Set-ClusterParameter EnableNetBIOS 0

# Set Cluster auto balancer to DISABLED if requested
If (!$clusterAutoBalance) {
    Write-Host " - Set Cluster Auto Balance to DISABLED" -ForegroundColor Yellow
    (Get-Cluster).AutoBalancerMode = 0
    (Get-Cluster).AutoBalancerLevel = 3
}

# Set Cluster Core Resources to use their own RHS monitor process
# Note that this change will require a resource node ownership
# change to take effect. Rebooting the nodes works, too.
# TODO: makes sense to Get-ClusterResource by TYPE instead of NAME to prevent
#       error if things were changed from default. 
Write-Host " - Enable separate RHS monitor processes" -ForegroundColor Yellow
Write-Host "   Some of these may fail as they may not be enabled on your cluster. That's ok!"
(Get-ClusterResource -Name "Cloud Witness").SeparateMonitor               = 1
(Get-ClusterResource -Name "Cluster IP Address").SeparateMonitor          = 1
(Get-ClusterResource -Name "Cluster Name").SeparateMonitor                = 1
(Get-ClusterResource -Name "Cluster Pool 1").SeparateMonitor              = 1
(Get-ClusterResource -Name "File Share Witness").SeparateMonitor          = 1
(Get-ClusterResource -Name "Health").SeparateMonitor                      = 1
(Get-ClusterResource -Name "SDDC Management").SeparateMonitor             = 1
(Get-ClusterResource -Name "Task Scheduler").SeparateMonitor              = 1
(Get-ClusterResource -Name "User Manager").SeparateMonitor                = 1
(Get-ClusterResource -Name "Storage Qos Resource").SeparateMonitor        = 1
(Get-ClusterResource -Name "Virtual Machine Cluster WMI").SeparateMonitor = 1

#endregion

#####################################
#region REGISTER AZURE STACK HCI
$sku = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName).ProductName

If ($sku -eq "Azure Stack HCI") {
    Write-Host "Registering Azure Stack HCI... please log in with an account that has correct permissions" -ForegroundColor Cyan
    Install-Module -Name Az.Accounts -Force
    Install-Module -Name Az.StackHCI -Force

    Connect-AzAccount -TenantId $hciRegistrationTenantID -SubscriptionId $hciRegistrationSubscriptionID -UseDeviceAuthentication

    Write-Host "Connecting to Azure and sleeping 10 seconds..."
    Start-Sleep 10

    $armTokenItemResource = "https://management.core.windows.net/"
    $azContext = Get-AzContext
    $authFactory = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory
    $armToken = $authFactory.Authenticate($azContext.Account, $azContext.Environment, $azContext.Tenant.Id, $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, $armTokenItemResource).AccessToken
    $id = $azContext.Account.Id

    Register-AzStackHCI -Region $hciRegistrationRegion -SubscriptionID $hciRegistrationSubscriptionID -ResourceGroupName $hciRegistrationRGName -ArcServerResourceGroupName "$clusterName-Arc-Infra-RG" -ArmAccessToken $armToken -AccountId $id -ResourceName $clusterName
}

#####################
#region END OF SCRIPT

Write-Host "Configuration completed." -ForegroundColor Cyan

#endregion