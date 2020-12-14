[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if ($_.host -notlike '*.images.linuxcontainers.org' -or $_.Segments[-1] -ne 'rootfs.tar.xz') {
            throw "Please provide a link to a valid rootfs.tar.xz file from images.linuxcontainers.org"
        }
        else {
            return $true
        }
    })]
    [System.Uri]
    $ImageURI,

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
    $ContainerID,

    [Parameter()]
    [Switch]
    $SetRootPassword,

    [Parameter()]
    [ValidateSet('console', 'shell', 'tty')]
    [String]
    $DefaultConsole = 'tty',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [String]
    $SSHPublicKey,

    [Parameter(HelpMessage = 'This is used to setup configuration inside the container, and corresponds to lxc setup scripts in /usr/share/lxc/config/<ostype>.common.conf. Value unmanaged can be used to skip and OS specific setup.' )]
    [ValidateSet('alpine', 'archlinux', 'centos', 'debian', 'fedora', 'gentoo', 'opensuse', 'ubuntu', 'unmanaged')]
    [String]
    $ContainerOSType,

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
    $ContainerDiskStorageVolume,

    [Parameter(
        Mandatory = $true,
        HelpMessage = 'Example: vmbr0'
    )]
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

    [Parameter(
        Mandatory = $true,
        HelpMessage = 'Useful for name resolution.'
    )]
    [ValidateNotNullOrEmpty()]
    [String]
    $Hostname,

    [Parameter(HelpMessage = 'Example: 2048')]
    [ValidateScript({$MemoryMiB -ge 16})]
    [Int]
    $MemoryMiB,

    [Parameter()]
    [Bool]
    $StartOnCreate = $false
)
begin {

    $templateStorage = '/var/lib/vz/template/cache'
    $fileName = $ImageURI.Segments[-1] -replace 'rootfs', $Hostname
    $downloadPath = $templateStorage + '/' + $fileName
    $parameterCollection = @()
    $parameterCollection += "--storage $ContainerDiskStorageVolume"
    $parameterCollection += "--net0 name=eth0,bridge=$NetworkBridge"
    $parameterCollection += "--hostname $Hostname"
    if ($SetRootPassword.IsPresent) { $parameterCollection += '--password' }
    if ($PSBoundParameters['DefaultConsole']) { $parameterCollection += "--cmode $DefaultConsole" }
    if ($PSBoundParameters['SSHPublicKey']) { 
        $sshPublicKeysFile = "/tmp/$fileName-pubkeys"
        touch $sshPublicKeysFile
        $SSHPublicKey > $sshPublicKeysFile
        $parameterCollection += "--ssh-public-keys $sshPublicKeysFile" 
    }
    if ($PSBoundParameters['ContainerOSType']) { $parameterCollection += "--ostype $ContainerOSType" }
    if ($PSBoundParameters['MemoryMiB']) { $parameterCollection += "--memory $MemoryMiB" }
    if ($PSBoundParameters['StartOnCreate']) { $parameterCollection += "--start 1" }
    $parameterString = $parameterCollection -join ' '    

}
process {

    Write-Host "Downloading container template from $ImageURI. Please be patient..." -ForegroundColor Green
    wget $ImageURI.ToString() -q --show-progress -O $downloadPath
    Start-Sleep -Seconds 2
    
    Write-Host "Attempting to create the container with the following command: pct create $ContainerID $downloadPath $parameterString" -ForegroundColor Green
    try {
        Start-Process pct -ArgumentList "create $ContainerID $downloadPath $parameterString" -Wait
        Write-Host "Command executed successfully." -ForegroundColor Green
    }
    catch {
        throw "pct create failed:`n$_"
    }

}
end {
    
    if (Test-Path $downloadPath -ErrorAction SilentlyContinue) { Remove-Item $downloadPath -Force | Out-Null }
    if (Test-Path $sshPublicKeysFile -ErrorAction SilentlyContinue) { Remove-Item $sshPublicKeysFile -Force | Out-Null }

}
