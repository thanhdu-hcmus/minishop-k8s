[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not (Get-ChildItem manifests -Recurse -Filter *.yaml)) { throw 'No manifests found.' }

$parseErrors = @()
Get-ChildItem scripts -Filter *.ps1 | ForEach-Object {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
  $parseErrors += $errors
}
if ($parseErrors) {
  $parseErrors | ForEach-Object { Write-Error $_ }
  throw 'PowerShell parser validation failed.'
}
Write-Host 'PowerShell parser checks passed.'

function Invoke-Checked {
  param([string]$Label, [scriptblock]$Command)
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE." }
}

# Kustomize parses the complete raw-manifest copy without reading kubeconfig.
Invoke-Checked 'Kustomize base render' { kubectl kustomize kustomize/base | Out-Null }
Invoke-Checked 'Helm lint' { helm lint charts/minishop }
Invoke-Checked 'Helm render' { helm template minishop charts/minishop | Out-Null }
Invoke-Checked 'Kustomize dev render' { kubectl kustomize kustomize/overlays/dev | Out-Null }
Invoke-Checked 'Kustomize prod render' { kubectl kustomize kustomize/overlays/prod | Out-Null }

if (Get-Command yamllint -ErrorAction SilentlyContinue) {
  Invoke-Checked 'yamllint' { yamllint manifests kustomize charts }
} else {
  Write-Host 'SKIP yamllint: command is not installed.'
}

if (Get-Command kubeconform -ErrorAction SilentlyContinue) {
  Invoke-Checked 'kubeconform' { kubectl kustomize kustomize/base | kubeconform -summary -ignore-missing-schemas }
} else {
  Write-Host 'SKIP kubeconform: command is not installed.'
}

$clientValidationFiles = @(
  'manifests/00-namespaces/namespaces.yaml',
  'manifests/01-storage/test-pvc.yaml',
  'manifests/02-config-secrets/runtime-config.yaml',
  'manifests/03-workloads/app.yaml',
  'manifests/05-networking/ingress.yaml',
  'manifests/06-security/rbac.yaml',
  'manifests/07-scaling/backend-hpa.yaml',
  'manifests/08-cronjobs/report-cronjob.yaml'
)

$priorErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$null = & kubectl cluster-info --request-timeout=2s 2>$null
$clusterInfoExitCode = $LASTEXITCODE
$ErrorActionPreference = $priorErrorAction
if ($clusterInfoExitCode -eq 0) {
  foreach ($file in $clientValidationFiles) {
    Invoke-Checked "kubectl client dry-run $file" { kubectl apply --dry-run=client -f $file | Out-Null }
  }
  Write-Host 'kubectl client dry-run checks passed for built-in resource YAML.'
} else {
  Write-Host 'SKIP kubectl client dry-run: a reachable cluster/API discovery is required; CNPG and monitoring CRDs are intentionally runtime-only checks.'
}

Write-Host 'Static rendering passed. CRD admission and runtime behavior still require a cluster.'
exit 0
