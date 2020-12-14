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
                $type = (file $file.FullName) -split ' '
                $isArchive = $type[-1] -eq 'archive'
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
    
    if (-not [System.IO.Path]::EndsInDirectorySeparator($DownloadDirectory)) { $DownloadDirectory = $DownloadDirectory + '/'  }
    $fileName = $VulnhubURI.Segments[-1] # Define the download file name based on the URI provided.
    if ($fileName -like '*.iso') { throw "Creating VMs from ISO files not yet implemented." }
    $downloadPath = $DownloadDirectory + $fileName
    $archiveOutputDirectory = $DownloadDirectory + "temp$(Get-Random)"
    $parameterCollection = @()
    $parameterCollection += "--ostype $GuestOSType"
    $parameterCollection += "--storage $VMDiskStorageVolume"
    if ($PSBoundParameters['NetworkBridge']) { $paramterCollection += "--net0 bridge=$NetworkBridge" }
    if ($PSBoundParameters['VMName']) { $paramterCollection += "--name $VMName" }
    if ($PSBoundParameters['MemoryMiB']) { $paramterCollection += "--memory $MemoryMiB" }        
    $parameterString = $parameterCollection -join ' '    
    
}
process {

    Write-Host "Downloading VM from Vulnhub. Please be patient..." -ForegroundColor Green
    wget $VulnhubURI.ToString() -q --show-progress -O $downloadPath
    $downloadedVM = Get-ChildItem $downloadPath
    try {
        unar $downloadedVM.FullName -o $archiveOutputDirectory
    }
    catch {
        throw "Error expanding archive:`n$_"
    }
    
    try {
        $vmDisk = Find-VMDK -Directory $archiveOutputDirectory
    }
    catch {
        Get-Item $downloadPath, $archiveOutputDirectory | Remove-Item -Recurse -Force # Clean up any artifacts after error.
        throw $_
    }

    try {
        $parameterString = $parameterCollection -join ' '

        Write-Host "Attempting to create the VM with the following command: qm create $VMID $parameterString." -ForegroundColor Green
        Start-Process qm -ArgumentList "create $VMID $parameterString" -Wait -RedirectStandardOutput /dev/null

        Write-Host "Attempting to import the VMDK file as a disk." -ForegroundColor Green
        Start-Process qm -ArgumentList "importdisk $VMID $($vmdisk.FullName) $VMDiskStorageVolume --format vmdk" -Wait -RedirectStandardOutput /dev/null

        Write-Host "Attempting to set the imported disk as the VM primary SCSI boot disk." -ForegroundColor Green
        Start-Process qm -ArgumentList "set $VMID --scsi0 $($VMDiskStorageVolume):vm-$VMID-disk-0" -Wait -RedirectStandardOutput /dev/null

        if ($PSBoundParameters['NetworkBridge']) {
            Write-Host "Attempting to set boot order to scsi0,net0." -ForegroundColor Green
            Start-Process qm -ArgumentList "set $VMID --boot=`"order=scsi0;net0`"" -Wait -RedirectStandardOutput /dev/null
        }
        else {
            Write-Host "Setting scsi0 as the boot device." -ForegroundColor Green
            Start-Process qm -ArgumentList "set $VMID --boot=`"order=scsi0`"" -Wait -RedirectStandardOutput /dev/null
        }

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
