# DeviceIdle Manager - Build Script
# Run this script to create the flashable ZIP

$ErrorActionPreference = "Stop"

$moduleName = "ksu_deviceidle_manager"
$version = "v1.0.0"
$zipName = "${moduleName}-${version}.zip"
$sourceDir = "."
$tempDir = "build_temp"

# Clean up
if (Test-Path $tempDir) {
    Remove-Item -Recurse -Force $tempDir
}
if (Test-Path $zipName) {
    Remove-Item -Force $zipName
}

# Create temp directory
New-Item -ItemType Directory -Path $tempDir | Out-Null

# Copy files (excluding build script and temp dir)
$exclude = @('build.ps1', 'build_temp', '*.zip', '.git', '.gitignore', 'README.md')
Get-ChildItem -Path $sourceDir -Exclude $exclude | ForEach-Object {
    $dest = Join-Path $tempDir $_.Name
    if ($_.PSIsContainer) {
        Copy-Item -Recurse -Force $_.FullName $dest
    } else {
        Copy-Item -Force $_.FullName $dest
    }
}

# Create ZIP with Android-friendly forward-slash entry names.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipName, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -Path $tempDir -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring((Resolve-Path $tempDir).Path.Length + 1)
        $entryName = $relative -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entryName) | Out-Null
    }
} finally {
    if ($zip) {
        $zip.Dispose()
    }
}

# Clean up
Remove-Item -Recurse -Force $tempDir

Write-Host "Build complete: $zipName" -ForegroundColor Green
Write-Host ""
Write-Host "Install via KernelSU Manager:" -ForegroundColor Cyan
Write-Host "  1. Open KernelSU Manager" -ForegroundColor White
Write-Host "  2. Go to Modules tab" -ForegroundColor White
Write-Host "  3. Click Install from storage" -ForegroundColor White
Write-Host "  4. Select $zipName" -ForegroundColor White
