param(
    [switch]$SkipAnalyze,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

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

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$gradleFile = Join-Path $repoRoot 'android/app/build.gradle.kts'
$manifestFile = Join-Path $repoRoot 'android/app/src/main/AndroidManifest.xml'
$iosPlistFile = Join-Path $repoRoot 'ios/Runner/Info.plist'
$backupRulesFile = Join-Path $repoRoot 'android/app/src/main/res/xml/backup_rules.xml'
$dataExtractionRulesFile = Join-Path $repoRoot 'android/app/src/main/res/xml/data_extraction_rules.xml'

Write-Host 'Running release security precheck...' -ForegroundColor Cyan

Assert-Contains -FilePath $gradleFile -Pattern 'signingConfig\s*=\s*signingConfigs\.getByName\("release"\)' -Message 'Release signing config is not set to release key.'
Assert-NotContains -FilePath $gradleFile -Pattern 'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)' -Message 'Debug signing is still configured for release build.'

Assert-NotContains -FilePath $manifestFile -Pattern 'MANAGE_EXTERNAL_STORAGE' -Message 'MANAGE_EXTERNAL_STORAGE must not be declared for Play release.'
Assert-NotContains -FilePath $manifestFile -Pattern 'tools:ignore\s*=\s*"ScopedStorage"' -Message 'Scoped storage lint suppression should not be present.'
Assert-Contains -FilePath $manifestFile -Pattern 'android:allowBackup\s*=\s*"false"' -Message 'android:allowBackup must be false.'
Assert-Contains -FilePath $manifestFile -Pattern 'android:dataExtractionRules\s*=\s*"@xml/data_extraction_rules"' -Message 'Manifest must reference data extraction rules.'
Assert-Contains -FilePath $manifestFile -Pattern 'android:fullBackupContent\s*=\s*"@xml/backup_rules"' -Message 'Manifest must reference full backup rules.'
Assert-Contains -FilePath $manifestFile -Pattern 'com\.example\.motocam\.permission\.INTERNAL_BROADCAST' -Message 'Internal broadcast permission is missing.'

if (-not (Test-Path $backupRulesFile)) {
    throw 'backup_rules.xml is missing.'
}
if (-not (Test-Path $dataExtractionRulesFile)) {
    throw 'data_extraction_rules.xml is missing.'
}

Assert-NotContains -FilePath $iosPlistFile -Pattern 'NSLocalNetworkUsageDescription' -Message 'NSLocalNetworkUsageDescription should be removed unless local network is used.'
Assert-NotContains -FilePath $iosPlistFile -Pattern 'NSBonjourServiceTypes' -Message 'NSBonjourServiceTypes should be removed unless Bonjour discovery is used.'

if (-not $SkipAnalyze) {
    Write-Host 'Running flutter analyze...' -ForegroundColor Cyan
    flutter analyze
}

if (-not $SkipTests) {
    Write-Host 'Running flutter test...' -ForegroundColor Cyan
    flutter test
}

Write-Host 'Release security precheck passed.' -ForegroundColor Green
