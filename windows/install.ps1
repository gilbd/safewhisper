$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$State = Join-Path $env:LOCALAPPDATA 'SafeWhisper'
$Run = Join-Path $State 'run'
$Venv = Join-Path $State 'venv'
New-Item -ItemType Directory -Force -Path $Run | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Run 'engine.sock'), (Join-Path $Run 'helper.sock')

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is required.' }
$Python = $null
if (Get-Command py -ErrorAction SilentlyContinue) {
    $candidate = (& py -3.11 -c "import sys; print(sys.executable)" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $candidate) { $Python = $candidate.Trim() }
    if (-not $Python) {
        $candidate = (& py -3 -c "import sys; print(sys.executable)" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $candidate) { $Python = $candidate.Trim() }
    }
}
if (-not $Python -and (Get-Command python -ErrorAction SilentlyContinue)) { $Python = (Get-Command python).Source }
if (-not $Python) { throw 'Python 3.11+ is required.' }
$env:SAFEWHISPER_RUN_DIR = $Run

$null = docker image inspect safewhisper-engine:local 2>$null
if ($LASTEXITCODE -ne 0) {
    $Bundle = Join-Path $Root 'safewhisper-engine-image.tar.gz'
    if (-not (Test-Path $Bundle)) { throw 'Engine image is missing. Copy safewhisper-engine-image.tar.gz or build on a connected machine.' }
    docker load -i $Bundle
}
docker compose -f (Join-Path $Root 'docker-compose.yml') -f (Join-Path $Root 'windows/docker-compose.windows.yml') up -d --force-recreate

$VenvPython = Join-Path $Venv 'Scripts/python.exe'
$RecreateVenv = -not (Test-Path $VenvPython)
if (-not $RecreateVenv) {
    & $VenvPython -c "import sys; assert sys.version_info >= (3, 11)" *> $null
    if ($LASTEXITCODE -ne 0) { $RecreateVenv = $true }
}
if ($RecreateVenv) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Venv
    & $Python -m venv $Venv
}
$VenvPython = Join-Path $Venv 'Scripts/python.exe'
& $VenvPython -c "import sys; assert sys.version_info >= (3, 11)"
& $VenvPython -m pip install -r (Join-Path $Root 'windows/requirements.txt')

$env:PYTHONPATH = Join-Path $Root 'src'
$env:SAFEWHISPER_HELPER_SOCKET = Join-Path $Run 'helper.sock'
$env:SAFEWHISPER_CONTAINER = 'safewhisper-engine'
$Helper = Start-Process -FilePath $VenvPython -ArgumentList '-m','safewhisper.helper' -WorkingDirectory $Root -WindowStyle Hidden -PassThru
$Healthy = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    & $VenvPython -m safewhisper.cli health *> $null
    if ($LASTEXITCODE -eq 0) { $Healthy = $true; break }
}
if (-not $Healthy) { throw "SafeWhisper helper did not become healthy. Check $State\windows.log" }
Start-Process -FilePath $VenvPython -ArgumentList (Join-Path $Root 'windows/safewhisper_windows.py') -WorkingDirectory $Root
Write-Host "SafeWhisper started. Helper PID: $($Helper.Id)"
Write-Host "Hotkey: Ctrl+Alt+Shift+K | Cancel: Escape"
