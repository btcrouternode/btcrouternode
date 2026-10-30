# SPDX-License-Identifier: GPL-2.0-only
# Knots Appliance - install local CA into Windows Trusted Root (N13 / U17)
# Prefer: double-click install-windows.bat (same folder as this .ps1).
# Or:  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
#      .\install-windows.ps1 -Router http://rnode.local
#      .\install-windows.ps1 -CaFile .\knots-ca.crt
#      .\install-windows.ps1 -CaFile .\knots-ca.crt -CheckOnly   (verify only)
# May prompt for Administrator (UAC / computer password).
# Only installs a CA restricted to this appliance (P4); prints its fingerprint.
# ASCII only: Windows PowerShell 5.1 reads downloads as ANSI when there is no BOM.

param(
  [string]$Router = "http://rnode.local",
  [string]$CaFile = "",
  # Folder the user saved install-windows.bat in (the .bat unpacks this script
  # to %TEMP%, so "next to this script" is not where a saved knots-ca.crt is).
  [string]$BatDir = "",
  # Verify the certificate and print its fingerprint, then stop: nothing is
  # installed and no elevation is requested (support / testing).
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
$Router = $Router.TrimEnd("/")
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$caPath = Join-Path $env:TEMP "knots-ca.crt"

# P4 (review 2026-10-10): fetch the router's CURRENT CA first; a copy saved
# next to this script before a factory reset / Renew is a different CA.
# A local file is only a fallback when the router cannot be reached.
$fetched = $false
if (-not $CaFile) {
  $caUrl = "$Router/knots-ca.crt"
  Write-Host "Downloading CA from $caUrl ..."
  try {
    Invoke-WebRequest -Uri $caUrl -OutFile $caPath -UseBasicParsing
    $fetched = $true
  } catch {
    $sidecar = Join-Path $here "knots-ca.crt"
    if ($BatDir) {
      $batSide = Join-Path $BatDir "knots-ca.crt"
      if (Test-Path $batSide) { $sidecar = $batSide }
    }
    if (Test-Path $sidecar) {
      Write-Host "Router not reachable - using local copy: $sidecar"
      $CaFile = $sidecar
    } else {
      throw "Could not download the certificate - stay on the router LAN (HTTP) and retry"
    }
  }
}
if (-not $fetched) {
  if (-not (Test-Path $CaFile)) { throw "CA file not found: $CaFile" }
  Write-Host "Using local CA: $CaFile"
  Copy-Item -Force $CaFile $caPath
}

$pem = Get-Content -Raw $caPath
if ($pem -notmatch "BEGIN CERTIFICATE") { Write-Host "ERROR: File does not look like a certificate."; exit 1 }

# P4: only trust a CA that is restricted to this appliance (P3). The name
# constraints extension must be critical and byte-for-byte the appliance's
# permitted set (localised Windows text would be fragile). Anything else
# could vouch for other websites on this computer, so it is refused.
$expectedNc = "306ea06c300d820b6e6f64652d726f75746572300e820c6b6e6f74732d726f75746572300b82096c6f63616c686f7374300782056c6f63616c300582036c616e300a87080a000000ff000000300a8708ac100000fff00000300a8708c0a80000ffff0000300a87087f000000ff000000"
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $caPath
# Refusals print a plain message and exit 1 (no PowerShell error trace).
function Refuse([string]$msg) {
  Write-Host ("ERROR: " + $msg)
  exit 1
}
if ($cert.Subject -notmatch "CN=Knots Appliance CA") { Refuse "This certificate is not a Knots Appliance CA - refusing to trust it." }
$bc = $cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.19" }
if (-not $bc -or -not ([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$bc).CertificateAuthority) {
  Refuse "Not a CA certificate - refusing to trust it."
}
$nc = $cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.30" }
$ncHex = ""
if ($nc) { $ncHex = (($nc.RawData | ForEach-Object { $_.ToString("x2") }) -join "") }
if (-not $nc -or -not $nc.Critical -or $ncHex -ne $expectedNc) {
  Write-Host "ERROR: this router's certificate is not restricted to the router itself."
  Write-Host "  On the router: Settings -> Renew HTTPS certificate, then run this again."
  exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$fp = (($sha.ComputeHash($cert.RawData) | ForEach-Object { $_.ToString("X2") }) -join ":")
Write-Host "Certificate: Knots Appliance CA (restricted to this router)"
Write-Host ("  SHA-256 fingerprint: " + $fp)
Write-Host "  (Compare with Router Settings -> HTTPS certificate on a device that already trusts it.)"
if ($CheckOnly) {
  Write-Host "CHECK-ONLY: certificate accepted - nothing installed."
  exit 0
}

Write-Host "Installing into Local Machine Trusted Root (UAC may prompt)..."
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

# Concatenate host and port. Do not put a colon immediately after a
# subexpression inside a double-quoted string (Windows PowerShell 5.1
# treats that as a scope; the string never closes; "} else {" is UnexpectedToken).
$uiHost = $Router -replace '^https?://', ''
$setupHttps = "https://" + $uiHost + "/setup.html?after_tls=1"

function Reopen-SetupHttps {
  Write-Host ""
  Write-Host ("Reopening Setup on " + $setupHttps + " ...")
  $ff = Get-Process -Name firefox -ErrorAction SilentlyContinue
  if ($ff) {
    Write-Host "Closing Firefox so it uses the Windows certificate store..."
    $ff | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $ffExe = Join-Path $env:ProgramFiles "Mozilla Firefox\firefox.exe"
    if (-not (Test-Path $ffExe)) {
      $ffExe = Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox\firefox.exe"
    }
    if (Test-Path $ffExe) {
      Start-Process -FilePath $ffExe -ArgumentList @("-new-window", $setupHttps)
      Write-Host "Firefox is opening the secure Setup page."
      return
    }
  }
  Start-Process $setupHttps
  Write-Host "Opening the secure Setup page in your browser."
}

if (-not $isAdmin) {
  $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Router `"$Router`""
  if ($CaFile) { $arg += " -CaFile `"$CaFile`"" }
  if ($BatDir) { $arg += " -BatDir `"$BatDir`"" }
  # Start-Process -Wait does not set $LASTEXITCODE - use -PassThru.ExitCode.
  $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arg -Wait -PassThru
  if ($p.ExitCode -ne 0) { exit $p.ExitCode }
  # Reopen as the logged-in user, not the elevated child (U17 / N13).
  Reopen-SetupHttps
  exit 0
}

& certutil.exe -addstore -f Root $caPath
if ($LASTEXITCODE -ne 0) { throw "certutil failed with $LASTEXITCODE" }

# Firefox has its own store - tell it to use the Windows store through the
# enterprise-policy REGISTRY key (P4/W10: writing distribution\policies.json
# replaced any existing Firefox policies - proxy, DoH, extension locks).
# Applies at next Firefox start; other policies are left untouched.
try {
  $key = "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\Certificates"
  New-Item -Path $key -Force | Out-Null
  New-ItemProperty -Path $key -Name "ImportEnterpriseRoots" -Value 1 -PropertyType DWord -Force | Out-Null
  Write-Host "Firefox: will use the Windows certificate store from next start."
} catch {
  Write-Host "Firefox policy (registry) write failed: $_"
}

Write-Host ""
Write-Host "Certificate installed."
exit 0

