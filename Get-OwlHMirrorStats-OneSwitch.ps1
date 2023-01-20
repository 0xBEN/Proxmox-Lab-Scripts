# Silence verbosity
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Log directory and file names for script output
$mirrorLogDir = '/var/log/OwlH/'
$mirrorLog = $mirrorLogDir + 'OwlHlog.txt'
$statCache = $mirrorLogDir + 'cache.clixml'
$guestCache = $mirrorLogDir + 'guest-cache.txt'

# Lab switch
# Update according to your environment
$labSwitch = 'vmbr0'

# Sniff interface 1
# Modify as needed based on VM ID
$tap1Name = 'veth208i1'

# Span port names for Open vSwitch
$span0Name = 'owlhLab'

# Get the current I/O stats for the port mirrors
# Use this as a baseline to check for ongoing I/O
# If the next I/O check is higher, the mirror is working
$mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Where-Object name -like 'owlh*'

# Get the current running guests
# Use this as a baseline to check if any guests have started or stopped
# Mirrors need to be reconfigured if any hosts are started or stopped
$cachedGuestIDs = Get-Content $guestCache
$vms = /usr/sbin/qm list | grep running
$vms = $vms -replace '^\s{1,}', '' # Get rid of whitespace at the star of the string
$containers = /usr/sbin/pct list | grep running
$guests = $vms + $containers
$guestIDs = $guests.ForEach({$_.Split(' ')[0]})
$guestIDs > $guestCache

# Create log dirs/files as needed
if (-not (Test-Path $mirrorLogDir)) {
    New-Item -ItemType Directory -Path $mirrorLogDir -Force | Out-Null
    New-Item -ItemType File -Path $mirrorLog -Force | Out-Null
}
# Create the cache file for consecutive script runs to compare I/O
if (-not (Test-Path $statCache)) {
    New-Item -ItemType File -Path $statCache -Force | Out-Null
    $mirrorStats | Export-Clixml $statCache -Force
}
# Create the cache file to check if any guests have started or stopped between mirror configuration checks
if (-not (Test-Path $guestCache)) {
    New-Item -ItemType -Path $guestCache -Force | Out-Null
    $guestIDs > $guestCache
    break # First run, first cache. Stop execution.   
}

if ($mirrorStats.count -lt 1) {

    # Recreate the mirrors and refresh data since there should always be a minimum of two
    # This is based on my lab environment, where I have two switches
    # https://benheater.com/proxmox-lab-wazuh-siem-and-nids/
    ovs-vsctl clear Brige $labSwitch mirrors 2>&1 > /dev/null
    ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge $labSwitch mirrors=@m | Out-Null
    Start-Sleep -Seconds 5
    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Where-Object name -like 'owlh*'
    if ($mirrorStats.Count -lt 1) {
        ovs-vsctl clear Brige $labSwitch mirrors 2>&1 > /dev/null
        Write-Output 'Stopping script, as the mirror count remains less than 1 after initial attempt to restart.' > $mirrorLog
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
    
        # Take both SPAN port objects and compare them individually against the current and cached I/O
        $currentSpan0 = $mirrorStats | Where-Object {$_.name -match $span0Name}
        $cacheSpan0 = $cacheStats | Where-Object {$_.name -match $span0Name}
        $currentSpan0txData = $currentSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
        $cacheSpan0txData = $cacheSpan0.statistics -replace '{' -replace '}' -split ', ' | ConvertFrom-StringData
	
	if ($guestIDs.Count -ne $cachedGuestIDs.Count) {
	    # Reconfigure port mirrors because the number of guests is greater or less than the cached amount
	    Write-Output 'A guest or guests have either been added/removed/started/stopped between checks. Mirrors will be reconfigured.' > $mirrorLog
	    ovs-vsctl clear Brige $labSwitch mirrors 2>&1 > /dev/null
            ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge $labSwitch mirrors=@m | Out-Null
            Start-Sleep -Seconds 5
	    $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Where-Object name -like 'owlh*'
	    $mirrorStats | Export-Clixml $statCache -Force	    
	}
	else {
	
            if ($currentSpan0txData.tx_bytes -gt $cacheSpan0txData.tx_bytes)  {
	        # No problems, as tx_bytes property is larger than that in the cache
                Write-Output 'No action taken as current span TX data is greater than that in the cache.' > $mirrorLog
                $mirrorStats | Export-Clixml $statCache -Force
            }
            else {
	        # The cached bytes and the current span bytes are either non-existent or equal to the cached bytes
	        # Recreate the mirror
                Write-Output 'Recreated mirrors as current span TX data was equal to or older than that in the cache.' > $mirrorLog
	        ovs-vsctl clear Brige $labSwitch mirrors 2>&1 > /dev/null
                ovs-vsctl -- --id=@p get port $tap1Name -- --id=@m create mirror name=$span0Name select-all=true output-port=@p -- set bridge $labSwitch mirrors=@m | Out-Null
                Start-Sleep -Seconds 5
	        $mirrorStats = ovs-vsctl --format=csv list mirror | ConvertFrom-Csv | Where-Object name -like 'owlh*'
	        $mirrorStats | Export-Clixml $statCache -Force
	    }
	    
        }
	
    }
    
}
