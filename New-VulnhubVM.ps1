[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({$_.Host -eq 'download.vulnhub.com'})]
    [System.Uri]
    $VulnhubURI,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path $_)) {
            throw "Specified path does not exist:`n$_"
        }
        else {
            return $true
        }
    })]
    [String]
    $DownloadDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        $id = $_
        $id -ge 0
        if (Invoke-Command -ScriptBlock {qm status $id 2>/dev/null}) {
            throw "VM with ID: $id already exists."
        }
        elseif (Invoke-Command -ScriptBlock {pct status $id 2>/dev/null}) {
            throw "Container with ID: $id already exists."
        }
        else {
            return $true
        }
    })]
    [Int]
    $VMID,

    [Parameter(
        Mandatory = $true,
        HelpMessage = 'other: unspecified OS; wxp: Windows XP; w2k: Windows 2000; w2k3: Windows 2003; w2k8: Windows 2008; wvista: Windows Vista; win7: Windows 7; win8: Windows 8; win10: Windows 10; l24: Linux Kernel 2.4; l26: Linux Kernel 2.6; solaris: Solaris/OpenSolaris/OpenIndiana kernel'
    )]
    [ValidateSet('other', 'wxp', 'w2k', 'w2k3', 'w2k8', 'wvista', 'win7','win8', 'win10', 'l24', 'l26', 'solaris')]
    [String]
    $GuestOSType,

    [Parameter(
        Mandatory = $true,
        HelpMessage = 'Example: local-lvm. This is where the guest boot disk will be stored on the Proxmox node.'
    )]
    [ValidateScript({
        if (-not (pvesm list $_ 2>/dev/null)) {
            throw "Storage volume: $_ does not exist."
        }
        else {
            return $true
        }
    })]
    [String]
    $VMDiskStorageVolume,

    [Parameter(HelpMessage = 'Example: vmbr0')]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if (-not (ip link show $_)) {
            throw "Network interface not found."
        }
        else {
            return $true
        }
    })]
    [String]
    $NetworkBridge,

    [Parameter(HelpMessage = 'Enter an integer between 0 and 4094')]
    [ValidateRange(0,4094)]
    [Int]
    $VlanTag,

    [Parameter(HelpMessage = 'Strictly for administrative purposes only.')]
    [ValidateNotNullOrEmpty()]
    [String]
    $VMName,

    [Parameter(HelpMessage = 'Example: 2048')]
    [Int]
    $MemoryMiB
)
begin {
     
    if (-not (which unar)) {
        throw "This script requires the program, unar, which is a single archive decompression tool that works on a variety or archive types.`nPlease install that program and re-run the script."
    }
    
    function Find-VMDK ($Directory) {
        
        $files = Get-ChildItem $Directory -Recurse
        $vmdk = $files | Where-Object {$_.Extension -eq '.vmdk'}
        if (-not $vmdk) {
            $files | ForEach-Object {
                $file = $_
                $type = file $file.FullName
                $isArchive = $type -like '*archive*' -or $type -like '*compressed*'
                if ($isArchive) {
                    Write-Host "Nested archive found: " -NoNewLine
		    Write-Host $file.FullName -ForegroundColor Green
                    $archiveFileFound = $file
                }
            }
            if ($archiveFileFound) {
                $subdirectory = "$Directory/temp$(Get-Random)"
                unar $archiveFileFound.FullName -o $subdirectory
                Find-VMDK -Directory $subdirectory
            }
            else {
                throw "No .vmdk file found and finished recursively checking for archives without results."
            }
        }
        else {
            return $vmdk
        }

    }
    
    if (-not [System.IO.Path]::EndsInDirectorySeparator($DownloadDirectory)) { $DownloadDirectory = $DownloadDirectory + '/'  }
    $fileName = $VulnhubURI.Segments[-1] # Define the download file name based on the URI provided.
    if ($fileName -like '*.iso') { throw "Creating VMs from ISO files not yet implemented." }
    $downloadPath = $DownloadDirectory + $fileName
    $archiveOutputDirectory = $DownloadDirectory + "temp$(Get-Random)"
    $parameterCollection = @()
    $parameterCollection += "--ostype $GuestOSType"
    $parameterCollection += "--storage $VMDiskStorageVolume"
    if ($PSBoundParameters['NetworkBridge']) { 
        if ($PSBoundParameters['VlanTag']) {
            $parameterCollection += "--net0 model=virtio,bridge=$NetworkBridge,firewall=0,tag=$VlanTag"         
        }
        else {
            $parameterCollection += "--net0 model=virtio,bridge=$NetworkBridge,firewall=0" 
        }
    }
    if ($PSBoundParameters['VMName']) { $parameterCollection += "--name $VMName" }
    if ($PSBoundParameters['MemoryMiB']) { $parameterCollection += "--memory $MemoryMiB" }        
    $parameterString = $parameterCollection -join ' '    
    
}
process {

    Write-Host "Downloading VM from Vulnhub. Please be patient..." -ForegroundColor Green
    wget $VulnhubURI.ToString() -q --show-progress -O $downloadPath
    $downloadedVM = Get-ChildItem $downloadPath
    try {
	Write-Host "Decompressing archive: $downloadedVM to $archiveOutputDirectory" -ForegroundColor Green
        Write-Host "This may take a while depending on the size of the archive." -ForegroundColor Yellow
	unar $downloadedVM.FullName -o $archiveOutputDirectory
    }
    catch {
        throw "Error expanding archive:`n$_"
    }
    
    try {
        Get-ChildItem $archiveOutputDirectory -Recurse | ForEach-Object { # Arbitrarily try to remove any whitespace in file path, as this has been an issue before
	   $removeWhiteSpace = $_.FullName -replace ' ', '_'
           if ($removeWhiteSpace -ne $_.FullName) {
               Move-Item $_.FullName $removeWhiteSpace
           }
        }
	Write-Host "Searching for the .vmdk disk file(s) in $archiveOutputDirectory" -ForegroundColor Green
        $vmDisk = Find-VMDK -Directory $archiveOutputDirectory
        $vmDisk = Find-VMDK -Directory $archiveOutputDirectory # Rediscover the renamed disks

	Write-Host "Attempting to convert the VMDK file(s) to QCOW2 to support snapshots." -ForegroundColor Green
	$qcow2Disks = @()
	$vmDisk | ForEach-Object {
	    $vmdkfile = $_
	    $qcow2file = $vmdkfile.FullName -replace 'vmdk', 'qcow2'
	    $qcow2Disks += $qcow2file
	    Start-Process qemu-img -ArgumentList "convert -f vmdk -O qcow2 $($vmdkfile.FullName) $qcow2file" -Wait
	}
    }
    catch {
        Get-Item $downloadPath, $archiveOutputDirectory | Remove-Item -Recurse -Force # Clean up any artifacts after error.
        throw $_
    }

    try {
        Write-Host "Attempting to create the VM with the following command: qm create $VMID $parameterString." -ForegroundColor Green
        Start-Process qm -ArgumentList "create $VMID $parameterString" -Wait -RedirectStandardOutput /dev/null

        Write-Host "Attempting to import the QCOW2 file(s) as a disk." -ForegroundColor Green
        $qcow2Disks | ForEach-Object {
            $disk = $_
            Write-Host "Running command: qm importdisk $VMID $disk $VMDiskStorageVolume --format qcow2" -ForegroundColor Green
            Start-Process qm -ArgumentList "importdisk $VMID $disk $VMDiskStorageVolume --format qcow2" -Wait -RedirectStandardOutput /dev/null
        }

        $iteration = 0
        $qcow2Disks | ForEach-Object {
            Write-Host "Attempting to attach the disk to the VM's SATA controller." -ForegroundColor Green
            Write-Host "Running command: qm set $VMID --sata$iteration $($VMDiskStorageVolume):$VMID/vm-$VMID-disk-$iteration" -ForegroundColor Green
            Start-Process qm -ArgumentList "set $VMID --sata$iteration $($VMDiskStorageVolume):$VMID/vm-$VMID-disk-$iteration" -Wait -RedirectStandardOutput /dev/null
            $iteration++
        }

        Write-Host "Setting sata0 as the boot device." -ForegroundColor Green
        Start-Process qm -ArgumentList "set $VMID --boot=`"order=sata0`"" -Wait -RedirectStandardOutput /dev/null

        Write-Host "All commands completed successfully" -ForegroundColor Green
    }
    catch {
        throw "Command failed with the following error:`n$_"
    }

}
end {

    if ((Test-Path $downloadPath -ErrorAction SilentlyContinue) -or (Test-Path $archiveOutputDirectory -ErrorAction SilentlyContinue)) {
        Write-Host "Removing any files created by the script." -ForegroundColor Green
        Remove-Item $downloadPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null   
        Remove-Item $archiveOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue | Out-Null   
    }

}
 
