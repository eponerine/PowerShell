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
$pageFileSizeBytes               = $clusterData.pageFileSizeBytes
$interfaceDesc                   = $clusterData.interfaceDescription
$interfaceName                   = $clusterData.interfaceName

#$interfaces                      = $clusterData.interfaces
$embeddedSwitches                = $clusterData.embeddedSwitches

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
$netATCEnabled                   = $clusterData.netATCEnabled
$SDNEnabled                      = $clusterData.SDNEnabled
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
#region CREATE AND CONFIGURE SET VM SWITCHES (SWITCH EMBEDDED TEAMING)

# Create the SET Switch and add the correct pNIC's to it. Don't create Management OS vNICs; we'll do that later
Write-Host "Creating SET Switch and adding all pNICs with matching name prefix" -ForegroundColor Cyan

ForEach ($v in $embeddedSwitches) {
    Write-Host "Configuring SET Switch - $($v.name)" -ForegroundColor Cyan
    $interfacesToAdd = Get-NetAdapter | ? Name -like "*$($v.memberNamePrefix)*"
    Write-Host " - Adding following interfaces:"
    $interfacesToAdd
    New-VMSwitch -Name $v.name -AllowManagementOS $false -EnableEmbeddedTeaming $true -EnableIov $true -NetAdapterInterfaceDescription $interfacesToAdd.InterfaceDescription | Out-Null
}

#endregion

##############################################
#region CONFIGURE MANAGEMENT vNICs

Write-Host "Configuring vNICs" -ForegroundColor Cyan

# Create Management vNIC and configure network settings
Write-Host " - Adding Management vNIC" -ForegroundColor Yellow
$targetSwitch = $embeddedSwitches | ? isMgmt -like $true

Add-VMNetworkAdapter -SwitchName $targetSwitch.name -Name $mgmtName -ManagementOS
Set-VMNetworkAdapterVlan -VMNetworkAdapterName $mgmtName -VlanId $mgmtVLAN -Access -ManagementOS

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

##############################################
#region CONFIGURE SMB vNICs

$targetSwitch = $embeddedSwitches | ? isStorage -like $true

# We may have multiple vSwitches need separate SMB interfaces configured (on diff VLANs)
ForEach ($s in $targetSwitch) {
    # Get the pNICs bound to that vSwitch and use the count to determine how many vNICs to create
    Write-Host " - Configuring vSwitch $($s.name)" -ForegroundColor Yellow
    $tempCurrentSwitch = Get-VMSwitch -Name $s.Name
    
    For ($i = 1; $i -le $tempCurrentSwitch.NetAdapterInterfaceDescriptions.count; $i++) {
        
        $tempName = "$($s.storageName)-$($s.storageVLAN) $i"
        Write-Host "   - Creating storage vNIC: $tempName" -ForegroundColor Magenta
        Add-VMNetworkAdapter -SwitchName $s.name -Name $tempName -ManagementOS
        Start-Sleep 5
        $tempvNIC = Get-VMNetworkAdapter -Name $tempName -ManagementOS
        Set-VMNetworkAdapterVlan -VMNetworkAdapterName $tempName -VlanId $s.storageVLAN -Access -ManagementOS
        
        # Build out the IP for storage vNICs
        $mgmtIPArray = $mgmtIP.split('.')
        $storageIPArray = $s.storageCIDR.split('.')
        $storageIPArray[2] = $mgmtIPArray[3]
        $storageIPArray[3] = $i
        $tempStorageIP = ($storageIPArray -join '.')
        
        # Set the IP address
        Write-Host "   - IP: $tempStorageIP"
        Get-NetAdapter | ? Name -like "*$tempName*" | New-NetIPAddress -IPAddress $tempStorageIP -PrefixLength $s.storageSubnet | Out-Null
        
        #Enable RDMA
        Write-Host "   - Enable RDMA"
        Get-NetAdapter | ? Name -like "*$tempName*" | Enable-NetAdapterRdma
                
        # Disable DNS registration on all Storage NICs
        Write-Host "   - Disable DNS registration"
        Get-NetAdapter | ? Name -like "*$tempName*" | Set-DNSClient -RegisterThisConnectionsAddress $False
    }
}

Write-Host " - Sleeping for 5 seconds and clearing DNS cache" -ForegroundColor Yellow
Start-Sleep 5
Clear-DnsClientCache

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
New-NetQosPolicy "Default"          -Default                         -PriorityValue8021Action 0 | Out-Null
New-NetQosPolicy "SMB"              -NetDirectPortMatchCondition 445 -PriorityValue8021Action 3 | Out-Null
New-NetQosPolicy "ClusterHeartbeat" -Cluster                         -PriorityValue8021Action 7 | Out-Null

Write-Host " - Configure Priority Flow Control (PFC)" -ForegroundColor Yellow
Enable-NetQosFlowControl -Priority 3
Disable-NetQosFlowControl -Priority 0,1,2,4,5,6,7

Write-Host " - Apply QoS policy to all pNICs (but not LOM, OOB, DRAC, etc)" -ForegroundColor Yellow
Get-NetAdapter | ? InterfaceDescription -like "*$interfaceDesc*" | Get-NetAdapterQos | Enable-NetAdapterQos | Out-Null

# Configure DCB minimum bandwidth (Default = 49%, SMB Direct = 50%, Cluster Heartbeat = 1%)
Write-Host " - Set minimum bandwidth for Default (39%), SMB Direct (60%), and Cluster Heartbeat (1%)" -ForegroundColor Yellow
New-NetQosTrafficClass "SMB"              -Priority 3 -BandwidthPercentage 50 -Algorithm ETS | Out-Null
New-NetQosTrafficClass "ClusterHeartbeat" -Priority 7 -BandwidthPercentage 1 -Algorithm ETS | Out-Null

# Configure Live Migration SMB Bandwidth Limit
Write-Host " - Configure Live Migration SMB Bandwidth Limit to 40% of total bandwidth" -ForegroundColor Yellow
$physicalInterfaces = Get-NetAdapter | ? InterfaceDescription -like "*$interfaceDesc*"
$bytesPerSecond = ($physicalInterfaces | Select TransmitLinkSpeed | Measure-Object -Sum TransmitLinkSpeed).Sum / 8
Write-Host "  - Total Bytes/Sec: $bytesPerSecond"
Set-SmbBandwidthLimit -Category LiveMigration -BytesPerSecond ($bytesPerSecond*0.4)

# Disable traditional Flow Control on the Storage pNICs
Write-Host " - Disable traditional Flow Control on pNICs" -ForegroundColor Yellow
Get-NetAdapter | ? InterfaceDescription -like "*$interfaceDesc*" | Set-NetAdapterAdvancedProperty -RegistryKeyword "*FlowControl" -RegistryValue 0
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
$pagefile.InitialSize = $pageFileSizeBytes
$pagefile.MaximumSize = $pageFileSizeBytes
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