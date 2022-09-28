# Silence verbosity
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Log directory and file names for script output
$mirrorLogDir = '/var/log/OwlH/'
$mirrorLog = $mirrorLogDir + 'OwlHlog.txt'
$statCache = $mirrorLogDir + 'cache.clixml'

# Prod switch
# Update according to your environment
$prodSwitch = 'vmbr0'
# Vuln switch
# Update according to your environment
$vulnSwitch = 'vmbr1'

# Sniff interface 1
# Modify as needed based on VM ID
$tap1Name = 'veth208i1'
# Sniff interface 2
# Modify as needed based on VM ID
$tap2Name = 'veth208i2'

# Span port names for Open vSwitch
$span0Name = 'owlhProd'
$span1Name = 'owlhSec'

# Get the current I/O stats for the port mirrors
# Use this as a baseline to check for ongoing I/O
# If the next I/O check is higher, the mirror is working
$mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Where-Object name -like 'owlh*'

# Create log dirs/files as needed
if (-not (Test-Path $mirrorLogDir)) {
    New-Item -ItemType Directory -Path $mirrorLogDir -Force | Out-Null
    New-Item -ItemType File -Path $mirrorLog -Force | Out-Null
}
# Create the cache file for consecutive script runs to compare I/O
if (-not (Test-Path $statCache)) {
    New-Item -ItemType File -Path $statCache -Force | Out-Null
    $mirrorStats | Export-Clixml $statCache -Force
    break # First run, first cache. Stop execution.
}

if ($mirrorStats.count -lt 2) {
    # Recreate the mirrors and refresh data since there should always be a minimum of two
    # This is based on my lab environment, where I have two switches
    # https://benheater.com/proxmox-lab-wazuh-siem-and-nids/
    ovs-vsctl clear brge $prodSwitch mirrors 2>&1 > /dev/null
    ovs-vsctl clear brge $vulnSwitch mirrors 2>&1 > /dev/null
    ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge $prodSwitch mirrors=@m | Out-Null
    ovs-vsctl -- --id=@p get port $tap2Name -- --id=@m create mirror name=$span1Name select-all=true output-port=@p -- set bridge $vulnSwitch mirrors=@m | Out-Null
    Start-Sleep -Seconds 5
    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv
    if ($mirrorStats.Count -lt 2) {
        ovs-vsctl clear brge $prodSwitch mirrors 2>&1 > /dev/null
        ovs-vsctl clear brge $vulnSwitch mirrors 2>&1 > /dev/null
        Write-Output 'Stopping script, as the mirror count remains less than 2 after initial attempt to restart.' > $mirrorLog
    }
}
else {
    # Import the cache file to compare I/O on this run
    $cacheStats = Import-Clixml $statCache
    $cacheStats = $cacheStats | Sort-Object name
    $mirrorStats = $mirrorStats | Sort-Object name 
    
    # $mirrorStats will contain the CSV output from ovs-vsctl converted to object notation
    # Check the number of objects in the array
    # I'm pretty certain I added this logic in at one point cause I was testing mirroring on a third switch and didn't want the script to destroy break it
    if ($mirrorStats.count -gt $cacheStats.count) {
        Write-Output 'No action taken, as the number of current mirror ports exceeds that in the cache.' > $mirrorLog
        $mirrorStats | Export-Clixml $statCache -Force
    }
    else {
        # Take both SPAN port objectes and compare them individually against the current and cached I/O
        $currentSpan0 = $mirrorStats | Where-Object {$_.name -match $span0Name}
        $currentSpan1 = $mirrorStats | Where-Object {$_.name -match $span1Name}
        $cacheSpan0 = $cacheStats | Where-Object {$_.name -match $span0Name}
        $cacheSpan1 = $cacheStats | Where-Object {$_.name -match $span1Name}
        $currentSpan0txData = $currentSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $currentSpan1txData = $currentSpan1.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan0txData = $cacheSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan1txData = $cacheSpan1.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData

        if (($currentSpan0txData.tx_bytes -gt $cacheSpan0txData.tx_bytes) -or ($currentSpan1txData.tx_bytes -gt $cacheSpan1txData.tx_bytes))  {
	    # No problems, as tx_bytes property is larger than that in the cache
            Write-Output 'No action taken as current span TX data is greater than that in the cache.' > $mirrorLog
            $mirrorStats | Export-Clixml $statCache -Force
        }
        else {
	    # The cached bytes and the current span bytes are either non-existent or equal to the cached bytes
	    # Recreate the mirror
            Write-Output 'Recreated mirrors as current span TX data was equal to or older than that in the cache.' > $mirrorLog
	    ovs-vsctl clear brge $prodSwitch mirrors 2>&1 > /dev/null
            ovs-vsctl clear brge $vulnSwitch mirrors 2>&1 > /dev/null
            ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge $prodSwitch mirrors=@m | Out-Null
            ovs-vsctl -- --id=@p get port $tap2Name -- --id=@m create mirror name=span1Name select-all=true output-port=@p -- set bridge $vulnSwitch mirrors=@m | Out-Null
            Start-Sleep -Seconds 5
	    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv
	    $mirrorStats | Export-Clixml $statCache -Force
        }
    }
}
