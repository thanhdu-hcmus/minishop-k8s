[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$required = @('docker', 'kind', 'kubectl', 'helm')
$missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing) {
  throw "Missing required command(s): $($missing -join ', '). Install them, then run this preflight again."
}

function Invoke-PrerequisiteCheck {
  param([string]$Name, [scriptblock]$Command)

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Name check failed. Resolve the reported command error, then run this preflight again."
  }
}

Invoke-PrerequisiteCheck 'Docker daemon' { docker info --format '{{.ServerVersion}}' | Out-Null }
Invoke-PrerequisiteCheck 'kind' { kind version | Out-Null }
Invoke-PrerequisiteCheck 'kubectl client' { kubectl version --client=true | Out-Null }
Invoke-PrerequisiteCheck 'Helm' { helm version --short | Out-Null }
Write-Host 'Preflight passed. This script does not install tools, create a cluster, or change host networking.'
