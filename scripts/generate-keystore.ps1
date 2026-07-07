param(
    [string]$OutFile = "android/release.keystore",
    [string]$Alias = "moto_release",
    [int]$ValidityDays = 10000,
    [string]$KeyAlg = "RSA",
    [int]$KeySize = 2048
)

Write-Host "This script generates an Android keystore using Java's keytool."
Write-Host "If keytool is not on your PATH, run this from a Developer Command Prompt or ensure JDK is installed."

if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
    throw "keytool not found. Install JDK and ensure keytool is on PATH."
}

$storePass = Read-Host -Prompt "Enter store password" -AsSecureString
$keyPass = Read-Host -Prompt "Enter key password (press Enter to reuse store password)" -AsSecureString

if (-not $keyPass) {
    $keyPass = $storePass
}

$storePassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($storePass))
$keyPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($keyPass))

$dn = Read-Host -Prompt "Enter Distinguished Name (e.g. CN=Your Name, OU=OrgUnit, O=Org, L=City, ST=State, C=US)"
if (-not $dn) { $dn = "CN=MotoCam Developer, OU=Dev, O=MotoCam, L=Unknown, ST=Unknown, C=US" }

Write-Host "Generating keystore at $OutFile..."

mkdir (Split-Path $OutFile -Parent) -ErrorAction SilentlyContinue | Out-Null

$cmd = "keytool -genkeypair -alias $Alias -keyalg $KeyAlg -keysize $KeySize -keystore `"$OutFile`" -storepass $storePassPlain -keypass $keyPassPlain -validity $ValidityDays -dname `"$dn`""

Write-Host "Running: $cmd"
Invoke-Expression $cmd

if (Test-Path $OutFile) {
    Write-Host "Keystore generated: $OutFile"
    Write-Host "Create android/key.properties from android/key.properties.template and fill values accordingly."
} else {
    throw "Failed to generate keystore."
}
