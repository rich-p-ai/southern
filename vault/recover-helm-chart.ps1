#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Recover a Helm chart from a deployed Helm 3 release stored as a Kubernetes secret.

.DESCRIPTION
  Helm 3 stores each release as a Secret named sh.helm.release.v1.<release>.v<rev>
  in the release's namespace. The secret's `release` data field holds:
      base64( gzip( json ) )
  This script:
    1. Locates the latest release secret for a given release/namespace.
    2. Extracts the secret data via `oc extract` (which strips Kubernetes' base64).
    3. Base64-decodes, gunzips, and parses the inner JSON.
    4. Reconstructs the original chart directory (Chart.yaml, values.yaml,
       templates/, charts/, plus any extra files like README, NOTES.txt, etc.).
    5. Writes the user-supplied values to <outdir>/user-values.yaml.

.PARAMETER Namespace
  Namespace where the Helm release lives.

.PARAMETER Release
  Helm release name (default: vault).

.PARAMETER OutDir
  Destination directory. Will create <OutDir>/<chart-name>/ for the chart and
  <OutDir>/user-values.yaml for the override values.

.EXAMPLE
  .\recover-helm-chart.ps1 -Namespace 47303-vault-xadch506-pr -Release vault -OutDir .\recovered
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$Namespace,
  [string]$Release = 'vault',
  [Parameter(Mandatory = $true)] [string]$OutDir
)

$ErrorActionPreference = 'Stop'

function Convert-YamlString([object]$Value) {
  if ($Value -is [string]) { return $Value }
  return ($Value | ConvertTo-Json -Depth 100)
}

function Find-LatestReleaseSecret {
  param([string]$Namespace, [string]$Release)
  $names = oc get secret -n $Namespace -l "owner=helm,name=$Release" -o name 2>$null
  if (-not $names) {
    $names = oc get secret -n $Namespace -o name 2>$null |
      Where-Object { $_ -match "^secret/sh\.helm\.release\.v1\.$([regex]::Escape($Release))\.v\d+$" }
  }
  if (-not $names) { throw "No Helm release secrets found for $Release in $Namespace" }

  $best = $null; $bestRev = -1
  foreach ($n in $names) {
    if ($n -match '\.v(\d+)$') {
      $rev = [int]$Matches[1]
      if ($rev -gt $bestRev) { $bestRev = $rev; $best = ($n -replace '^secret/','') }
    }
  }
  return [pscustomobject]@{ Name = $best; Revision = $bestRev }
}

function Get-DecodedRelease {
  param([string]$Namespace, [string]$SecretName)

  $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("helm-recover-" + [guid]::NewGuid())) -Force
  $tmpPath = $tmp.FullName
  try {
    & oc extract -n $Namespace "secret/$SecretName" --keys=release "--to=$tmpPath" --confirm | Out-Null
    $rawFile = Join-Path $tmpPath 'release'
    if (-not (Test-Path $rawFile)) { throw "oc extract did not produce a 'release' file" }

    # `oc extract` already decoded the Kubernetes-API base64 layer.
    # The file contents now equal Helm's stored bytes: base64( gzip( json ) ).
    $b64 = Get-Content -Raw -Path $rawFile
    $b64 = ($b64 -replace '\s+','')
    $gz  = [Convert]::FromBase64String($b64)

    $msIn  = New-Object System.IO.MemoryStream(,$gz)
    $gzs   = New-Object System.IO.Compression.GZipStream($msIn, [System.IO.Compression.CompressionMode]::Decompress)
    $msOut = New-Object System.IO.MemoryStream
    $gzs.CopyTo($msOut)
    $gzs.Dispose(); $msIn.Dispose()
    $jsonBytes = $msOut.ToArray()
    $msOut.Dispose()

    $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    # PS 5.1 ConvertFrom-Json has no -Depth param (default ~1024, plenty for charts)
    return $json | ConvertFrom-Json
  }
  finally {
    Remove-Item -Recurse -Force $tmpPath -ErrorAction SilentlyContinue
  }
}

