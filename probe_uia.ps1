# Probe de viabilidade UIA — RODAR DENTRO DA SESSAO TSplus.
# NAO instala nada. So LE a arvore de acessibilidade que o Windows ja expoe.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File probe_uia.ps1
#       -> lista as janelas de topo (pega um trecho do titulo do app)
#   powershell -ExecutionPolicy Bypass -File probe_uia.ps1 "trecho do titulo"
#       -> despeja a arvore de controles dessa janela
#
# O que olhar na saida: se aparece AutomationId e Name uteis por controle,
# o robo vai ser limpo. Se tudo vira "pane"/"custom" sem id nem nome, o app
# expoe UIA pobre e a gente muda de estrategia ANTES de investir.

param(
    [string]$Titulo = "",
    [int]$MaxDepth = 8
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE   = [System.Windows.Automation.AutomationElement]
$root = $AE::RootElement

function Ct($el) {
    try { ($el.Current.ControlType.ProgrammaticName -replace 'ControlType\.','') }
    catch { "?" }
}

if ([string]::IsNullOrWhiteSpace($Titulo)) {
    Write-Host "=== Janelas de topo ===" -ForegroundColor Cyan
    $wins = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($w in $wins) {
        $n = $w.Current.Name
        if ($n) {
            "{0,-18} [{1,-25}] {2}" -f (Ct $w), $w.Current.ClassName, $n
        }
    }
    Write-Host "`nAgora: powershell -ExecutionPolicy Bypass -File probe_uia.ps1 `"trecho do titulo`"" -ForegroundColor Yellow
    return
}

# acha a janela pelo trecho do titulo
$cond = New-Object System.Windows.Automation.PropertyCondition(
    $AE::NameProperty, $Titulo)  # match exato falha; usamos varredura manual:
$wins = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition)
$alvo = $wins | Where-Object { $_.Current.Name -like "*$Titulo*" } | Select-Object -First 1

if (-not $alvo) { Write-Host "Janela nao encontrada: *$Titulo*" -ForegroundColor Red; return }

Write-Host ("Janela: '{0}'  (class {1})`n" -f $alvo.Current.Name, $alvo.Current.ClassName) -ForegroundColor Green

$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
function Walk($el, $depth) {
    if ($depth -gt $MaxDepth) { return }
    $c   = $el.Current
    $ind = "  " * $depth
    $id  = if ($c.AutomationId) { $c.AutomationId } else { "-" }
    $nm  = if ($c.Name)         { $c.Name }         else { "" }
    "{0}{1,-16} id={2,-22} name='{3}'" -f $ind, (Ct $el), $id, $nm
    $child = $walker.GetFirstChild($el)
    while ($child) {
        Walk $child ($depth + 1)
        $child = $walker.GetNextSibling($child)
    }
}
Walk $alvo 0
