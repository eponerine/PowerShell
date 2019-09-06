$clusterName   = "CLUSTERNAME.foo.bar"
$dedupJobType  = "Optimization"              # GarbageCollection, Optimization

$clusterNodes = Get-Cluster -Name $clusterName | Get-ClusterNode

ForEach ($n in $clusterNodes) {
    Write-Host "$($n.Name) - Stopping $dedupJobType jobs" -ForegroundColor Cyan
    Invoke-Command -ComputerName $n.Name -ArgumentList $dedupJobType -ScriptBlock {
        Get-DedupJob -Type $args[0] | Stop-DedupJob
    }
}