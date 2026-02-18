<#
.SYNOPSIS
  Generates a Terraform .tfvars file for Proxmox full-clone definitions
  Then runs Terraform to clone said VMs

.EXAMPLE
  .\Invoke-TfClones.ps1 -VmIdStart 200 -TeamNumber 2 `
    -TerraformPath "D:\terraform_1.14.5_windows_amd64\terraform.exe" `
    -ProxmoxEndpoint "https://pve.example.com:8006/" `
    -ProxmoxApiToken "root@pam!terraform=xxxxxxxx"
#>

[CmdletBinding()]
param(
  # Path to executable Terraform
  [Parameter(Mandatory)]
  [string]$TerraformPath,

  # Starting VMID - Will increment 10 from here
  # !!!! Please be sure not to collide with existing vms !!!!
  [Parameter(Mandatory)]
  [ValidateRange(1, 9999)]
  [int]$VmIdStart,

  # Team number (appends to each VM name + tag)
  [Parameter(Mandatory)]
  [ValidateRange(1, 999)]
  [int]$TeamNumber,

  # Proxmox endpoint (https://pve.example.com/)
  [Parameter(Mandatory)]
  [string]$ProxmoxEndpoint,

  # Proxmox API token (root@pam!terraform=xxxxxxxx)
  [Parameter(Mandatory)]
  [string]$ProxmoxApiToken,

  # Proxmox invalid https cert (y/n)?
  [Parameter()]
  [bool]$ProxmoxInsecure = $true,

  # Output path for the .tfvars file (probably leave default if unsure)
  [Parameter()]
  [string]$Path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'tf'))
)

$ErrorActionPreference = "Stop"

# Check Terraform
# Cross-version Windows detection (PS7+: $IsWindows, PS5.1: $env:OS)
$OnWindows = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) { $IsWindows } else { $env:OS -eq 'Windows_NT' }

if ($OnWindows) {
  # On Windows, require a real .exe path that exists
  if (-not (Test-Path -LiteralPath $TerraformPath) -or ([IO.Path]::GetExtension($TerraformPath) -ne '.exe')) {
    throw "Terraform executable (.exe) not found at $TerraformPath"
  }
} else {
  # On Linux/macOS, allow either:
  #  1) an explicit path to an executable file, OR
  #  2) a command name discoverable in PATH (e.g. 'terraform')
  $cmd = Get-Command -Name $TerraformPath -ErrorAction SilentlyContinue
  if (-not $cmd) {
    # If they passed a path, validate it exists and is executable-ish
    if (-not (Test-Path -LiteralPath $TerraformPath)) {
      throw "Terraform command not found in PATH and file not found at $TerraformPath"
    }
  }
}

if (!(Test-Path -LiteralPath $Path)) {
  throw "Path not found: $Path"
}

# Fixed fields
$NodeName    = "ccdcpve"
$DatastoreId = "local-lvm"
$Started     = "true"
$Tag         = "blue_team_$TeamNumber"

# Clone definitions (order matters for vm_id incrementing)
# !!!! Please ensure the source VM ID's are properly configured !!!!
$defs = @(
  @{ Key="windows-webserver";  NameFmt="Windows-Webserver-{0}";   SourceVmId=104; Nets=@("BTWinInt") },
  @{ Key="oracle-splunk";      NameFmt="Oracle-Splunk-{0}";       SourceVmId=109; Nets=@("BTLinInt") },
  @{ Key="linux-panos";        NameFmt="Linux-PanOS-{0}";         SourceVmId=125; Nets=@("BTLinInt","BTLinInt","BTLinEx") },
  @{ Key="win11";              NameFmt="Windows-Wkst11-{0}";      SourceVmId=155; Nets=@("BTWinInt") },
  @{ Key="vyos";               NameFmt="Router-Vyos-{0}";         SourceVmId=160; Nets=@("vmbr1","BTLinEx","BTWinEx") },
  @{ Key="ecom";               NameFmt="Linux-Ecom-{0}";          SourceVmId=165; Nets=@("BTLinInt") },
  @{ Key="webmail";            NameFmt="Linux-Webmail-{0}";       SourceVmId=166; Nets=@("BTLinInt") },
  @{ Key="windows-ad-dns";     NameFmt="Windows-AD-DNS-{0}";      SourceVmId=167; Nets=@("BTWinInt") },
  @{ Key="ubuntu-wkst";        NameFmt="Ubuntu-Wkst-{0}";         SourceVmId=168; Nets=@("BTLinInt") },
  @{ Key="windows-ftp";        NameFmt="Windows-FTP-{0}";         SourceVmId=171; Nets=@("BTWinInt") },
  @{ Key="windows-ciscoftd";   NameFmt="Windows-FTP-{0}";         SourceVmId=175; Nets=@("BTWinInt","BTWinEx","BTWinEx","BTWinInt") }
)

function New-NetworkDevicesBlock {
  param([string[]]$Bridges)

  $lines = for ($i = 0; $i -lt $Bridges.Count; $i++) {
    $comma = if ($i -lt $Bridges.Count - 1) { "," } else { "" }
    '      { bridge = "' + $Bridges[$i] + '", model = "virtio" }' + $comma
  }

  @(
    "    network_devices = ["
    ($lines -join "`r`n")
    "    ]"
  ) -join "`r`n"
}

$blocks = for ($i = 0; $i -lt $defs.Count; $i++) {
  $d = $defs[$i]
  $vmid = $VmIdStart + $i
  $name = ($d.NameFmt -f $TeamNumber)

  $netBlock = New-NetworkDevicesBlock -Bridges $d.Nets

@"
  $($d.Key) = {
    name         = "$name"
    vm_id        = $vmid
    node_name    = "$NodeName"
    started      = $Started
    source_vm_id = $($d.SourceVmId)
    datastore_id = "$DatastoreId"
    tags         = ["$Tag"]
$netBlock
  }
"@
}

# Top-level variables + clones map
$content = @"
proxmox_endpoint  = "$ProxmoxEndpoint"
proxmox_api_token = "$ProxmoxApiToken"
proxmox_insecure  = $($ProxmoxInsecure.ToString().ToLower())

clones = {

$($blocks -join "`r`n`r`n")

}
"@

# Write exactly as text into .tfvars
$outputPath = Join-Path $Path "clones.auto.tfvars"
$content | Out-File -FilePath $outputPath -Encoding utf8 -Force -NoNewline
Write-Host "Wrote $outputPath"

# Run Terraform
& $TerraformPath -chdir="$Path" init

# Run Terraform
& $TerraformPath -chdir="$Path" plan -var-file="$outputPath" -out=tfplan

$confirmation = Read-Host "Apply changes? (This takes about 10 minutes!) (y/N)"
if ($confirmation -ieq "y") {
  & $TerraformPath -chdir="$Path" apply tfplan
}