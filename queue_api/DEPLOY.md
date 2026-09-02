# Fila de RPA — deploy e uso

## A) Subir a API (Cloudflare Worker) — ~5 min, sem CLI

1. Conta grátis em https://dash.cloudflare.com → **Workers & Pages** → **Create** → **Create Worker**.
2. **Edit code** → apague o exemplo, cole o conteúdo de `worker.js` → **Deploy**.
   Vai gerar uma URL tipo `https://sua-fila.SEU-SUBDOMINIO.workers.dev`.
3. Criar o storage: **Workers & Pages → KV → Create namespace** (ex.: `rpa_jobs`).
4. No Worker → **Settings → Bindings → Add → KV namespace**:
   - Variable name: `JOBS`  → namespace: `rpa_jobs`.
5. No Worker → **Settings → Variables and Secrets → Add secret** (2 secrets):
   - `CLIENT_TOKEN` = uma senha forte (quem cria jobs usa esta)
   - `WORKER_TOKEN` = outra senha forte (o robô na sessão usa esta)
6. **Deploy** de novo pra aplicar bindings.

Teste: `GET https://.../health` deve responder `{"ok":true}`.

## B) Ligar o worker na sessão TSplus

Dentro da sessão:
```
powershell -ExecutionPolicy Bypass -File worker.ps1 `
    -BaseUrl "https://sua-fila.SEU-SUBDOMINIO.workers.dev" `
    -Token   "<WORKER_TOKEN>"
```
Ele fica em loop puxando jobs e rodando o `encerra_mdfe.ps1` (modo validação).
Deixe rodando numa sessão **desconectada** (não deslogada) para operar sem UI.

## C) Disparar jobs (de qualquer lugar)

Criar um job (PowerShell):
```powershell
$H = @{ Authorization = "Bearer <CLIENT_TOKEN>" }
$b = @{ empresa = "1"; mdfe = "17854" } | ConvertTo-Json
Invoke-RestMethod -Uri "https://.../jobs" -Method POST -Headers $H -Body $b -ContentType "application/json"
# -> { id: "...", status: "pending" }
```

Criar via curl / n8n / outro sistema:
```
curl -X POST https://.../jobs \
  -H "Authorization: Bearer <CLIENT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"empresa":"1","mdfe":"17854"}'
```

Consultar o resultado:
```powershell
Invoke-RestMethod -Uri "https://.../jobs/<id>" -Headers $H
# status: pending -> running -> done | error ;  detail traz "cancelado(validacao)" etc.
```

## Notas de segurança (já embutidas)
- Dois tokens separados (cliente x worker).
- **Idempotência**: mesmo empresa|mdfe|mode não roda 2x (use `force:true` pra reprocessar).
- **v1 = só validação**. `mode:"execute"` é recusado pelo worker — encerramento fiscal
  real segue manual/interativo até desenharmos autorização não-interativa segura.
- Toda execução continua gravando o `encerra_mdfe_log.jsonl` (auditoria local).
