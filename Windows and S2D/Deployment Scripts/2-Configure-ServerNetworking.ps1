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
$domainName                      = $clusterData.domainName
$domainOU                        = $clusterData.domainOU
$interfaceDesc                   = $clusterData.interfaceDescription
$interfaceName                   = $clusterData.interfaceName
$switchName                      = $clusterData.embeddedSwitchName
$serverName                      = $serverData.serverName
$mgmtName                        = $clusterData.mgmtName
$mgmtIP                          = $serverData.mgmtIP
$mgmtSubnet                      = $clusterData.mgmtSubnet
$mgmtVLAN                        = $clusterData.mgmtVLAN
$mgmtGW                          = $serverData.mgmtGateway
$mgmtDNS1                        = $serverData.mgmtDNS1
$mgmtDNS2                        = $serverData.mgmtDNS2
$storageName                     = $clusterData.storageName
$storageIPs                      = $serverData.storageIPs
$storageSubnet                   = $clusterData.storageSubnet
$storageVLAN                     = $clusterData.storageVLAN
$SDNEnabled                      = $clusterData.SDNEnabled
$SDNNcHostAgentDnsProxyServiceIP = $clusterData.SDNNcHostAgentDnsProxyServiceIP
$SDNDNSProxyForwarders           = $clusterData.SDNDNSProxyForwarders

# Global variables
$serverOSBuild = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\' -Name CurrentBuildNumber

#endregion

####################################
#region DISABLE TEMPORARY IP ADDRESS

Write-Host "Resetting temporary MGMT interface IP address back to default settings" -ForegroundColor Cyan

$tempInterface = Get-NetIPAddress | ? IPAddress -EQ $mgmtIP | Get-NetAdapter
$tempInterface | Remove-NetIPAddress -Confirm:$false
$tempInterface | Remove-NetRoute -Confirm:$false
$tempInterface | Set-DnsClientServerAddress -ResetServerAddresses
$tempInterface | Set-NetAdapter -VlanID 0 -Confirm:$false
$tempInterface | Set-NetIPInterface -Dhcp Enabled

#endregion

##########################################################
#region CREATE AND CONFIGURE SET (SWITCH EMBEDDED TEAMING)

# Create the SET Switch and add all the available pNIC's to it. Don't create the default vNIC, we'll do that later
Write-Host "Creating SET Switch and adding all pNICs with Status = UP" -ForegroundColor Cyan

$physicalInterfacesAll = Get-NetAdapter -Name "*$interfaceName*"
$physicalInterfaces = Get-NetAdapter -Name "*$interfaceName*" | ? Status -like "*up*"

If ($physicalInterfacesAll -ne $physicalInterfaces) {
    Write-Host " - There was a mismatch between ALL pNIC and UP pNIC... make sure you have everything plugged in or manually go add to SET Switch later" -ForegroundColor Yellow
}

New-VMSwitch -Name $switchName -NetAdapterName $physicalInterfaces.Name -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight -AllowManagementOS $false | Out-Null

# Set SET Switch load balancing algorithm to HyperVPort if it's 2016. Anything newer than 2016 has this on by default
If ($serverOSBuild -eq 14393) {
    Write-Host " - Setting Load Balance Algorithm to HyperVPort (you're probably running 2016)" -ForegroundColor Yellow
    Set-VMSwitchTeam -Name $switchName -LoadBalancingAlgorithm HyperVPort
}

#endregion

##############################################
#region CONFIGURE MANAGEMENT AND STORAGE vNICs

Write-Host "Configuring vNICs" -ForegroundColor Cyan

# Create Management vNIC and configure network settings
Write-Host " - Adding Management vNIC" -ForegroundColor Yellow
Add-VMNetworkAdapter -SwitchName $switchName -Name $mgmtName -ManagementOS
Set-VMNetworkAdapterVlan -VMNetworkAdapterName $mgmtName -VlanId $mgmtVLAN -Access -ManagementOS

# Create Storage vNIC's and configure their network settings
# The number of vNIC's is determined by the total number of pNICs we added to the SET Switch above
Write-Host " - Adding $($physicalInterfaces.count) Storage vNICs" -ForegroundColor Yellow
For ($i = 1; $i -le $physicalInterfaces.count; $i++) {
    Add-VMNetworkAdapter -SwitchName $switchName -Name "$storageName $i" -ManagementOS
    Set-VMNetworkAdapterVlan -VMNetworkAdapterName "$storageName $i" -VlanId $storageVLAN -Access -ManagementOS
}

# Restart vNIC's to make sure VLAN tags are in effect
Write-Host " - Restarting all vNICs and sleeping for 5 seconds" -ForegroundColor Yellow
Restart-NetAdapter -Name "*vEthernet*"
Start-Sleep 5

#endregion

#########################
#region CONFIGURE MGMT IP

