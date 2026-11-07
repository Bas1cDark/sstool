@echo off
chcp 65001 >nul
title BAS1CDARK MOD CHECKER
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = [IO.File]::ReadAllText('%~f0', [Text.Encoding]::UTF8); $m = '#PS_' + 'START#'; $s = $c.Substring($c.IndexOf($m) + $m.Length); Invoke-Expression $s"
echo.
pause
exit /b

#PS_START#
Add-Type -AssemblyName System.IO.Compression.FileSystem

Write-Host "==============================" -ForegroundColor Magenta
Write-Host "       BAS1CDARK MOD CHECKER" -ForegroundColor Magenta
Write-Host "==============================" -ForegroundColor Magenta
Write-Host ""

$folder = (Read-Host "Enter mods folder path").Trim('"')
if (-not (Test-Path -LiteralPath $folder)) {
    Write-Host "Folder not found." -ForegroundColor Red
    return
}

$jars = Get-ChildItem -LiteralPath $folder -Filter *.jar -File
if ($jars.Count -eq 0) {
    Write-Host "No .jar files found in this folder." -ForegroundColor Yellow
    return
}

$idOwners = @{}
$rows = foreach ($jar in $jars) {
    $modId = $null
    $loader = "unknown"
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)

        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'fabric.mod.json' } | Select-Object -First 1
        if ($entry) {
            $sr = New-Object System.IO.StreamReader($entry.Open())
            $json = $sr.ReadToEnd(); $sr.Close()
            $modId = ($json | ConvertFrom-Json).id
            $loader = "fabric"
        }
        else {
            $entry = $zip.Entries | Where-Object { $_.FullName -in @('META-INF/neoforge.mods.toml', 'META-INF/mods.toml') } | Select-Object -First 1
            if ($entry) {
                $sr = New-Object System.IO.StreamReader($entry.Open())
                $txt = $sr.ReadToEnd(); $sr.Close()
                if ($txt -match 'modId\s*=\s*"([^"]+)"') { $modId = $matches[1] }
                $loader = "forge"
            }
        }
    }
    catch {
        $loader = "corrupt"
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }

    $zone = Get-Content -LiteralPath $jar.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
    $srcUrl = ($zone | Where-Object { $_ -like 'HostUrl=*' }) -replace '^HostUrl=', ''
    $hash = (Get-FileHash -LiteralPath $jar.FullName -Algorithm SHA256).Hash.Substring(0, 12)

    if ($modId) {
        if (-not $idOwners.ContainsKey($modId)) { $idOwners[$modId] = @() }
        $idOwners[$modId] += $jar.Name
    }

    [pscustomobject]@{
        File   = $jar.Name
        Id     = $modId
        Loader = $loader
        Hash   = $hash
        Source = $srcUrl
        Hidden = [bool]($jar.Attributes -band [IO.FileAttributes]::Hidden)
        Size   = $jar.Length
    }
}

$mcDir = Split-Path -Parent $folder
$logPath = Join-Path $mcDir "logs\latest.log"
$logText = $null
if (Test-Path -LiteralPath $logPath) {
    $logText = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8)
}

foreach ($r in $rows) {
    $red = @()
    $yellow = @()

    if (-not $r.Source) { $red += "No download record (Zone.Identifier)" }
    if ($r.Loader -in @('corrupt', 'unknown')) { $red += "Could not read mod info" }
    if ($r.Size -eq 0) { $red += "File size is 0 bytes" }

    if ($r.Id -and $idOwners[$r.Id].Count -gt 1) { $yellow += ("Duplicate mod id: " + ($idOwners[$r.Id] -join ', ')) }
    if ($r.Id -and ($r.File -notmatch [regex]::Escape($r.Id))) { $yellow += "Filename does not match mod id" }
    if ($r.Hidden) { $yellow += "File is hidden" }

    if ($logText -ne $null -and $r.Id) {
        $pattern = "\b" + [regex]::Escape($r.Id) + "\b"
        if ($logText -notmatch $pattern) { $yellow += "Not found in latest.log (probably not loaded)" }
    }

    $color = if ($red.Count -gt 0) { 'Red' } elseif ($yellow.Count -gt 0) { 'Yellow' } else { 'Green' }

    Write-Host ""
    Write-Host ("{0}" -f $r.File) -ForegroundColor $color
    Write-Host ("  id: {0}   loader: {1}   sha256: {2}" -f $r.Id, $r.Loader, $r.Hash)
    Write-Host ("  Download source: {0}" -f $(if ($r.Source) { $r.Source } else { "not recorded" }))

    foreach ($f in $red)    { Write-Host "  [X] $f" -ForegroundColor Red }
    foreach ($f in $yellow) { Write-Host "  [!] $f" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host ("Total: {0} .jar file(s) scanned" -f $rows.Count) -ForegroundColor Cyan
if (-not $logText) { Write-Host "Note: latest.log not found, log check was skipped." -ForegroundColor DarkYellow }
