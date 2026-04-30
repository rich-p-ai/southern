# Inspect a Vault deployment in a given OpenShift cluster.
# Logs in (assumes $env:OC_USER and $env:OC_PASSWORD already set), then
# reports pod, helm, service, route, vault status, raft peers, leader.

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$ApiUrl,
  [Parameter(Mandatory=$true)] [string]$Namespace,
  [string]$Pod = 'vault-0',
  [string]$Release = 'vault'
)

$ErrorActionPreference = 'Continue'

function Section([string]$title) {
  Write-Host ''
  Write-Host ('=' * 72) -ForegroundColor DarkGray
  Write-Host $title -ForegroundColor Cyan
  Write-Host ('=' * 72) -ForegroundColor DarkGray
}

Section "LOGIN  ->  $ApiUrl  ($Namespace)"
oc login $ApiUrl -u $env:OC_USER -p $env:OC_PASSWORD --insecure-skip-tls-verify=true 2>&1 | Select-Object -Last 2
oc project $Namespace 2>&1 | Select-Object -Last 1

Section "HELM  release"
helm list -n $Namespace 2>&1
Write-Host ''
helm status $Release -n $Namespace 2>&1 | Select-String -Pattern 'NAME:|LAST DEPLOYED:|NAMESPACE:|STATUS:|REVISION:|CHART:'

Section "PODS in $Namespace"
oc get pod -n $Namespace -o wide 2>&1

Section "STATEFULSET / DEPLOYMENT"
oc get statefulset,deployment -n $Namespace 2>&1
Write-Host ''
oc get statefulset $Release -n $Namespace -o jsonpath='{"replicas: "}{.status.replicas}{" / readyReplicas: "}{.status.readyReplicas}{" / currentRevision: "}{.status.currentRevision}{"`n"}' 2>$null

Section "SERVICES + ROUTE"
oc get svc -n $Namespace 2>&1
Write-Host ''
oc get route -n $Namespace 2>&1

Section "VAULT STATUS  (inside $Pod)"
oc exec -n $Namespace $Pod -- /bin/sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' 2>&1

Section "VAULT  raft list-peers  (requires VAULT_TOKEN env var)"
$rootToken = $env:VAULT_ROOT_TOKEN
if (-not $rootToken) {
  Write-Host '  Skipped: set $env:VAULT_ROOT_TOKEN to inspect raft membership.' -ForegroundColor DarkYellow
  Write-Host '  e.g. $env:VAULT_ROOT_TOKEN = (Get-Content .\NEW-KEYS-DO-NOT-COMMIT.json | ConvertFrom-Json).root_token' -ForegroundColor DarkYellow
} else {
  oc exec -n $Namespace $Pod -- /bin/sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$rootToken vault operator raft list-peers" 2>&1
}

Section "POD events (last 10)"
oc get events -n $Namespace --sort-by=.lastTimestamp 2>&1 | Select-Object -Last 11

Section "STORAGE  (PVCs)"
oc get pvc -n $Namespace 2>&1

Write-Host ''
Write-Host "Done: $Namespace" -ForegroundColor Green