Write-Host "Configure Management vNIC" -ForegroundColor Cyan

# Get Management interface
$managementNIC = Get-NetAdapter | ? Name -Like "*$mgmtName*"

# Set Management NIC IP settings
Write-Host " - Set Management vNIC IP settings" -ForegroundColor Yellow
$managementNIC | New-NetIPAddress -IPAddress $mgmtIP -DefaultGateway $mgmtGW -PrefixLength $mgmtSubnet | Out-Null
$managementNIC | Set-DnsClientServerAddress -ServerAddresses $mgmtDNS1,$mgmtDNS2 | Out-Null

Write-Host " - Sleeping for 5 seconds and clearing DNS cache" -ForegroundColor Yellow
Start-Sleep 5
Clear-DnsClientCache

# Enable RDMA on vNICs
Write-Host " - Enable RDMA on Management vNIC" -ForegroundColor Yellow
$managementNIC | Enable-NetAdapterRdma

#endregion

################################
#region CONFIGURE STORAGE NIC IP

Write-Host "Configure Storage vNICs" -ForegroundColor Cyan

# Get all Storage interfaces
$storageVNICs = Get-NetAdapter | ? Name -Like "*$storageName*"

# Individually set each Storage vNIC IP setting
# TODO: Build in some logic to make sure the number of IPs in the JSON array matches the number of storage vNICs we're configuring, otherwise we'll get an Array OOB
Write-Host " - Set Management vNIC IP settings" -ForegroundColor Yellow
For ($i = 0; $i -lt $storageVNICs.count; $i++) {
    Write-Host " - Configuring Storage vNIC $i - $($storageIPs[$i])" -ForegroundColor Yellow
    $storageVNICs[$i] | New-NetIPAddress -IPAddress $storageIPs[$i] -PrefixLength $storageSubnet | Out-Null
}

Write-Host " - Sleeping for 5 seconds and clearing DNS cache" -ForegroundColor Yellow
Start-Sleep 5
Clear-DnsClientCache

# Enable RDMA on vNICs
Write-Host " - Enable RDMA on SMB vNICs" -ForegroundColor Yellow
$storageVNICs | Enable-NetAdapterRdma

# TODO: Set vNIC to pNIC affinity
#Set-VMNetworkAdapterTeamMapping

#endregion

#######################
#region DISABLE NetBIOS

# Get all the interfaces from WMI and set NetBIOS to DISABLED (2)
Write-Host "Disabling NetBIOS on all interfaces" -ForegroundColor Cyan
$interfaces = (Get-WmiObject win32_networkadapterconfiguration )

ForEach ($i in $interfaces) {

    $i.SetTcpipNetBios(2) | Out-Null
}

#endregion

######################################
#region CONFIGURE DCB AND FLOW CONTROL

Write-Host "Configuring DCB" -ForegroundColor Cyan

# Clear any existing DCB configs
Write-Host " - Clear any existing DCB configs" -ForegroundColor Yellow
Get-NetQosPolicy | Remove-NetQosPolicy -Confirm:$False
Disable-NetQosFlowControl -Priority 0,1,2,3,4,5,6,7
Get-NetQosTrafficClass | Remove-NetQosTrafficClass -Confirm:$False

# Turn off DCBX Willing
Write-Host " - Disable DCBX Willing" -ForegroundColor Yellow
Set-NetQosDcbxSetting -Willing $false -Confirm:$False

# Create QoS policies for SMB Direct and Cluster Heartbeat
Write-Host " - Create QoS policy for SMB Direct and Cluster Heartbeat" -ForegroundColor Yellow
New-NetQosPolicy "Default"          -Default                         -PriorityValue8021Action 0
New-NetQosPolicy "SMB"              -NetDirectPortMatchCondition 445 -PriorityValue8021Action 3
New-NetQosPolicy "ClusterHeartbeat" -Cluster                         -PriorityValue8021Action 7

Write-Host " - Configure Priority Flow Control (PFC)" -ForegroundColor Yellow
Enable-NetQosFlowControl -Priority 3
Disable-NetQosFlowControl -Priority 0,1,2,4,5,6,7

Write-Host " - Apply QoS policy to all pNICs (but not LOM, OOB, DRAC, etc)" -ForegroundColor Yellow
Get-NetAdapterQos | ? Name -like "*$interfaceName*" | Enable-NetAdapterQos | Out-Null

# Configure DCB minimum bandwidth (Default = 39%, SMB Direct = 60%, Cluster Heartbeat = 1%)
Write-Host " - Set minimum bandwidth for Default (39%), SMB Direct (60%), and Cluster Heartbeat (1%)" -ForegroundColor Yellow
New-NetQosTrafficClass "SMB"              -Priority 3 -BandwidthPercentage 60 -Algorithm ETS
New-NetQosTrafficClass "ClusterHeartbeat" -Priority 7 -BandwidthPercentage 1 -Algorithm ETS

