[CmdletBinding()]
param(
  [string]$EnvFile = '.env'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $EnvFile)) {
  throw "Missing $EnvFile. Copy .env.example to .env and set POSTGRES_PASSWORD."
}

$line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^POSTGRES_PASSWORD=' } | Select-Object -First 1
if (-not $line) { throw 'POSTGRES_PASSWORD is required in .env.' }
$password = $line.Substring('POSTGRES_PASSWORD='.Length)
if ([string]::IsNullOrWhiteSpace($password) -or $password -eq 'replace-with-a-long-local-password') {
  throw 'Set a non-placeholder POSTGRES_PASSWORD in .env.'
}

kubectl create secret generic postgres-creds -n data --from-literal=username=kumademo --from-literal=password=$password --type=kubernetes.io/basic-auth --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic postgres-app-creds -n webapp --from-literal=password=$password --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap minishop-postgres-schema -n webapp --from-file=database.sql=vendor/kuma-demo/database.sql --dry-run=client -o yaml | kubectl apply -f -
Write-Host 'Runtime-only Secrets and public schema ConfigMap applied.'

