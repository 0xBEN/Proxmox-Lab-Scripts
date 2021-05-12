$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$selksLogDir = '/var/log/SELKS/'
$selksLog = $selksLogDir + 'selkslog.txt'
$statCache = $selksLogDir + 'cache.clixml'
$tap1Name = 'tap103i1' # Modify as needed based on VM ID
$tap2Name = 'tap103i2' # Modify as needed based on VM ID
$span0Name = 'selksCyberRange'
$span1Name = 'selksProd'
$mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Where-Object name -like 'selks*'

if (-not (Test-Path $selksLogDir)) {
    New-Item -ItemType Directory -Path $selksLogDir -Force | Out-Null
    New-Item -ItemType File -Path $selksLog -Force | Out-Null
}
if (-not (Test-Path $statCache)) {
    New-Item -ItemType File -Path $statCache -Force | Out-Null
    $mirrorStats | Export-Clixml $statCache -Force
    break # First run, first cache. Stop execution.
}

if ($mirrorStats.count -lt 2) {
    # Recreate the mirrors and refresh data since there should always be a minimum of two
    ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge vmbr1 mirrors=@m | Out-Null
    ovs-vsctl -- --id=@p get port $tap2Name -- --id=@m create mirror name=$span1Name select-all=true output-port=@p -- set bridge vmbr0 mirrors=@m | Out-Null
    Start-Sleep -Seconds 5
    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv
    if ($mirrorStats.Count -lt 2) {
        Write-Output 'Stopping script, as the mirror count remains less than 2 after initial attempt to restart.' > $selksLog
    }
}
else {
    $cacheStats = Import-Clixml $statCache
    $cacheStats = $cacheStats | Sort-Object name
    $mirrorStats = $mirrorStats | Sort-Object name    
    if ($mirrorStats.count -gt $cacheStats.count) {
        Write-Output 'No action taken, as the number of current mirror ports exceeds that in the cache.' > $selksLog
        $mirrorStats | Export-Clixml $statCache -Force
    }
    else {
        $currentSpan0 = $mirrorStats | Where-Object {$_.name -match $span0Name}
        $currentSpan1 = $mirrorStats | Where-Object {$_.name -match $span1Name}
        $cacheSpan0 = $cacheStats | Where-Object {$_.name -match $span0Name}
        $cacheSpan1 = $cacheStats | Where-Object {$_.name -match $span1Name}
        $currentSpan0txData = $currentSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $currentSpan1txData = $currentSpan1.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan0txData = $cacheSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan1txData = $cacheSpan1.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData

        if (($currentSpan0txData.tx_bytes -gt $cacheSpan0txData.tx_bytes) -or ($currentSpan1txData.tx_bytes -gt $cacheSpan1txData.tx_bytes))  {
            Write-Output 'No action taken as current span TX data is greater than that in the cache.' > $selksLog
            $mirrorStats | Export-Clixml $statCache -Force
        }
        else {
            Write-Output 'Recreated mirrors as current span TX data was equal to or older than that in the cache.' > $selksLog
            ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge vmbr1 mirrors=@m | Out-Null
            ovs-vsctl -- --id=@p get port $tap2Name -- --id=@m create mirror name=span1Name select-all=true output-port=@p -- set bridge vmbr0 mirrors=@m | Out-Null
            Start-Sleep -Seconds 5
	    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv
	    $mirrorStats | Export-Clixml $statCache -Force
        }
    }
}
