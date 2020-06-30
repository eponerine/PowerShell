$clusterName   = "CLUSTERNAME.foo.bar"

$clusterNodes = Get-Cluster -Name $clusterName | Get-ClusterNode

ForEach ($n in $clusterNodes) {
    Write-Host $n.Name -ForegroundColor Cyan
    Invoke-Command -ComputerName $n.Name -ScriptBlock { Get-DedupJob | FT Type, ScheduleType, StartTime, Progress, State, Volume }
}