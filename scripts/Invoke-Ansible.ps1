<#
.SYNOPSIS
  Generates an Ansible inventory from VM specs and runs associated playbooks.

.DESCRIPTION
  This script mirrors the automation style of Invoke-TfClones.ps1:
  - Reads VM definitions from a JSON spec file.
  - Builds an inventory at infra/ansible/inventories/<name>/hosts.yaml.
  - Runs playbook .yaml files associated with the spec.

  Playbooks can be defined:
  - At top-level in JSON as "playbooks" or "ansible_playbooks".
  - Per VM as "playbooks" or "ansible_playbooks" (all unique entries are run).
  - Via -DefaultPlaybooks when not present in JSON.

.EXAMPLE
  .\Invoke-Ansible.ps1 -VmSpecPath .\conf\vm-specs.json -InventoryName lab02
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$VmSpecPath,

  [Parameter()]
  [string]$AnsibleDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'ansible')),

  [Parameter()]
  [string]$InventoryName = "generated",

  [Parameter()]
  [string]$AnsiblePlaybookPath = "ansible-playbook",

  [Parameter()]
  [string]$AnsibleGalaxyPath = "ansible-galaxy",

  [Parameter()]
  [string[]]$DefaultPlaybooks = @(),

  [Parameter()]
  [string]$Limit,

  [Parameter()]
  [string[]]$ExtraArgs = @(),

  [Parameter()]
  [switch]$InstallRequirements,

  [Parameter()]
  [switch]$Check,

  [Parameter()]
  [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"

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

function Get-RequiredProperty {
  param(
    [Parameter(Mandatory)]$Object,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ItemKey,
    [Parameter(Mandatory)][string]$Context
  )

  $prop = $Object.PSObject.Properties[$Name]
  if (-not $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    throw "$Context '$ItemKey' is missing required property '$Name' in $VmSpecPath"
  }

  return [string]$prop.Value
}

function Get-OptionalStringArrayProperty {
  param(
    [Parameter(Mandatory)]$Object,
    [Parameter(Mandatory)][string[]]$Names
  )

  foreach ($name in $Names) {
    $prop = $Object.PSObject.Properties[$name]
    if ($prop -and $null -ne $prop.Value) {
      if ($prop.Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
          return @([string]$prop.Value)
        }
      }

      $items = @($prop.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($items.Count -gt 0) {
        return $items
      }
    }
  }

  return @()
}

function ConvertTo-YamlScalar {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

  if ($Value -match "^[a-zA-Z0-9_./:@-]+$") {
    return $Value
  }

  return "'{0}'" -f ($Value -replace "'", "''")
}

function Resolve-PathCandidate {
  param(
    [Parameter(Mandatory)][string]$PathValue,
    [Parameter(Mandatory)][string[]]$BaseDirs
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    if (Test-Path -LiteralPath $PathValue) {
      return (Resolve-Path -LiteralPath $PathValue).Path
    }
    throw "Path does not exist: $PathValue"
  }

  foreach ($baseDir in $BaseDirs) {
    $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($baseDir, $PathValue))
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "Could not resolve path '$PathValue' from base dirs: $($BaseDirs -join ', ')"
}

Test-Executable -CommandOrPath $AnsiblePlaybookPath
if ($InstallRequirements) {
  Test-Executable -CommandOrPath $AnsibleGalaxyPath
}

if (-not (Test-Path -LiteralPath $VmSpecPath)) {
  throw "VmSpecPath not found: $VmSpecPath"
}
if (-not (Test-Path -LiteralPath $AnsibleDir)) {
  throw "AnsibleDir not found: $AnsibleDir"
}

$vmSpecFullPath = (Resolve-Path -LiteralPath $VmSpecPath).Path
$vmSpecDir = Split-Path -Parent $vmSpecFullPath
$specRaw = Get-Content -LiteralPath $vmSpecFullPath -Raw
$specData = $specRaw | ConvertFrom-Json

if ($null -eq $specData) {
  throw "No VM specs found in $VmSpecPath"
}

$vmSpecs = @()
$topLevelPlaybooks = @()

if ($specData -is [System.Collections.IEnumerable] -and $specData -isnot [string]) {
  $vmSpecs = @($specData)
} elseif ($specData.PSObject.Properties['vms']) {
  $vmSpecs = @($specData.vms)
  $topLevelPlaybooks = Get-OptionalStringArrayProperty -Object $specData -Names @('playbooks', 'ansible_playbooks')
} else {
  $vmSpecs = @($specData)
}

if ($vmSpecs.Count -eq 0) {
  throw "VM spec list is empty in $VmSpecPath"
}

$inventoryDir = Join-Path $AnsibleDir (Join-Path 'inventories' $InventoryName)
New-Item -ItemType Directory -Path $inventoryDir -Force | Out-Null
$inventoryPath = Join-Path $inventoryDir 'hosts.yaml'

$hosts = New-Object System.Collections.Generic.List[object]
$groupToHosts = @{}
$playbooks = New-Object System.Collections.Generic.List[string]

foreach ($pb in $topLevelPlaybooks) {
  if (-not $playbooks.Contains($pb)) {
    $playbooks.Add($pb)
  }
}

foreach ($vm in $vmSpecs) {
  $key = Get-RequiredProperty -Object $vm -Name 'key' -ItemKey 'unknown' -Context 'VM'

  $ansibleHost = $null
  if ($vm.PSObject.Properties['public_ip'] -and -not [string]::IsNullOrWhiteSpace([string]$vm.public_ip)) {
    $ansibleHost = [string]$vm.public_ip
  } elseif ($vm.PSObject.Properties['ipv4_address'] -and -not [string]::IsNullOrWhiteSpace([string]$vm.ipv4_address)) {
    $ansibleHost = [string]$vm.ipv4_address
  } else {
    throw "VM '$key' must define either 'public_ip' or 'ipv4_address'"
  }

  $ansibleUser = if ($vm.PSObject.Properties['admin_username'] -and -not [string]::IsNullOrWhiteSpace([string]$vm.admin_username)) {
    [string]$vm.admin_username
  } else {
    'Administrator'
  }

  $ansiblePassword = if ($vm.PSObject.Properties['default_password'] -and -not [string]::IsNullOrWhiteSpace([string]$vm.default_password)) {
    [string]$vm.default_password
  } else {
    '!Password123'
  }

  $hostGroups = Get-OptionalStringArrayProperty -Object $vm -Names @('ansible_groups', 'groups', 'tags')
  if ($hostGroups.Count -eq 0) {
    $hostGroups = @('windows')
  }

  foreach ($group in $hostGroups) {
    if (-not $groupToHosts.ContainsKey($group)) {
      $groupToHosts[$group] = New-Object System.Collections.Generic.List[string]
    }
    if (-not $groupToHosts[$group].Contains($key)) {
      $groupToHosts[$group].Add($key)
    }
  }

  $hostPlaybooks = Get-OptionalStringArrayProperty -Object $vm -Names @('playbooks', 'ansible_playbooks')
  foreach ($pb in $hostPlaybooks) {
    if (-not $playbooks.Contains($pb)) {
      $playbooks.Add($pb)
    }
  }

  $hosts.Add([PSCustomObject]@{
      Key             = $key
      AnsibleHost     = $ansibleHost
      AnsibleUser     = $ansibleUser
      AnsiblePassword = $ansiblePassword
    })
}

foreach ($pb in $DefaultPlaybooks) {
  if (-not $playbooks.Contains($pb)) {
    $playbooks.Add($pb)
  }
}

if ($playbooks.Count -eq 0) {
  throw "No playbooks were defined. Add playbooks/ansible_playbooks in JSON or pass -DefaultPlaybooks."
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('all:')
$lines.Add('  hosts:')
foreach ($host in $hosts) {
  $lines.Add("    $($host.Key):")
  $lines.Add("      ansible_host: $(ConvertTo-YamlScalar -Value $host.AnsibleHost)")
  $lines.Add("      ansible_user: $(ConvertTo-YamlScalar -Value $host.AnsibleUser)")
  $lines.Add("      ansible_password: $(ConvertTo-YamlScalar -Value $host.AnsiblePassword)")
}
$lines.Add('  children:')
foreach ($groupName in ($groupToHosts.Keys | Sort-Object)) {
  $lines.Add("    $groupName:")
  $lines.Add('      hosts:')
  foreach ($hostKey in ($groupToHosts[$groupName] | Sort-Object)) {
    $lines.Add("        $hostKey: {}")
  }
}

($lines -join [Environment]::NewLine) | Out-File -FilePath $inventoryPath -Encoding utf8 -Force -NoNewline
Write-Host "Wrote $inventoryPath"

$requirementsPath = Join-Path $AnsibleDir 'requirements.yaml'
if ($InstallRequirements -and (Test-Path -LiteralPath $requirementsPath)) {
  & $AnsibleGalaxyPath collection install -r $requirementsPath
  if ($LASTEXITCODE -ne 0) { throw "ansible-galaxy install failed" }
}

$baseDirs = @($AnsibleDir, $vmSpecDir, (Get-Location).Path)
$resolvedPlaybooks = @()
foreach ($pb in $playbooks) {
  $resolvedPlaybooks += (Resolve-PathCandidate -PathValue $pb -BaseDirs $baseDirs)
}

Write-Host "Inventory: $inventoryPath"
Write-Host "Playbooks:"
$resolvedPlaybooks | ForEach-Object { Write-Host "  - $_" }

if (-not $AutoApprove) {
  $confirmation = Read-Host "Run Ansible playbooks now? (y/N)"
  if ($confirmation -ine 'y') {
    Write-Host 'Cancelled before ansible-playbook execution.'
    exit 0
  }
}

Push-Location $AnsibleDir
try {
  foreach ($playbook in $resolvedPlaybooks) {
    $args = @('-i', $inventoryPath, $playbook)
    if (-not [string]::IsNullOrWhiteSpace($Limit)) {
      $args += @('--limit', $Limit)
    }
    if ($Check) {
      $args += '--check'
    }
    if ($ExtraArgs.Count -gt 0) {
      $args += $ExtraArgs
    }

    & $AnsiblePlaybookPath @args
    if ($LASTEXITCODE -ne 0) {
      throw "ansible-playbook failed for $playbook"
    }
  }
}
finally {
  Pop-Location
}

exit 0