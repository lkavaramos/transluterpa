# setup.ps1 - rehidrata a sessao efemera do TSplus, um clique = ambiente de pe:
#   1) VS Code PORTATIL (sem admin/instalador)
#   2) baixa o repo (ZIP do GitHub, sem git)
#   3) gera o .env (pergunta os tokens, se ainda nao existir)
#   4) abre o VS Code e SOBE o worker
#
# Baixado e executado pelo setup.bat (iwr setup.ps1 | iex).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===== AJUSTE AQUI =====
$RepoOwner  = 'lkavaramos'
$RepoName   = 'transluterpa'
$Branch     = 'main'
$DefaultUrl = 'https://senior.lucas-ramos-086.workers.dev'
# =======================

$Dev = Join-Path $env:USERPROFILE 'dev'
New-Item -ItemType Directory -Force -Path $Dev | Out-Null

function Step($n, $msg) { Write-Host ("`n== {0} == {1}" -f $n, $msg) -ForegroundColor Cyan }

# ---------- 1) VS Code portatil ----------
Step '1/4' 'VS Code (portatil)'
$codeDir = Join-Path $env:LOCALAPPDATA 'Programs\VSCodePortable'
$codeExe = Join-Path $codeDir 'Code.exe'
if (-not (Test-Path $codeExe)) {
    $zip = Join-Path $env:TEMP 'vscode.zip'
    Write-Host '   baixando...'
    Invoke-WebRequest 'https://update.code.visualstudio.com/latest/win32-x64-archive/stable' -OutFile $zip -UseBasicParsing
    Write-Host '   extraindo...'
    Expand-Archive -Path $zip -DestinationPath $codeDir -Force
    Remove-Item $zip -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $codeDir 'data') | Out-Null  # modo portatil
}
Write-Host "   OK -> $codeExe" -ForegroundColor Green

# ---------- 2) Repo ----------
Step '2/4' 'Repositorio'
$repoZip = Join-Path $env:TEMP 'repo.zip'
$tmp     = Join-Path $env:TEMP 'repo_extract'
$url     = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"
Write-Host "   baixando $url"
Invoke-WebRequest $url -OutFile $repoZip -UseBasicParsing
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $repoZip -DestinationPath $tmp -Force
$inner = Get-ChildItem $tmp | Select-Object -First 1   # github extrai em REPO-branch/
Copy-Item (Join-Path $inner.FullName '*') $Dev -Recurse -Force
Remove-Item $repoZip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "   OK -> $Dev" -ForegroundColor Green

# ---------- 3) .env ----------
Step '3/4' 'Configuracao (.env)'
$envPath = Join-Path $Dev '.env'
if ((Test-Path $envPath) -and ((Get-Content $envPath -Raw) -match 'WORKER_TOKEN=\S')) {
    Write-Host "   .env ja existe e tem token - mantendo. (apague o .env pra recriar)" -ForegroundColor Yellow
} else {
    Write-Host "   Preencha os tokens (do painel do Cloudflare):"
    $base = Read-Host "   BASE_URL [$DefaultUrl]"; if (-not $base) { $base = $DefaultUrl }
    $wtok = Read-Host "   WORKER_TOKEN"
    $ctok = Read-Host "   CLIENT_TOKEN"
    @"
BASE_URL=$base
WORKER_TOKEN=$wtok
CLIENT_TOKEN=$ctok
POLL_SECONDS=5
SCRIPT=
LOG_JSONL=
"@ | Set-Content -Path $envPath -Encoding UTF8
    Write-Host "   .env criado" -ForegroundColor Green
}

# ---------- 4) Abrir VS Code + subir worker ----------
Step '4/4' 'Abrindo VS Code e subindo o worker'
Start-Process $codeExe -ArgumentList $Dev

$hasTok = (Test-Path $envPath) -and ((Get-Content $envPath -Raw) -match 'WORKER_TOKEN=\S')
if ($hasTok) {
    Start-Process powershell -WindowStyle Minimized -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Dev 'worker.ps1')
    Write-Host "   worker iniciado (janela minimizada, girando o loop)" -ForegroundColor Green
} else {
    Write-Host "   sem WORKER_TOKEN - worker NAO iniciado. Preencha o .env e rode worker.ps1." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "PRONTO. Ambiente de pe." -ForegroundColor Green
Write-Host "Lembre: abra o modulo CCE/MDFe no Senior para os jobs poderem rodar." -ForegroundColor Yellow