function Write-ChartFiles {
  param($Release, [string]$OutDir)

  $chart = $Release.chart
  $meta  = $chart.metadata
  $chartName = $meta.name
  if (-not $chartName) { throw "chart.metadata.name is empty" }

  $chartDir = Join-Path $OutDir $chartName
  if (Test-Path $chartDir) { Remove-Item -Recurse -Force $chartDir }
  New-Item -ItemType Directory -Path $chartDir -Force | Out-Null

  # Chart.yaml — serialize metadata as YAML-ish via JSON->YAML conversion.
  # Helm metadata maps cleanly to JSON so we write JSON and rename to .yaml;
  # but to get human-readable YAML, do a minimal hand conversion.
  $chartYaml = @()
  foreach ($prop in $meta.PSObject.Properties) {
    $name = $prop.Name; $val = $prop.Value
    if ($null -eq $val) { continue }
    if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
      $chartYaml += "${name}:"
      foreach ($item in $val) {
        if ($item -is [psobject]) {
          $first = $true
          foreach ($p in $item.PSObject.Properties) {
            $prefix = $(if ($first) { "  - " } else { "    " }); $first = $false
            $chartYaml += "$prefix$($p.Name): $(Convert-YamlString $p.Value)"
          }
        } else {
          $chartYaml += "  - $item"
        }
      }
    } elseif ($val -is [psobject]) {
      $chartYaml += "${name}:"
      foreach ($p in $val.PSObject.Properties) {
        $chartYaml += "  $($p.Name): $(Convert-YamlString $p.Value)"
      }
    } else {
      $chartYaml += "${name}: $val"
    }
  }
  Set-Content -Path (Join-Path $chartDir 'Chart.yaml') -Value ($chartYaml -join "`n") -Encoding UTF8

  # values.yaml — chart's default values (raw YAML lives in chart.values? No — chart.values is parsed object).
  # The original raw values.yaml file is in chart.raw[] when present, but in modern Helm it's in chart.files / chart.raw.
  # We'll write parsed values back as YAML and ALSO drop the raw file if found.
  $defaultValues = $chart.values
  if ($null -ne $defaultValues) {
    $defValYaml = ($defaultValues | ConvertTo-Json -Depth 100)
    Set-Content -Path (Join-Path $chartDir 'values.json') -Value $defValYaml -Encoding UTF8
  }

  # chart.raw[] holds many original files including values.yaml, .helmignore, README.md, LICENSE, etc.
  if ($chart.PSObject.Properties.Name -contains 'raw' -and $chart.raw) {
    foreach ($f in $chart.raw) {
      $rel = $f.name
      if (-not $rel) { continue }
      $dest = Join-Path $chartDir $rel
      $destDir = Split-Path -Parent $dest
      if ($destDir) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      $bytes = [Convert]::FromBase64String($f.data)
      [System.IO.File]::WriteAllBytes($dest, $bytes)
    }
  }

  # chart.files[] also holds non-template files in some chart builds
  if ($chart.PSObject.Properties.Name -contains 'files' -and $chart.files) {
    foreach ($f in $chart.files) {
      $rel = $f.name
      if (-not $rel) { continue }
      $dest = Join-Path $chartDir $rel
      $destDir = Split-Path -Parent $dest
      if ($destDir) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      if (-not (Test-Path $dest)) {
        $bytes = [Convert]::FromBase64String($f.data)
        [System.IO.File]::WriteAllBytes($dest, $bytes)
      }
    }
  }

  # chart.templates[] holds all templates — base64 encoded
  if ($chart.templates) {
    foreach ($t in $chart.templates) {
      $rel = $t.name  # already includes "templates/" prefix
      $dest = Join-Path $chartDir $rel
      $destDir = Split-Path -Parent $dest
      if ($destDir) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      $bytes = [Convert]::FromBase64String($t.data)
      [System.IO.File]::WriteAllBytes($dest, $bytes)
    }
  }

  # Sub-charts (dependencies) — recursive structure under chart.dependencies (parsed)
  if ($chart.PSObject.Properties.Name -contains 'dependencies' -and $chart.dependencies) {
    $subDir = Join-Path $chartDir 'charts'
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
    foreach ($dep in $chart.dependencies) {
      $depMeta = $dep.metadata
      $depName = $depMeta.name
      if (-not $depName) { continue }
      $fakeRelease = [pscustomobject]@{ chart = $dep }
      Write-ChartFiles -Release $fakeRelease -OutDir $subDir | Out-Null
    }
  }

  # User-supplied values (the override file given at install time)
  $userVals = $Release.config
  if ($null -ne $userVals) {
    $userYaml = ($userVals | ConvertTo-Json -Depth 100)
    Set-Content -Path (Join-Path $OutDir 'user-values.json') -Value $userYaml -Encoding UTF8
  }

  return $chartDir
}

# ---- main -------------------------------------------------------------------

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Write-Host "[*] Looking for Helm release secret: release=$Release  ns=$Namespace"
$sec = Find-LatestReleaseSecret -Namespace $Namespace -Release $Release
Write-Host "[*] Found secret: $($sec.Name) (revision $($sec.Revision))"

Write-Host "[*] Decoding release payload..."
$rel = Get-DecodedRelease -Namespace $Namespace -SecretName $sec.Name

$chartName    = $rel.chart.metadata.name
$chartVersion = $rel.chart.metadata.version
$appVersion   = $rel.chart.metadata.appVersion
Write-Host "[*] Chart: $chartName  version=$chartVersion  app=$appVersion"
Write-Host "[*] Release status: $($rel.info.status)   namespace: $($rel.namespace)"

Write-Host "[*] Writing chart files into $OutDir ..."
$chartDir = Write-ChartFiles -Release $rel -OutDir $OutDir
Write-Host "[+] Chart written to: $chartDir"
Write-Host "[+] User values dumped to: $(Join-Path $OutDir 'user-values.json')"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  helm lint   $chartDir"
Write-Host "  helm template $Release $chartDir -f (Join-Path $OutDir 'user-values.json') | Out-File rendered.yaml"
