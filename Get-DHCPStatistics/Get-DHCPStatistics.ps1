function ConvertTo-DecimalIP {
  <#
    .Synopsis
      Converts a Decimal IP address into a 32-bit unsigned integer.
    .Description
      ConvertTo-DecimalIP takes a decimal IP, uses a shift-like operation on each octet and returns a single UInt32 value.
    .Parameter IPAddress
      An IP Address to convert.
  #>
  
  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [Net.IPAddress]$IPAddress
  )
 
  process {
    $i = 3; $DecimalIP = 0;
    $IPAddress.GetAddressBytes() | ForEach-Object { $DecimalIP += $_ * [Math]::Pow(256, $i); $i-- }
 
    return [UInt32]$DecimalIP
  }
}


$DHCPScopes = Get-DHCPServerV4Scope

ForEach ($Scope in $DHCPScopes)
{
    $ScopeName = $Scope.Name
    
    # Calculate number of total leases in scope
    $ScopeStartDecimal = ConvertTo-DecimalIP($Scope.StartRange)
    $ScopeEndDecimal = ConvertTo-DecimalIP($Scope.EndRange)
    $ScopeSize = $ScopeEndDecimal - $ScopeStartDecimal

    # Get a count of all the issued IP addresses
    $Lease = Get-DHCPServerV4Lease -ScopeID $Scope.ScopeId
    $LeaseCount = $Lease.Count
    
    # Write info to console
    Write-Host ("Scope: " + $ScopeName)
    Write-Host ("Size: " + $ScopeSize)
    Write-Host ("Leases: " + $LeaseCount)
    Write-Host ("Available: " + ($ScopeSize - $LeaseCount))
}