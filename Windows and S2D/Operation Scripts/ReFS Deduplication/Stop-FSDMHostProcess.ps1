$clusterName = "CLUSTERNAME.foo.bar"

$clusterNodes = Get-Cluster -Name $clusterName | Get-ClusterNode

ForEach ($n in $clusterNodes) {
    Write-Host "$($n.Name) - Stopping FSDMHost.exe process" -ForegroundColor Cyan
    Invoke-Command -ComputerName $n.Name -ScriptBlock { Get-Process | ? Name -like "*fsdmhost*" | Stop-Process -Force }
}