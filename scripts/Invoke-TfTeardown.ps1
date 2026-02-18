<#
.SYNOPSIS
    Tears down the Terraform VMs created by the Invoke-TfClones script
    
.Example
    .\Invoke-TfTeardown.ps1 -TerraformPath terraform
#>

[CmdletBinding()]
param(
  # Path to executable Terraform
  [Parameter(Mandatory)]
  [string]$TerraformPath,

  # Path to Terraform directory
  [Parameter()]
  [string]$Path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'tf'))
)

& $TerraformPath -chdir="$Path" destroy