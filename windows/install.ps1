$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$State = Join-Path $env:LOCALAPPDATA 'SafeWhisper'
$Run = Join-Path $State 'run'
$Venv = Join-Path $State 'venv'
New-Item -ItemType Directory -Force -Path $Run | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Run 'engine.sock'), (Join-Path $Run 'helper.sock')

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is required.' }
docker info | Out-Null
$env:SAFEWHISPER_RUN_DIR = $Run

$null = docker image inspect safewhisper-engine:local 2>$null
if ($LASTEXITCODE -ne 0) {
    $Bundle = Join-Path $Root 'safewhisper-engine-image.tar.gz'
    if (-not (Test-Path $Bundle)) { throw 'Engine image is missing. Copy safewhisper-engine-image.tar.gz or build on a connected machine.' }
    docker load -i $Bundle
}
docker compose -f (Join-Path $Root 'docker-compose.yml') -f (Join-Path $Root 'windows/docker-compose.windows.yml') up -d --force-recreate

if (-not (Test-Path (Join-Path $Venv 'Scripts/python.exe'))) {
    py -3.11 -m venv $Venv
}
& (Join-Path $Venv 'Scripts/python.exe') -m pip install -r (Join-Path $Root 'windows/requirements.txt')

$env:PYTHONPATH = Join-Path $Root 'src'
$env:SAFEWHISPER_HELPER_SOCKET = Join-Path $Run 'helper.sock'
$env:SAFEWHISPER_CONTAINER = 'safewhisper-engine'
$Helper = Start-Process -FilePath (Join-Path $Venv 'Scripts/python.exe') -ArgumentList '-m','safewhisper.helper' -WorkingDirectory $Root -WindowStyle Hidden -PassThru
Start-Process -FilePath (Join-Path $Venv 'Scripts/python.exe') -ArgumentList (Join-Path $Root 'windows/safewhisper_windows.py') -WorkingDirectory $Root
Write-Host "SafeWhisper started. Helper PID: $($Helper.Id)"
Write-Host "Hotkey: Ctrl+Alt+Shift+K | Cancel: Escape"
