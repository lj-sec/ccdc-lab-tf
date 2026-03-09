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
  # Proxmox API token (root@pam!terraform=xxxxxxxx)
  [Parameter(Mandatory)]
  [string]$ProxmoxApiToken,

  # Starting VMID - Will increment 10 from here
  # !!!! Please be sure not to collide with existing vms !!!!
  [Parameter(Mandatory)]
  [ValidateRange(1, 9999)]
  [int]$VmIdStart,

  # Team number (appends to each VM name + tag)
  [Parameter(Mandatory)]
  [ValidateRange(1, 999)]
  [int]$TeamNumber,

  # Path to executable Terraform
  [Parameter(Mandatory)]
  [string]$TerraformPath = "terraform",

  # Path to executable Ansible
  [Parameter(Mandatory)]
  [string]$AnsiblePath = "ansible-playbook",

  # Proxmox endpoint (https://pve.example.com/)
  [Parameter(Mandatory)]
  [string]$ProxmoxEndpoint = "https://ccdcpve.eku.edu",

  # Proxmox invalid https cert (y/n)?
  [Parameter()]
  [bool]$ProxmoxInsecure = $true,

  # Terraform's directory within the repository
  [Parameter()]
  [string]$TerraformDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'tf'))

  # Ansible's directory within the repository
  [Parameter()]
  [string]$TerraformDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'ansible'))
)

# Globals
$ErrorActionPreference = "Stop"

# Fixed fields
$NodeName    = "ccdcpve"
$DatastoreId = "local-lvm"
$Started     = "true"
$Tag         = "blue_team_$TeamNumber"
$VlanId      = 20+$TeamNumber-1

function Test-Executable {
  param([Parameter(Mandatory)][string]$CommandOrPath)

  $onWindows = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
    $IsWindows
  } else {
    $env:OS -eq 'Windows_NT'
  }

  if ($onWindows -and (Test-Path -LiteralPath $CommandOrPath)) {
    if ([IO.Path]::GetExtension($CommandOrPath) -ne '.exe') {
      throw "Expected a .exe at: $CommandOrPath"
    }
    return
  }

  $cmd = Get-Command -Name $CommandOrPath -ErrorAction SilentlyContinue
  if (-not $cmd -and -not (Test-Path -LiteralPath $CommandOrPath)) {
    throw "Command not found in PATH and file not found at: $CommandOrPath"
  }
}

function Escape-HclString {
  param([Parameter(Mandatory)][string]$Value)
  return ($Value -replace '\\', '\\\\' -replace '"', '\"')
}

function Escape-YamlDoubleQuoted {
  param([Parameter(Mandatory)][string]$Value)
  return ($Value -replace '\\', '\\\\' -replace '"', '\"')
}

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

Test-Executable -CommandOrPath $TerraformPath
if ($RunAnsible) {
  Test-Executable -CommandOrPath $AnsibleExe
}

if (-not (Test-Path -LiteralPath $TerraformDir)) {
  throw "TerraformDir not found: $TerraformDir"
}
if (-not (Test-Path -LiteralPath $AnsibleDir)) {
  throw "AnsibleDir not found: $AnsibleDir"
}

$inventoryDir = Join-Path $AnsibleDir "inventory"
$groupVarsDir = Join-Path $inventoryDir "group_vars"
$playbookPath = Join-Path $AnsibleDir "playbooks"

New-Item -ItemType Directory -Force -Path $inventoryDir | Out-Null
New-Item -ItemType Directory -Force -Path $groupVarsDir | Out-Null

$tfvarsPath   = Join-Path $TerraformDir "clones.auto.tfvars"
$planPath     = Join-Path $TerraformDir "tfplan"
$hostsPath    = Join-Path $inventoryDir "hosts.yaml"
$groupVarsPath = Join-Path $groupVarsDir "windows.yaml"

$tfvarsContent

$hostsContent

$groupVarsContent

$tfvarsContent   | Out-File -FilePath $tfvarsPath -Encoding utf8 -Force -NoNewline
$hostsContent    | Out-File -FilePath $hostsPath -Encoding utf8 -Force -NoNewline
$groupVarsContent| Out-File -FilePath $groupVarsPath -Encoding utf8 -Force -NoNewline

Write-Host "Wrote $tfvarsPath"
Write-Host "Wrote $hostsPath"
Write-Host "Wrote $groupVarsPath"

& $TerraformPath -chdir="$TerraformDir" init
if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

& $TerraformPath -chdir="$TerraformDir" plan -var-file="$tfvarsPath" -out="$planPath"
if ($LASTEXITCODE -ne 0) { throw "terraform plan failed" }

$confirmation = Read-Host "Apply changes? (y/N)"
if ($confirmation -ine "y") {
  Write-Host "Cancelled before apply."
  exit 0
}

& $TerraformPath -chdir="$TerraformDir" apply "$planPath"
if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }

if ($RunAnsible) {
  if (-not (Test-Path -LiteralPath $playbookPath)) {
    throw "Playbook not found: $playbookPath"
  }

  & $AnsibleExe -i $hostsPath $playbookPath
  if ($LASTEXITCODE -ne 0) { throw "ansible-playbook failed" }
}