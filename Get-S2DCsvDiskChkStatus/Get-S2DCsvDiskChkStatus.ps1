# Change this name to match your cluster
$clusterName = "XXXXXXXXXXXXX"

############################
#    Script starts here
############################

# Gather cluster information (nodes, CSVs)
$cluster = Get-Cluster -Name $clusterName
$clusterNodes = $cluster | Get-ClusterNode
$clusterVolumes = $cluster | Get-ClusterSharedVolume

# Check each node...
ForEach ($node in $clusterNodes) {

    Write-Host "Checking $node..." -ForegroundColor Cyan

    # Check the CSV's value in reg
    ForEach ($csv in $clusterVolumes) {

        # Store the returned registry values in a temp variable
        $regDiskRunChkDsk = Invoke-Command -ComputerName $node.Name -ArgumentList $csv.Id -ScriptBlock { Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\Cluster\Resources\$($args[0])\Parameters" -Name DiskRunChkDsk }
        $regDiskRecoveryAction = Invoke-Command -ComputerName $node.Name -ArgumentList $csv.Id -ScriptBlock { Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\Cluster\Resources\$($args[0])\Parameters" -Name DiskRecoveryAction }

        # Verbosely report values if something is not 0/0
        If ($regDiskRunChkDsk.DiskRunChkDsk -ne 0 -or $regDiskRecoveryAction.DiskRecoveryAction -ne 0) {

            Write-Host " - CSV Name: $($csv.Name)" -ForegroundColor Yellow
            Write-Host "   CSV GUID: $($csv.Id)"
            Write-Host "   DiskRunChkDsk: $($regDiskRunChkDsk.DiskRunChkDsk)"
            Write-Host "   DiskRecoveryAction: $($regDiskRecoveryAction.DiskRecoveryAction)"
        }
    }

}