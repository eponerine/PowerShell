param (
    [Parameter(Mandatory)]
    [string]$ServerName,
    
    [Parameter(Mandatory)]
    [string]$ServerConfigJSONPath
)

#################################################
#region SCRIPT CONFIGURATION AND GLOBAL VARIABLES

# TODO: Change the .Json files to hold all cluster node info in an array.
#       Make this script now just functional, but reusable by allowing
#       parameters to be passed to it, specifically what node we want to configure.

# Load config file and specify which node we want to configure
$serverNameToConfigure = $ServerName
$serverConfigJSONFile = $ServerConfigJSONPath
$serverConfigJSONData = Get-Content -Path $serverConfigJSONFile | ConvertFrom-Json

# Get that specific node's data
$clusterData = $serverConfigJSONData.clusterData
$serverData = $serverConfigJSONData.serverData | ? serverName -Like $serverNameToConfigure

# Cluster and server specific
$domainName       = $clusterData.domainName
$domainOU         = $clusterData.domainOU
$interfaceDesc    = $clusterData.interfaceDescription
$interfaceName    = $clusterData.interfaceName
$serverName       = $serverData.serverName
$serverProductKey = $serverData.productKey
$mgmtName         = $clusterData.mgmtName
$mgmtIP           = $serverData.mgmtIP
$mgmtSubnet       = $clusterData.mgmtSubnet
$mgmtVLAN         = $clusterData.mgmtVLAN
$mgmtGW           = $serverData.mgmtGateway
$mgmtDNS1         = $serverData.mgmtDNS1
$mgmtDNS2         = $serverData.mgmtDNS2
$netATCEnabled    = $clusterData.netATCEnabled
$SDNEnabled       = $clusterData.SDNEnabled

# Global variables
$serverOSBuild = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\' -Name CurrentBuildNumber

#endregion

#####################################
#region FEATURE AND ROLE INSTALLATION

# Check if the required S2D Features and Roles are already installed, skip if they are
# TODO: Change this to Get-WindowsFeature
Write-Host "Installing roles like Hyper-V, FCM, DCB, Deduplication, etc..." -ForegroundColor Cyan
#Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
#Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
#Install-WindowsFeature -Name Data-Center-Bridging -IncludeManagementTools
#Install-WindowsFeature -Name FS-Data-Deduplication -IncludeManagementTools
#Install-WindowsFeature -Name FS-SMBBW -IncludeManagementTools
Install-WindowsFeature -Name "BitLocker", "Data-Center-Bridging", "Failover-Clustering", "FS-FileServer", "FS-Data-Deduplication", "Hyper-V", "Hyper-V-PowerShell", "RSAT-AD-Powershell", "RSAT-Clustering-PowerShell", "FS-SMBBW", "Storage-Replica" -IncludeAllSubFeature -IncludeManagementTools
If ($SDNEnabled) { Install-WindowsFeature -Name NetworkVirtualization -IncludeManagementTools }
If ($netATCEnabled) { Install-WindowsFeatures -Name "NetworkATC", "NetworkHUD" -IncludeManagementTools -IncludeAllSubFeature }

#endregion

############################
#region NIC RENAME
$allNIC = Get-NetAdapter | ? InterfaceDescription -Like "*$interfaceDesc*"

Write-Host "Found $($allNIC.count) interfaces that match description $interfaceDesc" -ForegroundColor Cyan
$allNIC | Sort ifIndex |FT Name, InterfaceDescription, ifIndex, Status

$interfaceGroupCount = Read-Host -Prompt "How many interface groups (vSwitch) are you creating"
Write-Host "-----------------------------"


For ($i = 1; $i -le $interfaceGroupCount; $i++) {
    
    # Loop thru and rename the interfaces
    $currentInterfaceGroupName = Read-Host -Prompt "Interface Group $i Prefix"
    $groupMemberInterfaceIndexes = Read-Host -Prompt "Interfaces to add to vSwitch $currentInterfaceGroupName (separate with commas)"
    $groupMemberInterfaceArray = $groupMemberInterfaceIndexes.split(',')
    
    $groupMemberInterfaces = Get-NetAdapter -ifIndex $groupMemberInterfaceArray
    
    ForEach ($n in $groupMemberInterfaces) {
        $tempName = "$currentInterfaceGroupName - $($n.Name)"
        $n | Rename-NetAdapter -NewName $tempName
    }
    Write-Host "-----------------------------"
}

############################
#region CONVERGED NIC RENAME

# Grab the specified pNICs and rename them.
# If the word "converged" is already in the display name, skip it as this portion of the script was most likely already ran.
#Write-Host "Renaming Converged pNIC's" -ForegroundColor Cyan
#$convergedNIC = Get-NetAdapter | ? InterfaceDescription -Like "*$interfaceDesc*" | ? Name -NotLike "*Converged*"

#ForEach ($n in $convergedNIC) {
#    # Set the interface's name and increment the counter
#    $tempName = "$interfaceName - $($n.Name)"
#    $n | Rename-NetAdapter -NewName $tempName
#}

#endregion

#########################################
#region CONVERGED NIC TEMPORARY MGMT IPv4

# Grab one of the pNICs that is Status UP
Write-Host "Configure MGMT IP temporarily on a single pNIC" -ForegroundColor Cyan
$tempMgmtNICIndex = Read-Host -Prompt "Which interface index do you want to configure as temporary MGMT"
$tempMgmtNIC = Get-NetAdapter -ifIndex $tempMgmtNICIndex

#$tempMgmtNIC = Get-NetAdapter | ? InterfaceDescription -Like "*$interfaceDesc*" | ? Status -like "*Up*" | Select -First 1

If ($tempMgmtNIC) {
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

    # Join to domain
    Write-Host "Renaming and joining to domain" -ForegroundColor Cyan
    Add-Computer -DomainName $domainName -NewName $serverName -OUPath $domainOU
}
Else {
    Write-Warning "Could not find a pNIC with UP status. IP was not set and did not join to domain. Please check your physical wiring or switch and try again." 
}

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

#####################
#region END OF SCRIPT

Write-Host "Configuration completed. Please restart this server and run Script 2." -ForegroundColor Cyan

#endregion