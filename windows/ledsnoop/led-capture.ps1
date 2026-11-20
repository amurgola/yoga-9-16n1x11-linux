# led-capture.ps1 - find what switches the webcam indicator light on.
#
# Builds ledsnoop.sys (the earlier ccusnoop capture driver plus a read-only dump of the
# SoC GPIO pin state), loads it with the camera closed, opens the Camera app, and unloads
# it while the preview is still running. Result: C:\ledsnoop.log
#
#   powershell -ExecutionPolicy Bypass -File C:\ledsnoop\led-capture.ps1
#
# Run from a normal (non-admin) PowerShell; it asks for elevation once (UAC).
# Needs test signing (admin prompt: bcdedit /set testsigning on, then reboot into Windows).
param(
    [int]$PreviewSeconds = 15,
    [switch]$Elevated
)

$dir  = 'C:\ledsnoop'
$sys  = Join-Path $dir 'ledsnoop.sys'
$flag = Join-Path $dir 'stop.flag'
$elog = Join-Path $dir 'capture-elevated.log'
$log  = 'C:\ledsnoop.log'

if ($Elevated) {
    & {
        "started $(Get-Date -Format s)"
        if (Test-Path $log) { Move-Item $log "C:\ledsnoop-$(Get-Date -Format yyyyMMdd-HHmmss).log" }
        sc.exe create ledsnoop type= kernel binPath= $sys
        sc.exe start ledsnoop
        if ($LASTEXITCODE -ne 0) { "START FAILED (exit $LASTEXITCODE)"; sc.exe delete ledsnoop; return }
        # Safety net: never leave the polling driver loaded for more than 2 minutes.
        $deadline = (Get-Date).AddSeconds(120)
        while (-not (Test-Path $flag) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        sc.exe stop ledsnoop
        sc.exe delete ledsnoop
        "finished $(Get-Date -Format s)"
    } *>&1 | Out-File $elog -Encoding utf8
    exit
}

# ---- 1. test signing ----
$opts = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name SystemStartOptions).SystemStartOptions
if ($opts -notmatch 'TESTSIGNING') {
    Write-Host "Test signing is not active in this boot."
    Write-Host "Open an ADMIN prompt, run:   bcdedit /set testsigning on   then reboot into Windows and run this script again."
    exit 2
}

# ---- 2. build (only if ledsnoop.sys is not there yet) ----
if (-not (Test-Path $sys)) {
    Write-Host "Building ledsnoop.sys ..."
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msbuild = $null
    if (Test-Path $vswhere) {
        $msbuild = & $vswhere -latest -prerelease -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    }
    if (-not $msbuild) { Write-Host "MSBuild not found (Visual Studio + WDK are needed, as for ccusnoop). See README.txt, 'If the build fails'."; exit 3 }
    Push-Location $dir
    & $msbuild ledsnoop.vcxproj /nologo /v:minimal /p:Configuration=Release /p:Platform=ARM64 2>&1 | Tee-Object -FilePath (Join-Path $dir 'build.log')
    Pop-Location
    $built = Get-ChildItem $dir -Recurse -Filter ledsnoop.sys | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $built) { Write-Host "Build produced no ledsnoop.sys. See C:\ledsnoop\build.log and README.txt, 'If the build fails'."; exit 3 }
    Copy-Item $built.FullName $sys -Force
    Write-Host "Built: $sys"
}

# ---- 3. capture ----
Get-Process WindowsCamera -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3                      # let the camera power down fully
Remove-Item $flag, $elog -ErrorAction SilentlyContinue
try {
    $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList `
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Elevated'
} catch { Write-Host "Elevation was declined or failed: $($_.Exception.Message)"; exit 4 }

$running = $false
for ($i = 0; $i -lt 150 -and -not $p.HasExited; $i++) {
    if ((sc.exe query ledsnoop) -match 'RUNNING') { $running = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $running) {
    Write-Host "Driver did not start. Elevated log:"
    if (Test-Path $elog) { Get-Content $elog }
    Write-Host "If it says the driver is not signed, see README.txt, 'If the driver will not load'."
    exit 5
}

Write-Host "Driver running, camera closed: recording the light-off state for 4 s ..."
Start-Sleep -Seconds 4
Write-Host "Opening Camera. WATCH THE LIGHT next to the webcam: does it come on?"
Start-Process 'microsoft.windows.camera:'
Start-Sleep -Seconds $PreviewSeconds
New-Item -ItemType File -Path $flag -Force | Out-Null    # stop while the preview is still running
$p.WaitForExit(60000) | Out-Null
Remove-Item $flag -ErrorAction SilentlyContinue

Write-Host "--- elevated log"
if (Test-Path $elog) { Get-Content $elog }
Write-Host "--- result"
if (Test-Path $log) {
    $f = Get-Item $log
    $dumps = (Select-String -Path $log -Pattern '^=== DUMP').Count
    $gpio  = (Select-String -Path $log -Pattern '^  gpio\+').Count
    Write-Host ("{0}: {1} bytes, {2} register dumps, {3} gpio lines" -f $log, $f.Length, $dumps, $gpio)
    if ($gpio -eq 0) { Write-Host "WARNING: no gpio lines in the log." }
    Write-Host "Done. You can close the Camera app. Leave C:\ledsnoop.log where it is; Linux reads it from there."
    Write-Host "When finished with captures: admin prompt, bcdedit /set testsigning off, reboot."
} else {
    Write-Host "$log was not written."
    exit 6
}
