param(
    [switch]$SkipAnalyze,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

$androidNs = 'http://schemas.android.com/apk/res/android'
$toolsNs = 'http://schemas.android.com/tools'

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $content = Get-Content -Raw -Path $FilePath
    if ($content -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $content = Get-Content -Raw -Path $FilePath
    if ($content -match $Pattern) {
        throw $Message
    }
}

# Parses an XML file so that checks see elements and attributes, not text that
# may sit inside comments.
function Read-XmlFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $document = New-Object System.Xml.XmlDocument
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($FilePath, $settings)
    try {
        $document.Load($reader)
    } finally {
        $reader.Dispose()
    }
    return $document
}

function Get-ChildElements {
    param([Parameter(Mandatory = $true)]$Node, [string]$LocalName)

    return @($Node.ChildNodes | Where-Object {
            $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            (-not $LocalName -or $_.LocalName -eq $LocalName)
        })
}

function Get-DeclaredPermissions {
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Manifest)

    $root = $Manifest.DocumentElement
    return @(
        @(Get-ChildElements $root 'uses-permission') + @(Get-ChildElements $root 'uses-permission-sdk-23') |
            ForEach-Object { $_.GetAttribute('name', $androidNs) }
    )
}

# Permissions that must never ship (owner decisions: no all-files access, no
# background location).
$forbiddenPermissions = @(
    'android.permission.MANAGE_EXTERNAL_STORAGE',
    'android.permission.ACCESS_BACKGROUND_LOCATION'
)

function Assert-NoForbiddenPermissions {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Manifest,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $declared = Get-DeclaredPermissions $Manifest
    foreach ($permission in $forbiddenPermissions) {
        if ($declared -contains $permission) {
            throw "$permission must not be declared ($Label)."
        }
    }
}

function Assert-NativeSuccess {
    param([Parameter(Mandatory = $true)][string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$gradleFile = Join-Path $repoRoot 'android/app/build.gradle.kts'
$manifestFile = Join-Path $repoRoot 'android/app/src/main/AndroidManifest.xml'
$mergedReleaseManifestFile = Join-Path $repoRoot 'build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml'
$androidAssetsDir = Join-Path $repoRoot 'android/app/src/main/assets'
$backupRulesFile = Join-Path $repoRoot 'android/app/src/main/res/xml/backup_rules.xml'
$dataExtractionRulesFile = Join-Path $repoRoot 'android/app/src/main/res/xml/data_extraction_rules.xml'

Write-Host 'Running release security precheck...' -ForegroundColor Cyan

# --- Signing ---------------------------------------------------------------
Assert-Contains -FilePath $gradleFile -Pattern 'signingConfig\s*=\s*signingConfigs\.getByName\("release"\)' -Message 'Release signing config is not set to release key.'
Assert-NotContains -FilePath $gradleFile -Pattern 'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)' -Message 'Debug signing is still configured for release build.'

# --- Source manifest -------------------------------------------------------
$manifest = Read-XmlFile $manifestFile
Assert-NoForbiddenPermissions -Manifest $manifest -Label 'android/app/src/main/AndroidManifest.xml'

$scopedStorageSuppressions = @($manifest.SelectNodes('//*') | Where-Object {
        $_.GetAttribute('ignore', $toolsNs) -match 'ScopedStorage'
    })
if ($scopedStorageSuppressions.Count -gt 0) {
    throw 'Scoped storage lint suppression should not be present.'
}

$application = Get-ChildElements $manifest.DocumentElement 'application' | Select-Object -First 1
if (-not $application) {
    throw 'Manifest has no <application> element.'
}
if ($application.GetAttribute('allowBackup', $androidNs) -ne 'false') {
    throw 'android:allowBackup must be false.'
}
if ($application.GetAttribute('dataExtractionRules', $androidNs) -ne '@xml/data_extraction_rules') {
    throw 'Manifest must reference data extraction rules.'
}
if ($application.GetAttribute('fullBackupContent', $androidNs) -ne '@xml/backup_rules') {
    throw 'Manifest must reference full backup rules.'
}

# The Kotlin bridges rely on this permission being signature-protected.
$internalBroadcastPermissions = @(Get-ChildElements $manifest.DocumentElement 'permission' | Where-Object {
        $_.GetAttribute('name', $androidNs) -eq 'com.example.motocam.permission.INTERNAL_BROADCAST'
    })
if ($internalBroadcastPermissions.Count -ne 1) {
    throw 'Internal broadcast <permission> element is missing.'
}
if ($internalBroadcastPermissions[0].GetAttribute('protectionLevel', $androidNs) -ne 'signature') {
    throw 'Internal broadcast permission must have android:protectionLevel="signature".'
}

if (-not (Test-Path $backupRulesFile)) {
    throw 'backup_rules.xml is missing.'
}
if (-not (Test-Path $dataExtractionRulesFile)) {
    throw 'data_extraction_rules.xml is missing.'
}

# --- Merged release manifest (what actually ships) -------------------------
# Only present after `flutter build apk --release`; ignored when older than the
# source manifest so a stale build cannot fail or pass the check.
if ((Test-Path $mergedReleaseManifestFile) -and
    ((Get-Item $mergedReleaseManifestFile).LastWriteTimeUtc -ge (Get-Item $manifestFile).LastWriteTimeUtc)) {
    $mergedManifest = Read-XmlFile $mergedReleaseManifestFile
    Assert-NoForbiddenPermissions -Manifest $mergedManifest -Label 'merged release manifest'
    Write-Host 'Checked merged release manifest.' -ForegroundColor Cyan
} else {
    Write-Host 'Merged release manifest missing or stale; run after `flutter build apk --release` to check it.' -ForegroundColor Yellow
}

# --- Credential blobs and packaged assets ----------------------------------
if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $repoRoot '.git'))) {
    $trackedBlobs = @(git ls-files -- '*.a.conf' '*.a.olf' '*mappls*' '*.jks' '*.keystore' '*.p12' 'android/key.properties')
    Assert-NativeSuccess 'git ls-files'
    if ($trackedBlobs.Count -gt 0) {
        throw "Credential or signing files must not be tracked: $($trackedBlobs -join ', ')"
    }
}
# MotoCam ships no Android assets; anything here is packaged into every APK.
if ((Test-Path $androidAssetsDir) -and @(Get-ChildItem -Path $androidAssetsDir -Recurse -File).Count -gt 0) {
    throw 'android/app/src/main/assets must be empty; files there are packaged into every APK.'
}

# --- Analyze and test ------------------------------------------------------
if (-not $SkipAnalyze) {
    Write-Host 'Running flutter analyze...' -ForegroundColor Cyan
    flutter analyze
    Assert-NativeSuccess 'flutter analyze'
}

if (-not $SkipTests) {
    Write-Host 'Running flutter test...' -ForegroundColor Cyan
    flutter test
    Assert-NativeSuccess 'flutter test'
    # The landscape-off build (MOTOCAM_LANDSCAPE=false) takes other branches
    # in the recording screen, so the suite runs that way too.
    Write-Host 'Running flutter test with landscape recording off...' -ForegroundColor Cyan
    flutter test --dart-define=MOTOCAM_LANDSCAPE=false
    Assert-NativeSuccess 'flutter test --dart-define=MOTOCAM_LANDSCAPE=false'
}

Write-Host 'Release security precheck passed.' -ForegroundColor Green