# Configure Live Migration SMB Bandwidth Limit
Write-Host " - Configure Live Migration SMB Bandwidth Limit to 40% of total bandwidth" -ForegroundColor Yellow
$physicalInterfaces = Get-NetAdapter -Name "*$interfaceName*" | ? Status -like "*up*"
$bytesPerSecond = ($physicalInterfaces | Select TransmitLinkSpeed | Measure-Object -Sum TransmitLinkSpeed).Sum / 8
Write-Host " - Total Bytes/Sec: $bytesPerSecond" -ForegroundColor Yellow
Set-SmbBandwidthLimit -Category LiveMigration -BytesPerSecond ($bytesPerSecond*0.4)

# Disable traditional Flow Control on the Storage pNICs
Write-Host " - Disable traditional Flow Control on pNICs" -ForegroundColor Yellow
Set-NetAdapterAdvancedProperty -Name "*$interfaceName*" -RegistryKeyword "*FlowControl" -RegistryValue 0
Write-Host " - Sleeping for 10 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

#endregion

#########################
#region SDN CONFIGURATION

# Configure iDNS Settings on SDN host
If ($SDNEnabled) {
    Write-Host "Configuring SDN settings" -ForegroundColor Cyan
    
    Write-Host " - Configuring NcHostAgent DnsProxyService settings: $($SDNNcHostAgentDnsProxyServiceIP)" -ForegroundColor Yellow
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet" -name "InfraServices" -Force | out-null
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices" -name "DnsProxyService" -Force | out-null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices\DnsProxyService" -Name "Port" -Value 53 -PropertyType "Dword" -Force | out-null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices\DnsProxyService" -Name "ProxyPort" -Value 53 -PropertyType "Dword" -Force | out-null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices\DnsProxyService" -Name "IP" -Value $SDNNcHostAgentDnsProxyServiceIP -PropertyType "String" -Force | out-null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters\Plugins\Vnet\InfraServices\DnsProxyService" -Name "MAC" -Value "AA-BB-CC-AA-BB-CC" -PropertyType "String" -Force | out-null

    Write-Host " - Configuring DnsProxy settings: $($SDNNcHostAgentDnsProxyServiceIP)" -ForegroundColor Yellow
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services" -name "DnsProxy" -Force | out-null
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DnsProxy" -name "Parameters" -Force | out-null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DNSProxy\Parameters" -Name "Forwarders" -Value $SDNDNSProxyForwarders -PropertyType "String" -Force | out-null
    
    Restart-Service NcHostAgent -Force
}

#################################
#region MISC SERVER CONFIGURATION

Write-Host "Configuring misc settings" -ForegroundColor Cyan

# Disable DNS registration on all Storage NICs
Write-Host " - Disable DNS registration on all Storage NICs" -ForegroundColor Yellow
Set-DNSClient -InterfaceAlias "*$storageName*" -RegisterThisConnectionsAddress $False

# Configure Hyper-V live migration settings
Write-Host " - Configure Hyper-V live migration to use SMB and 6 simultanious transfers" -ForegroundColor Yellow
Set-VMHost -VirtualMachineMigrationPerformanceOption SMB -MaximumVirtualMachineMigrations 6

#Configure Active memory dump
Write-Host " - Configure Active Memory Dump" -ForegroundColor Yellow
Set-ItemProperty -Path HKLM:\System\CurrentControlSet\Control\CrashControl -Name CrashDumpEnabled -Value 1
Set-ItemProperty -Path HKLM:\System\CurrentControlSet\Control\CrashControl -Name FilterPages -Value 1

# Configure pagefile size to 100GB
Write-Host " - Configure pagefile size to 100GB" -ForegroundColor Yellow
$computersys = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
$computersys.AutomaticManagedPagefile = $False
$computersys.Put() | Out-Null
$pagefile = Get-WmiObject -Query "Select * From Win32_PageFileSetting Where Name like '%pagefile.sys'"
$pagefile.InitialSize = 102400
$pagefile.MaximumSize = 102400
$pagefile.Put() | Out-Null

# Configure Power Policy to High Performance
powercfg.exe /S "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"

# Configure Intel NVMe/SSD hardware hack for timeouts. Second part of this hack is configured after S2D is configured.
Write-Host " - Configure NVMe and SSD hardware timeout hack for Intel drives" -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\spaceport\Parameters" -Name "HwTimeout" -Value 16000

#endregion

#####################
#region END OF SCRIPT

Write-Host "Configuration completed."
Write-Host "Once all servers in cluster have run this script, please run Script 3 from a single node." -ForegroundColor Cyan
Write-Host "You will only need to run this on 1 of the nodes as it will connect to all nodes and configure the cluster automatically." -ForegroundColor Cyan

#endregion
