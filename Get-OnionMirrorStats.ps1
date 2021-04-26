$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$onionLogDir = '/var/log/securityonion/'
$onionLog = $onionLogDir + 'onionlog.txt'
$statCache = $onionLogDir + 'cache.clixml'
$mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv

if (-not (Test-Path $onionLogDir)) {
    New-Item -ItemType Directory -Path $onionLogDir -Force | Out-Null
    New-Item -ItemType File -Path $onionLog -Force | Out-Null
}
if (-not (Test-Path $statCache)) {
    New-Item -ItemType File -Path $statCache -Force | Out-Null
    $mirrorStats | Export-Clixml $statCache -Force
    break # First run, first cache. Stop execution.
}

if ($mirrorStats.count -lt 2) {
    # Recreate the mirrors and refresh data since there should always be a minimum of two
    ovs-vsctl -- --id=@p get port tap102i1 -- --id=@m create mirror name=span0 select-all=true output-port=@p -- set bridge vmbr1 mirrors=@m | Out-Null
    ovs-vsctl -- --id=@p get port tap102i2 -- --id=@m create mirror name=span1 select-all=true output-port=@p -- set bridge vmbr0 mirrors=@m | Out-Null
    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv
    if ($mirrorStats.Count -lt 2) {
        Write-Output 'Stopping script, as the mirror count remains less than 2 after initial attempt to restart.' > $onionLog
    }
}
else {
    $cacheStats = Import-Clixml $statCache
    $cacheStats = $cacheStats | Sort-Object name
    $mirrorStats = $mirrorStats | Sort-Object name    
    if ($mirrorStats.count -gt $cacheStats.count) {
        Write-Output 'No action taken, as the number of current mirror ports exceeds that in the cache.' > $onionLog
        $mirrorStats | Export-Clixml $statCache -Force
    }
    else {
        $currentSpan0 = $mirrorStats | Where-Object {$_.name -eq 'span0'}
        $currentSpan1 = $mirrorStats | Where-Object {$_.name -eq 'span1'}
        $cacheSpan0 = $cacheStats | Where-Object {$_.name -eq 'span0'}
        $cacheSpan1 = $cacheStats | Where-Object {$_.name -eq 'span1'}
        $currentSpan0txData = $currentSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $currentSpan1txData = $currentSpan1.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan0txData = $cacheSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan1txData = $cacheSpan1.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData

        if (($currentSpan0txData.tx_bytes -gt $cacheSpan0txData.tx_bytes) -and ($currentSpan1txData.tx_bytes -gt $cacheSpan1txData.tx_bytes))  {
            Write-Output 'No action taken as all current span TX data is greater than that in the cache.' > $onionLog
            $mirrorStats | Export-Clixml $statCache -Force
        }
        else {
            Write-Output 'Recreated mirrors as current span TX data was equal to or older than that in the cache.' > $onionLog
            ovs-vsctl -- --id=@p get port tap102i1 -- --id=@m create mirror name=span0 select-all=true output-port=@p -- set bridge vmbr1 mirrors=@m | Out-Null
            ovs-vsctl -- --id=@p get port tap102i2 -- --id=@m create mirror name=span1 select-all=true output-port=@p -- set bridge vmbr0 mirrors=@m | Out-Null
            ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Export-Clixml $statCache -Force
        }
    }
}
