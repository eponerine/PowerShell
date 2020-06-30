#!/bin/bash          

# INSTRUCTIONS:
#
# First, make sure you create the Agent Pool in TFS/ADO. Whatever you name it goes into the variable TFSAgentPoolName below.
#
# Once done, pull down this script into a working directory on the Ubuntu VM you want to make into a TFS Build Agent.
# You can either wget it, pull it from Git, or create a new file with Vim and copy/paste.
# Once completed, chmod +x it and run the script!

# Variables
TFSAgentUrl="https://vstsagentpackage.azureedge.net/agent/2.160.1/vsts-agent-linux-x64-2.160.1.tar.gz" # use choco somehow?
TFSServerUrl="https://dev.azure.com/<OrgHere>"
TFSAgentAuth="PAT"
TFSAgentAuthToken="xxxxxx-PAT-TOKEN-xxxxxxxxx"
TFSAgentPoolName="<PoolNameFromTFS>"
DotNetSDKURL="https://packages.microsoft.com/config/ubuntu/16.04/packages-microsoft-prod.deb"
NugetConfigURL="https://nuget.yoursitehere.com/nuget.txt"  # this is a hack to grab nuget.config without IIS bitching about file types

# Install Docker
apt-get update
apt-get -y remove docker docker-engine docker.io containerd runc
apt-get -y install apt-transport-https ca-certificates curl gnupg-agent software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io

# Install OpenSSH
apt-get -y install openssh-server

# Create the TFS Agent directory, download the archive, extract
mkdir /bin/tfsagent
cd /bin/tfsagent
wget -O agent.tar.gz $TFSAgentUrl
tar zxf agent.tar.gz
chmod -R 777 .

# Copy the plain-text nuget.config file from Nuget webserver
wget -O nuget.config $NugetConfigURL

# Disable firewall
ufw disable

# Install TFS prereqs
./bin/installdependencies.sh

# Install .NET Core 2.2 and 3.0 SDK
# Info: https://docs.microsoft.com/en-us/dotnet/core/install/linux-package-manager-ubuntu-1604
wget -q $DotNetSDKURL
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get install apt-transport-https
sudo apt-get update
sudo apt-get -y install dotnet-sdk-2.2
sudo apt-get -y install dotnet-sdk-3.1

# Update Git to the latest version
sudo add-apt-repository ppa:git-core/ppa -y
sudo apt-get update
sudo apt-get install git -y
git --version

# Configure agent as root
export AGENT_ALLOW_RUNASROOT=1

/bin/tfsagent/config.sh --unattended --url "$TFSServerUrl" --auth "$TFSAgentAuth" --token "$TFSAgentAuthToken" --pool "$TFSAgentPoolName" --runAsService 
/bin/tfsagent/svc.sh install
/bin/tfsagent/svc.sh start
