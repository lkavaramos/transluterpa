# worker.ps1 - roda DENTRO da sessao TSplus. Puxa jobs da fila (Cloudflare Worker),
# executa o encerra_mdfe.ps1 e devolve o resultado. So faz SAIDA HTTPS (sem porta aberta).
#
# v1 SEGURANCA: o worker so roda modo VALIDACAO (cancela no fim). Encerramento
# real (mode=execute) fica manual/interativo ate desenharmos uma autorizacao
# nao-interativa segura. Jobs execute sao reportados como "bloqueado".
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File worker.ps1 `
#       -BaseUrl "https://SEU-WORKER.workers.dev" -Token "WORKER_TOKEN"

param(
    [string]$BaseUrl,
    [string]$Token,
    [int]$PollSeconds = 5,
    [string]$Script,
    [string]$LogJsonl,
    [string]$EnvFile,
    [switch]$AllowExecute   # reservado; ainda NAO habilita execute de verdade
)

# ---- carrega .env (KEY=VALUE) ao lado do script; param sempre vence o .env ----
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot ".env" }
function Load-DotEnv($path) {
    $h = @{}
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $i = $t.IndexOf('=')
            if ($i -lt 1) { continue }
            $k = $t.Substring(0, $i).Trim()
            $v = $t.Substring($i + 1).Trim()
            if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            $h[$k] = $v
        }
    }
    return $h
}
$cfg = Load-DotEnv $EnvFile

# caminho relativo -> resolve ao lado do worker.ps1; absoluto -> usa como veio
function Resolve-Local($p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $PSScriptRoot $p)
}

if (-not $PSBoundParameters.ContainsKey('BaseUrl')     -and $cfg.BASE_URL)     { $BaseUrl = $cfg.BASE_URL }
if (-not $PSBoundParameters.ContainsKey('Token')       -and $cfg.WORKER_TOKEN) { $Token = $cfg.WORKER_TOKEN }
if (-not $PSBoundParameters.ContainsKey('PollSeconds') -and $cfg.POLL_SECONDS) { $PollSeconds = [int]$cfg.POLL_SECONDS }

$scriptRaw = if ($Script)   { $Script }   elseif ($cfg.SCRIPT)    { $cfg.SCRIPT }    else { 'encerra_mdfe.ps1' }
$logRaw    = if ($LogJsonl) { $LogJsonl } elseif ($cfg.LOG_JSONL) { $cfg.LOG_JSONL } else { 'encerra_mdfe_log.jsonl' }
$Script   = Resolve-Local $scriptRaw
$LogJsonl = Resolve-Local $logRaw

if (-not $BaseUrl -or -not $Token) {
    Write-Host "Faltou BASE_URL/WORKER_TOKEN. Preencha o .env ou passe -BaseUrl/-Token." -ForegroundColor Red
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$BaseUrl = $BaseUrl.TrimEnd('/')
$H = @{ Authorization = "Bearer $Token" }

function Report($id, $status, $detail) {
    $body = @{ status = $status; result = $detail; detail = $detail } | ConvertTo-Json
    try {
        Invoke-WebRequest -Uri "$BaseUrl/jobs/$id/result" -Method POST -Headers $H -Body $body `
            -ContentType "application/json" -UseBasicParsing -TimeoutSec 20 | Out-Null
    } catch {
        Write-Host ("  ! falha ao reportar {0}: {1}" -f $id, $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ("worker on -> {0}  (poll {1}s)" -f $BaseUrl, $PollSeconds) -ForegroundColor Green

while ($true) {
    try {
        $r = Invoke-WebRequest -Uri "$BaseUrl/next" -Headers $H -UseBasicParsing -TimeoutSec 20
        if ($r.StatusCode -eq 204 -or -not $r.Content) { Start-Sleep -Seconds $PollSeconds; continue }

        $job = $r.Content | ConvertFrom-Json
        Write-Host ("[job {0}] empresa={1} mdfe={2} mode={3}" -f $job.id, $job.empresa, $job.mdfe, $job.mode) -ForegroundColor Cyan

        if ($job.mode -eq "execute" -and -not $AllowExecute) {
            Report $job.id "error" "execute bloqueado no worker v1 (encerramento real e manual)"
            Write-Host "  -> bloqueado (execute)" -ForegroundColor Yellow
            continue
        }

        # CSV temporario de 1 linha
        $tmp = [System.IO.Path]::GetTempFileName()
        "empresa;mdfe" | Set-Content -Path $tmp -Encoding UTF8
        ("{0};{1}" -f $job.empresa, $job.mdfe) | Add-Content -Path $tmp -Encoding UTF8

        # posicao do log antes de rodar
        $before = if (Test-Path $LogJsonl) { @(Get-Content $LogJsonl).Count } else { 0 }

        # roda o RPA numa janela MINIMIZADA: tem console real (igual a rodar manual,
        # que funciona), mas nao rouba foco. Hidden quebrava as operacoes de tela do dashboard.
        $child = Start-Process powershell -WindowStyle Minimized -Wait -PassThru -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-File", $Script, "-Csv", $tmp, "-Background"
        )
        $exit = $child.ExitCode
        Remove-Item $tmp -ErrorAction SilentlyContinue

        # casa a linha do log pelo MDFE deste job (evita ler resultado de job antigo)
        $status = "error"; $detail = "sem resultado (exit=$exit)"
        if (Test-Path $LogJsonl) {
            $lines = @(Get-Content $LogJsonl)
            if ($lines.Count -gt $before) {
                $novas = $lines[$before..($lines.Count - 1)]
                $match = $novas | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
                    Where-Object { $_ -and "$($_.mdfe)" -eq "$($job.mdfe)" } | Select-Object -Last 1
                if ($match) {
                    $detail = "$($match.status)"
                    $status = if ($detail -like "erro:*") { "error" } else { "done" }
                } else {
                    $detail = "rodou mas sem linha p/ mdfe $($job.mdfe) (exit=$exit)"
                }
            } else {
                $detail = "nenhuma linha nova no log; RPA nao rodou (exit=$exit)"
            }
        }

        Report $job.id $status $detail
        $col = if ($status -eq "error") { "Red" } else { "Green" }
        Write-Host ("  -> {0}: {1}" -f $status, $detail) -ForegroundColor $col
    } catch {
        Write-Host ("worker erro: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Start-Sleep -Seconds $PollSeconds
    }
}
