param(
    # A relative path is resolved against the repository root, not the current
    # directory, so the keystore always lands where the ignore rules expect it.
    [string]$OutFile = "android/release.keystore",
    [string]$Alias = "moto_release",
    [int]$ValidityDays = 10000,
    [string]$KeyAlg = "RSA",
    [int]$KeySize = 2048
)

$ErrorActionPreference = 'Stop'

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][securestring]$Value)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

Write-Host "This script generates an Android keystore using Java's keytool."
Write-Host "If keytool is not on your PATH, run this from a Developer Command Prompt or ensure JDK is installed."

if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
    throw "keytool not found. Install JDK and ensure keytool is on PATH."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
    $OutFile = Join-Path $repoRoot $OutFile
}
$OutFile = [System.IO.Path]::GetFullPath($OutFile)

$storePass = Read-Host -Prompt "Enter store password (at least 6 characters)" -AsSecureString
$keyPass = Read-Host -Prompt "Enter key password (press Enter to reuse store password)" -AsSecureString

# Read-Host returns an empty SecureString (which is still truthy) on Enter.
if ($keyPass.Length -eq 0) {
    $keyPass = $storePass
}
if ($storePass.Length -lt 6 -or $keyPass.Length -lt 6) {
    throw "keytool requires passwords of at least 6 characters."
}

$dn = Read-Host -Prompt "Enter Distinguished Name (e.g. CN=Your Name, OU=OrgUnit, O=Org, L=City, ST=State, C=US)"
if (-not $dn) { $dn = "CN=MotoCam Developer, OU=Dev, O=MotoCam, L=Unknown, ST=Unknown, C=US" }

Write-Host "Generating keystore at $OutFile..."

New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null

# Passwords reach keytool through process-local environment variables
# (-storepass:env / -keypass:env), so they never appear on the command line or
# in console output. Arguments are passed as an array, not re-parsed.
$storePassEnv = 'MOTOCAM_KEYTOOL_STOREPASS'
$keyPassEnv = 'MOTOCAM_KEYTOOL_KEYPASS'
$keytoolArgs = @(
    '-genkeypair',
    '-alias', $Alias,
    '-keyalg', $KeyAlg,
    '-keysize', "$KeySize",
    '-keystore', $OutFile,
    '-storepass:env', $storePassEnv,
    '-keypass:env', $keyPassEnv,
    '-validity', "$ValidityDays",
    '-dname', $dn
)

try {
    [Environment]::SetEnvironmentVariable($storePassEnv, (ConvertTo-PlainText $storePass), 'Process')
    [Environment]::SetEnvironmentVariable($keyPassEnv, (ConvertTo-PlainText $keyPass), 'Process')
    & keytool @keytoolArgs
    $keytoolExitCode = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable($storePassEnv, $null, 'Process')
    [Environment]::SetEnvironmentVariable($keyPassEnv, $null, 'Process')
}

if ($keytoolExitCode -ne 0) {
    throw "keytool failed with exit code $keytoolExitCode."
}

if (Test-Path $OutFile) {
    Write-Host "Keystore generated: $OutFile"
    Write-Host "Create android/key.properties from android/key.properties.template and fill values accordingly."
    Write-Host "storeFile is resolved relative to android/app/; the template default ../release.keystore matches this script's default output."
} else {
    throw "Failed to generate keystore."
}
