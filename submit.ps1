# submit.ps1 - cria job(s) na fila. Le BASE_URL/CLIENT_TOKEN do .env.
#
# Uso:
#   .\submit.ps1 -Empresa 1 -Mdfe 17854
#   .\submit.ps1 -Empresa 1 -Mdfe 17854 -Mode execute      (encerramento real; worker v1 ainda bloqueia)
#   .\submit.ps1 -Csv lista.csv                              (varias linhas empresa;mdfe)
#   .\submit.ps1 -Status <id>                                (consulta um job)

param(
    [string]$Empresa,
    [string]$Mdfe,
    [ValidateSet('validate', 'execute')][string]$Mode = 'validate',
    [switch]$Force,
    [string]$Csv,
    [string]$Status,
    [string]$EnvFile
)

if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot ".env" }
function Load-DotEnv($path) {
    $h = @{}
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            $t = $line.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
            $i = $t.IndexOf('='); if ($i -lt 1) { continue }
            $k = $t.Substring(0, $i).Trim(); $v = $t.Substring($i + 1).Trim()
            if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
            $h[$k] = $v
        }
    }
    return $h
}
$cfg = Load-DotEnv $EnvFile
$Base = $cfg.BASE_URL; $Tok = $cfg.CLIENT_TOKEN
if (-not $Base -or -not $Tok) { Write-Host "Preencha BASE_URL e CLIENT_TOKEN no .env" -ForegroundColor Red; exit 1 }
$Base = $Base.TrimEnd('/')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$H = @{ Authorization = "Bearer $Tok" }

function New-Job($empresa, $mdfe, $mode, $force) {
    $body = @{ empresa = "$empresa"; mdfe = "$mdfe"; mode = $mode; force = [bool]$force } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$Base/jobs" -Method POST -Headers $H -Body $body -ContentType 'application/json'
    Write-Host ("job {0}  empresa={1} mdfe={2} mode={3}  -> {4}" -f $r.id, $empresa, $mdfe, $mode, $r.status) -ForegroundColor Green
    return $r
}

if ($Status) {
    Invoke-RestMethod -Uri "$Base/jobs/$Status" -Headers $H | Format-List
    return
}

if ($Csv) {
    $itens = @(Import-Csv -Path $Csv -Delimiter ';')
    Write-Host ("Enviando {0} itens..." -f $itens.Count) -ForegroundColor Cyan
    foreach ($it in $itens) { New-Job $it.empresa $it.mdfe $Mode $Force | Out-Null }
    return
}

if ($Empresa -and $Mdfe) { New-Job $Empresa $Mdfe $Mode $Force | Out-Null; return }

Write-Host "Informe -Empresa e -Mdfe, ou -Csv arquivo.csv, ou -Status <id>." -ForegroundColor Yellow
