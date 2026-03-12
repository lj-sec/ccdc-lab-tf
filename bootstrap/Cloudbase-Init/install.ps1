<#
.SYNOPSIS
    Installs the configuration files in the proper place so they do not have to be manually copied over
    Must have internet connection

.EXAMPLE
    irm https://raw.githubusercontent.com/lj-sec/ccdc-lab-tf/refs/heads/main/bootstrap/Cloudbase-Init/install.ps1 | iex
#>

$baseRaw = "https://raw.githubusercontent.com/lj-sec/ccdc-lab-tf/main/bootstrap/Cloudbase-Init"
$root    = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init"

$files = @(
    @{ Url = "$baseRaw/conf/cloudbase-init.conf";          Dest = "$root\conf\cloudbase-init.conf" },
    @{ Url = "$baseRaw/conf/cloudbase-init-unattend.conf"; Dest = "$root\conf\cloudbase-init-unattend.conf" },
    @{ Url = "$baseRaw/conf/Unattend.xml";                 Dest = "$root\conf\Unattend.xml" },
    @{ Url = "$baseRaw/LocalScripts/01-winrm-network.ps1"; Dest = "$root\LocalScripts\01-winrm-network.ps1" }
)

$wc = New-Object System.Net.WebClient

foreach ($file in $files) {
    $destDir = Split-Path -Path $file.Dest -Parent
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $wc.DownloadFile($file.Url, $file.Dest)
    Write-Host "Downloaded $($file.Dest)"
}