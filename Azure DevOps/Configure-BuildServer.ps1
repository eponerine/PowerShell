# TFSAgentURL should be revamped to use Chocolatey to grab latest version:
# https://chocolatey.org/packages/azure-pipelines-agent
$TFSAgentUrl       = "https://vstsagentpackage.azureedge.net/agent/2.164.6/vsts-agent-win-x64-2.164.6.zip"
$TFSAgentPath      = "C:\TFSAgent"
$TFSServerUrl      = "https://dev.azure.com/<OrgName>"
$TFSAgentAuth      = "PAT"
$TFSAgentSvcUser   = "NT AUTHORITY\LocalSystem"
$TFSAgentAuthToken = "xxxxxxxxxxxxx-PAT-TOKEN-xxxxxxxxxxxxx"
$TFSAgentPoolName  = "<PoolNameFromTFS>"

# Disable Windows Firewall
Write-Output "###################################################"
Write-Output "Disable Firewall"
Write-Output "###################################################"
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Install Chocolatey
Write-Output "###################################################"
Write-Output "Install Chocolatey"
Write-Output "###################################################"
Install-PackageProvider -Name Chocolatey -Force # this needs to be removed completely
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

# Delete the working directory if it exists and recreate it
If (Test-Path -Path $TFSAgentPath) {
    Write-Output "- Delete $TFSAgentPath"
    Remove-Item -Path $TFSAgentPath -Recurse -Force
}
Write-Output "###################################################"
Write-Output "Create $TFSAgentPath"
Write-Output "###################################################"
New-Item -Path $TFSAgentPath -ItemType Directory

# Uncomment this to copy custom NuGet.config file
#Copy-Item -Path ".\NuGet.config" -Destination $TFSAgentPath

# Change to working directory
Set-Location -Path $TFSAgentPath

# Download the agent
Write-Output "###################################################"
Write-Output "Download TFS Agent"
Write-Output "###################################################"
Invoke-WebRequest -Uri $TFSAgentUrl -OutFile "$TFSAgentPath\tfsagent.zip"  # this all goes away with Chocolatey handling

# Extract the agent archive
Write-Output "###################################################"
Write-Output "Extract TFS Agent archive"
Write-Output "###################################################"
$agentArchive = Get-ChildItem -Path $TFSAgentPath | ? Name -like "tfsagent.zip"
Expand-Archive $agentArchive.FullName -DestinationPath $TFSAgentPath -Force

# Install the agent with arguments
Write-Output "###################################################"
Write-Output "Install TFS Agent and configure"
Write-Output "###################################################"
Start-Process ".\config.cmd" -ArgumentList "--unattended","--url $TFSServerUrl","--auth $TFSAgentAuth","--token $TFSAgentAuthToken","--pool `"$TFSAgentPoolName`"","--runAsService","--windowsLogonAccount `"$TFSAgentSvcUser`""
$serviceName = Get-Service | ? Name -like "*tfs*" | Select -ExpandProperty Name
Start-Process -FilePath "sc.exe" -ArgumentList "config $serviceName","obj=`".\LocalSystem`"","password= `"`""

# Download .NET Core installer script and run it
Write-Output "###################################################"
Write-Output "Install .NET Core"
Write-Output "###################################################"
Install-Package -Name dotnetcore-sdk -Force # TODO: use raw choco

# Install Hyper-V
Write-Output "###################################################"
Write-Output "Install Hyper-V"
Write-Output "###################################################"
Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature

# Install Docker
Write-Output "###################################################"
Write-Output "Install Docker"
Write-Output "###################################################"
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force

#TODO: REBOOT?