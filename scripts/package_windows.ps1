# ThriveWoo POS — Windows release packaging (Phase 6ZD).
# See docs/DESKTOP_RELEASE_BUILD.md.
#
# NOT YET EXECUTED: written on macOS; run it on a Windows 10/11 build machine
# and record the result before relying on it.
#
#   $env:POS_BASE_URL = "https://<api-host>"; .\scripts\package_windows.ps1
#   .\scripts\package_windows.ps1 -Unconfigured        # local smoke build only
#
# Optional Authenticode signing (values come from the environment, never
# printed): the certificate must be in the current user's or machine's store.
#   $env:WINDOWS_SIGN_CERT_SHA1  = "<certificate thumbprint>"
#   $env:WINDOWS_SIGN_TIMESTAMP_URL = "<RFC 3161 timestamp URL from the CA>"
#
# Output: build\dist\windows\ (gitignored): a portable ZIP of the whole
# Release folder (buskit_pos.exe + DLLs + data\). No installer is produced.
[CmdletBinding()]
param([switch]$Unconfigured)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

function Fail([string]$Message) { Write-Error "ERROR: $Message"; exit 1 }

# --- Server address (mirrors AppConfig.releaseBaseUrlProblem) --------------
$defines = @()
if ($Unconfigured) {
  if ($env:POS_BASE_URL) { Fail '-Unconfigured and POS_BASE_URL are mutually exclusive' }
  $label = 'unconfigured'
  Write-Host 'NOTE: -Unconfigured - the app will show its configuration screen and contact no server.'
} else {
  $url = "$env:POS_BASE_URL".Trim()
  if (-not $url) { Fail 'POS_BASE_URL is not set ($env:POS_BASE_URL = "https://<api-host>"), or pass -Unconfigured for a local smoke build' }
  $uri = $null
  if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { Fail 'POS_BASE_URL is not a valid URL' }
  if ($uri.Scheme -ne 'https') { Fail 'POS_BASE_URL must start with https://' }
  if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) { Fail 'POS_BASE_URL must not contain credentials, a query or a fragment' }
  $h = $uri.Host.ToLowerInvariant()
  if ($h -in @('localhost', '0.0.0.0', '10.0.2.2', '[::1]', '::1') -or $h.StartsWith('127.')) { Fail 'POS_BASE_URL is a development address' }
  $defines += "--dart-define=POS_BASE_URL=$url"
  $label = 'configured'
}

$versionLine = (Select-String -Path pubspec.yaml -Pattern '^version: ' | Select-Object -First 1).Line
$version = $versionLine.Substring('version: '.Length).Trim()
$buildName, $buildNumber = $version.Split('+')
$defines += "--dart-define=APP_VERSION=$buildName"

# --- Build ------------------------------------------------------------------
flutter build windows --release @defines
if ($LASTEXITCODE -ne 0) { Fail 'flutter build windows failed' }

$release = 'build\windows\x64\runner\Release'
$exe = Join-Path $release 'buskit_pos.exe'
foreach ($required in @($exe, (Join-Path $release 'flutter_windows.dll'), (Join-Path $release 'data\app.so'),
                        (Join-Path $release 'data\icudtl.dat'), (Join-Path $release 'data\flutter_assets'))) {
  if (-not (Test-Path $required)) { Fail "missing from the Release folder: $required" }
}

$info = (Get-Item $exe).VersionInfo
if ($info.ProductName -ne 'ThriveWoo POS') { Fail "unexpected ProductName: $($info.ProductName)" }
if ($info.CompanyName -ne 'ThriveWoo') { Fail "unexpected CompanyName: $($info.CompanyName)" }
if ($info.OriginalFilename -ne 'buskit_pos.exe') { Fail "unexpected OriginalFilename: $($info.OriginalFilename)" }
if ($info.ProductVersion -notlike "$buildName*") { Fail "ProductVersion $($info.ProductVersion) does not match pubspec.yaml $version" }
Write-Host "Version resource OK: $($info.ProductName) $($info.ProductVersion) by $($info.CompanyName)"

# --- Optional Authenticode signing -----------------------------------------
$signMode = 'unsigned'
if ($env:WINDOWS_SIGN_CERT_SHA1) {
  if (-not $env:WINDOWS_SIGN_TIMESTAMP_URL) { Fail 'WINDOWS_SIGN_TIMESTAMP_URL is required with WINDOWS_SIGN_CERT_SHA1' }
  $toSign = @($exe) + (Get-ChildItem $release -Filter *.dll | ForEach-Object FullName)
  signtool sign /sha1 $env:WINDOWS_SIGN_CERT_SHA1 /fd SHA256 /tr $env:WINDOWS_SIGN_TIMESTAMP_URL /td SHA256 @toSign
  if ($LASTEXITCODE -ne 0) { Fail 'signtool sign failed' }
  signtool verify /pa /all @toSign
  if ($LASTEXITCODE -ne 0) { Fail 'signtool verify failed' }
  $signMode = 'signed'
}

# --- Secret / source exclusion ---------------------------------------------
$forbidden = @('.env', '.env.*', '.env_*', '*.env', '*.p12', '*.pfx', '*.p8', '*.pem', '*.key', '*.jks',
               '*.keystore', 'key.properties', '*.cer', '*.dart', 'pubspec.yaml', 'pubspec.lock',
               'CMakeLists.txt', '*.pdb', '*.ilk', '*.exp', '*.lib')
$bad = Get-ChildItem $release -Recurse -Force -File -Include $forbidden
if ($bad) { $bad | ForEach-Object { Write-Host "forbidden file: $($_.FullName)" }; Fail 'artifact contains forbidden files' }
$keyHits = Get-ChildItem $release -Recurse -File | Select-String -Pattern '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -List
if ($keyHits) { $keyHits | ForEach-Object { Write-Host "private key material in: $($_.Path)" }; Fail 'artifact contains private key material' }

# --- Package (portable ZIP of the whole Release folder) ---------------------
$out = 'build\dist\windows'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
$zip = Join-Path $out "ThriveWoo-POS-$buildName-$buildNumber-windows-x64-$signMode-$label.zip"
$stage = Join-Path $out 'ThriveWoo POS'
Copy-Item $release $stage -Recurse
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item $stage -Recurse -Force

# Re-open the archive to confirm it is readable and complete.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $zip))
try {
  $names = $archive.Entries | ForEach-Object FullName
  foreach ($required in @('buskit_pos.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
    if (-not ($names | Where-Object { ($_ -replace '\\', '/') -like "*/$required" })) { Fail "zip is missing $required" }
  }
  Write-Host "zip entries: $($names.Count)"
} finally { $archive.Dispose() }

Get-FileHash $zip -Algorithm SHA256 | Format-List
Write-Host "Signing: $signMode   Server: $label"
if ($signMode -eq 'unsigned') { Write-Host 'UNSIGNED - SmartScreen will warn on other PCs. For testing only.' }
Write-Host 'The target PC also needs the Microsoft Visual C++ 2015-2022 Redistributable (x64).'
