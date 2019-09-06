$name = "FOOBAR"

# Get the Cluster Group, Cluster Resources, and the actual Hyper-V VM
$clusterGroup    = Get-ClusterGroup | ? Name -Like $name
$clusterResource = $clusterGroup | Get-ClusterResource
$clusterVm       = $clusterResource | ? ResourceType -Like "Virtual Machine" | Get-VM

# Remove the Cluster Group and its resources from the Cluster. This will not prompt for confirmation.
$clusterGroup | Remove-ClusterGroup -Force -RemoveResources

# Get the VMs VHDX files (Remove-VM only deletes the config)
$clusterVmDisks  = $clusterVm | Get-VMHardDiskDrive

# Delete the VHDXs
$clusterVmDisks | ForEach { Remove-Item -Path $_.Path -Recurse -Force -Confirm:$false }

# Delete the VM
$clusterVm | Remove-VM -Force -Confirm:$false

# This will leave behind a few empty directories. You'll need to do some recursive Get-Item magic to get parents until you're at the top-most level of the folder