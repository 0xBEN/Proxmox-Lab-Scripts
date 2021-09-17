[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({Test-Path $_})]
    [String]
    $FilePath,

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
    [ValidateSet('other', 'wxp', 'w2k', 'w2k3', 'w2k8', 'wvista', 'win7',' win8', 'win10', 'l24', 'l26', 'solaris')]
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
                    Write-Host $isArchive.FullName -ForegroundColor Green
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
   
    $FilePath = Resolve-Path $FilePath # In case a relative path is specified 
    if ($FilePath -like '*.iso') { throw "Creating VMs from ISO files not yet implemented." }
    elseif ($FilePath -like '*.vmdk') { $gotVmdk = $true }    
    else { $archiveOutputDirectory = $FilePath + "-temp$(Get-Random)" }
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

    if (-not $gotVmdk) {

	try {
	    Write-Host "Extracting files to $archiveOutputDirectory" -ForegroundColor Green
            unar $FilePath -o $archiveOutputDirectory
        }
        catch {
            throw "Error expanding archive:`n$_"
        }
    
        try {
            Get-ChildItem $archiveOutputDirectory -Recurse | 
	    ForEach-Object {# Arbitrarily try to remove any whitespace in file path, as this has been an issue before
               $removeWhiteSpace = $_.FullName -replace ' ', '_'
	       if ($removeWhiteSpace -ne $_.FullName) {
	           Move-Item $_.FullName $removeWhiteSpace
	       }
            }
            $vmDisk = Find-VMDK -Directory $archiveOutputDirectory
            $vmDisk = Find-VMDK -Directory $archiveOutputDirectory # Rediscover the renamed disks
        }
        catch {
            Get-Item $archiveOutputDirectory | Remove-Item -Recurse -Force # Clean up any artifacts after error.
            throw $_
        }
    }
    else {
        
        $vmDisk = Get-ChildItem $FilePath

    }

    try {
        Write-Host "Attempting to create the VM with the following command: qm create $VMID $parameterString." -ForegroundColor Green
        Start-Process qm -ArgumentList "create $VMID $parameterString" -Wait -RedirectStandardOutput /dev/null

        Write-Host "Attempting to import the VMDK file(s) as a disk." -ForegroundColor Green
        $vmDisk | ForEach-Object {
            $disk = $_
            Write-Host "Running command: qm importdisk $VMID $($disk.FullName) $VMDiskStorageVolume --format vmdk" -ForegroundColor Green
            Start-Process qm -ArgumentList "importdisk $VMID $($disk.FullName) $VMDiskStorageVolume --format vmdk" -Wait -RedirectStandardOutput /dev/null
        }

        $iteration = 0
        $vmDisk | ForEach-Object {
            Write-Host "Attempting to attach the disk to the VM's SATA controller." -ForegroundColor Green
            Write-Host "Running command: qm set $VMID --sata$iteration $($VMDiskStorageVolume):$VMID/vm-$VMID-disk-$iteration.vmdk" -ForegroundColor Green
            Start-Process qm -ArgumentList "set $VMID --sata$iteration $($VMDiskStorageVolume):$VMID/vm-$VMID-disk-$iteration.vmdk" -Wait -RedirectStandardOutput /dev/null
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

    if (Test-Path $archiveOutputDirectory -ErrorAction SilentlyContinue) {
        Write-Host "Removing any files created by the script." -ForegroundColor Green
        Remove-Item $archiveOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue | Out-Null   
    }

}
 
