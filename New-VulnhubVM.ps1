[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({$_.Host -eq 'download.vulnhub.com'})]
    [System.Uri]
    $VulnhubURI,

    [Parameter(Mandatory = $true)]
    [ValidateScript({[System.IO.Directory]::Exists($_)})]
    [String]
    $DownloadDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateScript({$_ -ge 0})]
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
    [ValidateNotNullOrEmpty()]
    [String]
    $VMDiskStorageVolume,

    [Parameter(HelpMessage = 'Example: vmbr0')]
    [ValidateNotNullOrEmpty()]
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
process {
    
    $fileName = $VulnhubURI.Segments[-1] # Define the download file name based on the URI provided.
    $downloadPath = "$DownloadDirectory/$fileName"
    Write-Host "Downloading VM from Vulnhub. Please be patient..." -ForegroundColor Green
    wget $VulnhubURI.ToString() -q --show-progress -O $downloadPath
    $downloadedVM = Get-ChildItem $downloadPath

    Write-Host "Expanding $($downloadedVM.FullName) contents to grab the VM disk." -ForegroundColor Green
    if ($downloadedVM.Extension -eq '.ova') {
        $directoryName = $downloadedVM.Name -replace '\.ova', ''
        $outputDirectory = "$DownloadDirectory/$directoryName"
        mkdir -p $outputDirectory
        tar -xvf $downloadedVM.FullName -C $outputDirectory
    }
    elseif ($downloadedVM.Name -like '*.ova.gz') {
        $directoryName = $downloadedVM.Name -replace '\.ova\.gz', ''
        $outputDirectory = "$DownloadDirectory/$directoryName"
        mkdir -p $outputDirectory
        tar -xvf $downloadedVM.FullName -C $outputDirectory
    }
    elseif ($downloadedVM.Extension -eq '.rar') {
        $outputDirectory = $DownloadDirectory + '/' + $downloadedVM.BaseName
        unar $downloadedVM.FullName -o $DownloadDirectory
    }
    else {
        Get-Item $downloadPath | Remove-Item -Recurse -Force # Clean up any artifacts after error.
        throw "Unhandled file extension. Attempting to clean up any artifacts from script."            
    }

    $vmDisk = Get-ChildItem $outputDirectory -Filter "*.vmdk"
    if (-not $vmDisk) { 
        Get-Item $downloadPath, $outputDirectory | Remove-Item -Recurse -Force # Clean up any artifacts after error.
        throw "Unable to locate .vmdk file to make VM. Attempting to clean up any artifacts from script."             
    }
    else {
        Write-Host "Creating a VM using <qm create> with the following parameters:" -ForegroundColor Green
        Write-Host "ID: $VMID"
        Write-Host "Name: $VMName"
        qm create $VMID --net0 virtio,bridge=$NetworkBridge --name $VMName --ostype $GuestOSType `
           --memory $MemoryMiB --bootdisk scsi0 --scsihw lsi > /dev/null
        
        Write-Host "Importing the disk $($vmDisk.FullName) into storage volume: $VMDiskStorageVolume." -ForegroundColor Green
        qm importdisk $VMID $vmDisk.FullName $VMDiskStorageVolume --format vmdk > /dev/null
        
        Write-Host "Attaching the disk $($VMDiskStorageVolume):vm-$VMID-disk-0 to scsi0." -ForegroundColor Green
        qm set $VMID --scsi0 "$($VMDiskStorageVolume):vm-$VMID-disk-0" > /dev/null
        
        Write-Host "Setting boot order to: scsi0, net0." -ForegroundColor Green            
        qm set 555 --boot="order=scsi0;net0" > /dev/null
        
        Write-Host "All commands completed successfully. Attempting to start VM." -ForegroundColor Green
        qm start $VMID > /dev/null
        
        Write-Host "Cleaning up any files in $outputDirectory." -ForegroundColor Yellow
        Remove-Item $downloadPath -Force
        Remove-Item $outputDirectory -Recurse -Force
    }

}
