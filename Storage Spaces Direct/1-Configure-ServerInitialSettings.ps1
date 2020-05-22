#################################################
#region SCRIPT CONFIGURATION AND GLOBAL VARIABLES

# TODO: Change the .Json files to hold all cluster node info in an array.
#       Make this script now just functional, but reusable by allowing
#       parameters to be passed to it, specifically what node we want to configure.

# Load config file and specify which node we want to configure
$serverNameToConfigure = "S2D-NODE-XX"
$serverConfigJSONFile = "C:\XXXXXX\clusterConfig.json"
$serverConfigJSONData = Get-Content -Path $serverConfigJSONFile | ConvertFrom-Json

# Get that specific node's data
$clusterData = $serverConfigJSONData.clusterData
$serverData = $serverConfigJSONData.serverData | ? serverName -Like $serverNameToConfigure

# Cluster and server specific
$domainName       = $clusterData.domainName
$domainOU         = $clusterData.domainOU
$interfaceDesc    = $clusterData.interfaceDescription
$interfaceName    = $clusterData.interfaceName
$switchName       = $clusterData.embeddedSwitchName
$serverName       = $serverData.serverName
$serverProductKey = $serverData.productKey
$mgmtName         = $clusterData.mgmtName
$mgmtIP           = $serverData.mgmtIP
$mgmtSubnet       = $clusterData.mgmtSubnet
$mgmtVLAN         = $clusterData.mgmtVLAN
$mgmtGW           = $serverData.mgmtGateway
$mgmtDNS1         = $serverData.mgmtDNS1
$mgmtDNS2         = $serverData.mgmtDNS2
$storageName      = $clusterData.storageName
$storageIP1       = $serverData.storageIP1
$storageIP2       = $serverData.storageIP2
$storageIP3       = $serverData.storageIP3
$storageIP4       = $serverData.storageIP4
$storageSubnet    = $clusterData.storageSubnet
$storageVLAN      = $clusterData.storageVLAN

# Global variables
$serverOSBuild = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\' -Name CurrentBuildNumber

#endregion

#####################################
#region FEATURE AND ROLE INSTALLATION

# Check if the required S2D Features and Roles are already installed, skip if they are
# TODO: Change this to Get-WindowsFeature
Write-Host "Checking if Hyper-V, FCM, DCB, and Deduplication Features are installed" -ForegroundColor Cyan
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
Install-WindowsFeature -Name Data-Center-Bridging -IncludeManagementTools
Install-WindowsFeature -Name FS-Data-Deduplication -IncludeManagementTools

#endregion

############################
#region CONVERGED NIC RENAME

# Grab the specified pNICs and rename them
Write-Host "Renaming Converged pNIC's" -ForegroundColor Cyan
$convergedNIC = Get-NetAdapter | ? InterfaceDescription -Like "*$interfaceDesc*"

ForEach ($n in $convergedNIC) {

    # Set the interface's name and increment the counter
    $tempName = "$interfaceName - $($n.Name)"
    $n | Rename-NetAdapter -NewName $tempName
}

#endregion

#########################################
#region CONVERGED NIC TEMPORARY MGMT IPv4

# Grab one of the pNICs that is Status UP
Write-Host "Configure MGMT IP temporarily on a single pNIC" -ForegroundColor Cyan
$tempMgmtNIC = Get-NetAdapter | ? InterfaceDescription -Like "*$interfaceDesc*" | ? Status -like "*Up*" | Select -First 1

# Set the pNIC IPv4 address to temporary MGMT IP and MGMT VLAN
Write-Host " - Name: $($tempMgmtNIC.Name)" -ForegroundColor Yellow
Write-Host " - IPv4: $mgmtIP" -ForegroundColor Yellow
Write-Host " - Sub:  $mgmtSubnet" -ForegroundColor Yellow
Write-Host " - GW:   $mgmtGW" -ForegroundColor Yellow
Write-Host " - DNS1: $mgmtDNS1" -ForegroundColor Yellow
Write-Host " - DNS2: $mgmtDNS2" -ForegroundColor Yellow
Write-Host " - VLAN: $mgmtVLAN" -ForegroundColor Yellow
$tempMgmtNIC | New-NetIPAddress -AddressFamily IPv4 -IPAddress $mgmtIP -PrefixLength $mgmtSubnet -DefaultGateway $mgmtGW | Out-Null
$tempMgmtNIC | Set-DnsClientServerAddress -ServerAddresses $mgmtDNS1,$mgmtDNS2
$tempMgmtNIC | Set-NetAdapter -VlanID $mgmtVLAN -Confirm:$false

#endregion

################################
#region ACTIVATE WINDOWS LICENSE

Write-Host "Activating Windows with specified key" -ForegroundColor Cyan
$softwareLicenseService = Get-WmiObject -query "SELECT * FROM SoftwareLicensingService"
$softwareLicenseService.InstallProductKey($serverProductKey) | Out-Null
$softwareLicenseService.RefreshLicenseStatus() | Out-Null

Write-Host " - Sleeping for 10 seconds while activation validates" -ForegroundColor Yellow
Start-Sleep 10

#endregion

#####################################
#region DOMAIN JOIN AND SERVER RENAME

Write-Host "Renaming and joining to domain" -ForegroundColor Cyan
Add-Computer -DomainName $domainName -NewName $serverName -OUPath $domainOU

#endregion

#####################
#region END OF SCRIPT

Write-Host "Configuration completed. Please restart this server and run Script 2." -ForegroundColor Cyan

#endregion