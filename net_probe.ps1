# net_probe.ps1 - testa o que a sessao TSplus alcanca PRA FORA (saida).
# Decide se da pra usar o modelo de fila por endpoint hospedado (polling HTTPS).
# Zero-install.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Line($label, $ok, $detail) {
    $tag = if ($ok) { "OK " } else { "FALHA" }
    $col = if ($ok) { "Green" } else { "Red" }
    Write-Host ("  [{0}] {1,-26} {2}" -f $tag, $label, $detail) -ForegroundColor $col
}

Write-Host "`n== Conectividade de saida da sessao ==`n" -ForegroundColor Cyan

# 1) DNS
try {
    $ips = [System.Net.Dns]::GetHostAddresses("api.github.com") | Select-Object -First 1
    Line "DNS resolve" $true ("api.github.com -> {0}" -f $ips)
} catch { Line "DNS resolve" $false $_.Exception.Message }

# 2) Proxy do sistema?
try {
    $proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy("https://api.github.com")
    if ($proxy -and $proxy.AbsoluteUri -notlike "*api.github.com*") {
        Line "Proxy do sistema" $true ("usa proxy: {0}" -f $proxy.AbsoluteUri)
    } else {
        Line "Proxy do sistema" $true "sem proxy (conexao direta)"
    }
} catch { Line "Proxy do sistema" $false $_.Exception.Message }

# 3) TCP 443 em alvos comuns
foreach ($h in "api.github.com", "raw.githubusercontent.com", "httpbin.org") {
    try {
        $r = Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue
        Line "TCP 443 $h" $r.TcpTestSucceeded ($(if ($r.TcpTestSucceeded) { "conectou" } else { "bloqueado" }))
    } catch { Line "TCP 443 $h" $false $_.Exception.Message }
}

# 4) HTTPS GET real (o que o worker vai fazer)
try {
    $resp = Invoke-WebRequest -Uri "https://httpbin.org/get" -UseBasicParsing -TimeoutSec 15
    Line "HTTPS GET" ($resp.StatusCode -eq 200) ("status {0}" -f $resp.StatusCode)
} catch { Line "HTTPS GET" $false $_.Exception.Message }

# 5) HTTPS POST real (o worker vai postar resultado)
try {
    $body = @{ teste = "ping"; origem = "tsplus" } | ConvertTo-Json
    $resp = Invoke-WebRequest -Uri "https://httpbin.org/post" -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 15
    Line "HTTPS POST" ($resp.StatusCode -eq 200) ("status {0}" -f $resp.StatusCode)
} catch { Line "HTTPS POST" $false $_.Exception.Message }

Write-Host "`n== Resumo ==" -ForegroundColor Cyan
Write-Host "  Se HTTPS GET e POST derem OK -> modelo de fila hospedada funciona (worker faz polling)."
Write-Host "  Se so o proxy aparecer -> funciona, mas o worker precisa apontar pro proxy."
Write-Host "  Se tudo falhar -> sem internet na sessao; vamos por drive de rede ou banco.`n"
