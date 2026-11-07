@echo off
title Hide Folders Checker
set "BATDIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content -LiteralPath '%~f0' -Raw) -split ('#PS'+'_START'))[1]"
echo.
pause
exit /b

#PS_START
$ErrorActionPreference = 'SilentlyContinue'

# ---------- settings ----------
$installPaths = @(
    'C:\Program Files\Hide Folders',
    'C:\Program Files (x86)\Hide Folders'
)
# words matched against: process name, exe path, product/description/company, window title
$keywords = @('hide folders', 'hidefolders', 'hide folder', 'hidefolder', 'hide_folders')
# ------------------------------

Write-Host ''
Write-Host '=== Hide Folders Checker ===' -ForegroundColor Cyan
Write-Host ''

# 1) Known hashes of the exe files from the install folder (catches renamed copies)
$knownHashes = @{}
foreach ($p in $installPaths) {
    if (Test-Path -LiteralPath $p) {
        Get-ChildItem -LiteralPath $p -Recurse -File -Force -Include *.exe,*.dll | ForEach-Object {
            $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            if ($h) { $knownHashes[$h] = $_.FullName }
        }
    }
}

# 2) Look through running processes (Task Manager list)
$hits = @()
$procs = Get-CimInstance Win32_Process
$windowTitles = @{}
Get-Process | ForEach-Object { if ($_.MainWindowTitle) { $windowTitles[[int]$_.Id] = $_.MainWindowTitle } }

foreach ($pr in $procs) {
    $reasons = @()
    $path = $pr.ExecutablePath
    $name = $pr.Name
    $title = $windowTitles[[int]$pr.ProcessId]
    $ver = $null
    if ($path -and (Test-Path -LiteralPath $path)) { $ver = (Get-Item -LiteralPath $path -Force).VersionInfo }

    $fields = @{
        'process name'  = $name
        'exe path'      = $path
        'product name'  = $ver.ProductName
        'description'   = $ver.FileDescription
        'company'       = $ver.CompanyName
        'original name' = $ver.OriginalFilename
        'window title'  = $title
    }
    foreach ($k in $fields.Keys) {
        $v = [string]$fields[$k]
        if (-not $v) { continue }
        foreach ($w in $keywords) {
            if ($v.ToLower().Contains($w)) { $reasons += "$k contains '$w'"; break }
        }
    }
    if ($path) {
        foreach ($ip in $installPaths) {
            if ($path.ToLower().StartsWith($ip.ToLower())) { $reasons += 'runs from the Hide Folders install folder'; break }
        }
        if ($knownHashes.Count -gt 0) {
            $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($h -and $knownHashes.ContainsKey($h)) { $reasons += 'file content identical to Hide Folders exe (possibly renamed)' }
        }
    }
    if ($reasons.Count -gt 0) {
        $hits += [pscustomobject]@{ PID = $pr.ProcessId; Name = $name; Path = $path; Title = $title; Reasons = ($reasons | Select-Object -Unique) }
    }
}

# 3) Check install location (folders + registry uninstall entries)
$locations = @()
foreach ($p in $installPaths) {
    if (Test-Path -LiteralPath $p) { $locations += $p }
}
$regRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($r in $regRoots) {
    Get-ItemProperty -Path $r | Where-Object { $_.DisplayName -and $_.DisplayName.ToLower().Contains('hide folder') } | ForEach-Object {
        if ($_.InstallLocation) { $locations += $_.InstallLocation.TrimEnd('\') }
        else { $locations += "(registered as '$($_.DisplayName)', no install path)" }
    }
}
foreach ($h in $hits) {
    if ($h.Path) { $locations += (Split-Path $h.Path -Parent) }
}
$locations = $locations | Select-Object -Unique

# 4) Result
if ($hits.Count -gt 0) {
    Write-Host '################################################' -ForegroundColor Red
    Write-Host '#            CHEAT DETECTED !!!                #' -ForegroundColor Red
    Write-Host '#     Hide Folders is RUNNING on this PC       #' -ForegroundColor Red
    Write-Host '################################################' -ForegroundColor Red
    foreach ($h in $hits) {
        Write-Host ''
        Write-Host ("  PID    : {0}" -f $h.PID) -ForegroundColor Yellow
        Write-Host ("  Name   : {0}" -f $h.Name)
        Write-Host ("  Path   : {0}" -f $h.Path)
        if ($h.Title) { Write-Host ("  Window : {0}" -f $h.Title) }
        foreach ($r in $h.Reasons) { Write-Host ("  Why    : {0}" -f $r) -ForegroundColor Magenta }
    }
    for ($i = 0; $i -lt 5; $i++) { [console]::Beep(1000, 300); Start-Sleep -Milliseconds 100 }
}
else {
    Write-Host '################################################' -ForegroundColor Green
    Write-Host '#         HE IS NOT CHEATER                    #' -ForegroundColor Green
    Write-Host '#   No Hide Folders process is running         #' -ForegroundColor Green
    Write-Host '################################################' -ForegroundColor Green
}

Write-Host ''
Write-Host '--- Install location check ---' -ForegroundColor Cyan
if ($locations.Count -gt 0) {
    foreach ($l in $locations) { Write-Host ("  FOUND: {0}" -f $l) -ForegroundColor Yellow }
    if ($hits.Count -eq 0) {
        Write-Host '  Hide Folders is installed but not running right now (still suspicious).' -ForegroundColor Magenta
    }
}
else {
    Write-Host '  Not installed in C:\Program Files\Hide Folders (or Program Files (x86)).' -ForegroundColor Green
}
