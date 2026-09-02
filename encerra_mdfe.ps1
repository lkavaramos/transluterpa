# ==========================================================================
# encerra_mdfe.ps1  —  Harness de ENCERRAMENTO de MDFe (CCE / Delphi) via win32
# RODAR DENTRO DA SESSAO. Zero-install (so P/Invoke).
#
# Fluxo por item (empresa;mdfe):
#   Filtros -> empresa + Nr MDF-e ini/fim -> Filtrar -> duplo-clique na linha
#   -> aba Dados -> botao Encerramento -> caixa "Confirmacao!" -> clica NAO
#
# Modos:
#   (padrao)   VALIDACAO: clica "Nao" na confirmacao (nao encerra nada).
#   -Diag      So aponta o mouse em cada controle achado e imprime. NAO clica.
#   -Execute   PRODUCAO: clica "Sim" (exige confirmacao humana por item).
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File encerra_mdfe.ps1 -Diag
#   powershell -ExecutionPolicy Bypass -File encerra_mdfe.ps1 -Csv lista.csv
#   (lista.csv: cabecalho "empresa;mdfe" e uma linha por item)
# ==========================================================================
param(
    [string]$Csv,
    [switch]$Diag,
    [switch]$Execute,
    [switch]$Background,   # usa PostMessage (roda em 2o plano, nao rouba o mouse)
    [int]$Pause = 800
)

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class Win {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr MsgLen(IntPtr h, uint m, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr MsgGet(IntPtr h, uint m, IntPtr wp, StringBuilder lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr MsgSet(IntPtr h, uint m, IntPtr wp, string lp);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, IntPtr e);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr[] Top(uint pid){
    var list = new List<IntPtr>();
    EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h, out p); if(p==pid) list.Add(h); return true; }, IntPtr.Zero);
    return list.ToArray();
  }
  public static string Text(IntPtr h){
    int len = (int)MsgLen(h, 0x000E, IntPtr.Zero, IntPtr.Zero);          // WM_GETTEXTLENGTH
    if(len<=0) return "";
    var sb = new StringBuilder(len+1);
    MsgGet(h, 0x000D, (IntPtr)(len+1), sb);                              // WM_GETTEXT
    return sb.ToString();
  }
  public static void SetText(IntPtr h, string s){ MsgSet(h, 0x000C, IntPtr.Zero, s); } // WM_SETTEXT
}
"@

$MOUSE_DOWN = 0x02; $MOUSE_UP = 0x04
$VK_TAB = 0x09; $VK_CONTROL = 0x11; $KEYUP = 0x0002

function Get-CCE {
    Get-Process | Where-Object { $_.MainWindowTitle -like "*MDFe*" -and $_.MainWindowTitle -like "*Movimenta*" } | Select-Object -First 1
}

# classes onde REALMENTE preciso do texto (botoes/abas/dialogos). WM_GETTEXT
# so nelas -> corta centenas de SendMessage cross-process por scan.
$TEXT_CLASSES = @("TBitBtn","TButton","TTabSheet","TfoMensagemSistema","TfoMenuGeralCCE")

# devolve lista plana de controles do processo: Hwnd/Class/Text/X/Y/W/H/Vis
function Get-Controls($procId) {
    $out = New-Object System.Collections.ArrayList
    function Walk($h) {
        $c = New-Object System.Text.StringBuilder 256
        [Win]::GetClassName($h, $c, 256) | Out-Null
        $cls = $c.ToString()
        $txt = if ($TEXT_CLASSES -contains $cls) { [Win]::Text($h) } else { "" }
        $r = New-Object Win+RECT
        [Win]::GetWindowRect($h, [ref]$r) | Out-Null
        [void]$out.Add([pscustomobject]@{
            Hwnd = $h; Class = $cls; Text = $txt
            X = $r.L; Y = $r.T; W = ($r.R - $r.L); H = ($r.B - $r.T)
            Vis = [Win]::IsWindowVisible($h)
        })
        $ch = [Win]::GetWindow($h, 5)   # GW_CHILD
        while ($ch -ne [IntPtr]::Zero) { Walk $ch; $ch = [Win]::GetWindow($ch, 2) }  # GW_HWNDNEXT
    }
    foreach ($t in [Win]::Top([uint32]$procId)) { Walk $t }
    return $out
}

# "ocupado?" = janela AnyDAC visivel. Checagem barata (so classe, sem WM_GETTEXT).
function Is-Busy($procId) {
    foreach ($h in [Win]::Top([uint32]$procId)) {
        $c = New-Object System.Text.StringBuilder 64
        [Win]::GetClassName($h, $c, 64) | Out-Null
        if ($c.ToString() -eq "TfrmADGUIxFormsAsyncExecute" -and [Win]::IsWindowVisible($h)) { return $true }
    }
    return $false
}
# espera o app terminar o processamento (janela ocupado sumir), com timeout
function Wait-Idle($procId, $timeoutMs = 15000, $appearMs = 200) {
    $t = 0
    while ($t -lt $appearMs)    { if (Is-Busy $procId) { break }; Start-Sleep -Milliseconds 30; $t += 30 }  # deixa aparecer
    $t = 0
    while ((Is-Busy $procId) -and $t -lt $timeoutMs) { Start-Sleep -Milliseconds 50; $t += 50 }            # espera sumir
}

function ByText($ctrls, $class, $text) {
    $ctrls | Where-Object { $_.Class -eq $class -and $_.Text -eq $text -and $_.Vis } | Select-Object -First 1
}
# casa por curinga (evita problema de acento: "&Nao" vs "&Não")
function ByLike($ctrls, $class, $pattern) {
    $ctrls | Where-Object { $_.Class -eq $class -and $_.Text -like $pattern -and $_.Vis } | Select-Object -First 1
}
# campo por posicao RELATIVA a janela principal (offset calibrado), tolerancia em px
function ByOffset($ctrls, $form, $class, $ox, $oy, $tol = 10) {
    $ctrls | Where-Object {
        $_.Class -eq $class -and $_.Vis -and
        [math]::Abs(($_.X - $form.X) - $ox) -le $tol -and
        [math]::Abs(($_.Y - $form.Y) - $oy) -le $tol
    } | Select-Object -First 1
}

# msgs
$BM_CLICK = 0x00F5; $WM_LBTNDOWN = 0x0201; $WM_LBTNUP = 0x0202; $WM_LBTNDBLCLK = 0x0203
$WM_KEYDOWN = 0x0100; $WM_KEYUP = 0x0101; $MK_LBUTTON = 1; $VK_RETURN = 0x0D

function LParamXY($x, $y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }

function Click-Ctl($c) {
    if ($Background) {
        [Win]::PostMessage($c.Hwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        return
    }
    $x = $c.X + [int]($c.W / 2); $y = $c.Y + [int]($c.H / 2)
    [Win]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 120
    [Win]::mouse_event($MOUSE_DOWN,0,0,0,[IntPtr]::Zero); [Win]::mouse_event($MOUSE_UP,0,0,0,[IntPtr]::Zero)
}
function Point-Ctl($c) {  # so aponta (modo Diag)
    $x = $c.X + [int]($c.W / 2); $y = $c.Y + [int]($c.H / 2)
    [Win]::SetCursorPos($x, $y) | Out-Null
}
# duplo-clique na 1a linha da grade: por mensagem (bg) ou mouse real
function DblClick-Row($g) {
    $cx = 40; $cy = 32   # offset dentro da area da grade (1a linha de dados)
    if ($Background) {
        $lp = LParamXY $cx $cy
        [Win]::PostMessage($g.Hwnd, $WM_LBTNDOWN,   [IntPtr]$MK_LBUTTON, $lp) | Out-Null
        [Win]::PostMessage($g.Hwnd, $WM_LBTNUP,     [IntPtr]0,           $lp) | Out-Null
        [Win]::PostMessage($g.Hwnd, $WM_LBTNDBLCLK, [IntPtr]$MK_LBUTTON, $lp) | Out-Null
        [Win]::PostMessage($g.Hwnd, $WM_LBTNUP,     [IntPtr]0,           $lp) | Out-Null
        return
    }
    $x = $g.X + $cx; $y = $g.Y + $cy
    [Win]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 120
    [Win]::mouse_event($MOUSE_DOWN,0,0,0,[IntPtr]::Zero); [Win]::mouse_event($MOUSE_UP,0,0,0,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Win]::mouse_event($MOUSE_DOWN,0,0,0,[IntPtr]::Zero); [Win]::mouse_event($MOUSE_UP,0,0,0,[IntPtr]::Zero)
}
# confirma o lookup da empresa (Enter por msg no bg; clique+Tab real caso contrario)
function Commit-Empresa($c) {
    if ($Background) {
        [Win]::PostMessage($c.Hwnd, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero) | Out-Null
        [Win]::PostMessage($c.Hwnd, $WM_KEYUP,   [IntPtr]$VK_RETURN, [IntPtr]::Zero) | Out-Null
        return
    }
    Click-Ctl $c
    [Win]::keybd_event($VK_TAB,0,0,[IntPtr]::Zero); [Win]::keybd_event($VK_TAB,0,$KEYUP,[IntPtr]::Zero)
}
function Send-CtrlTab {
    [Win]::keybd_event($VK_CONTROL,0,0,[IntPtr]::Zero)
    [Win]::keybd_event($VK_TAB,0,0,[IntPtr]::Zero)
    [Win]::keybd_event($VK_TAB,0,$KEYUP,[IntPtr]::Zero)
    [Win]::keybd_event($VK_CONTROL,0,$KEYUP,[IntPtr]::Zero)
}

# offsets calibrados (relativos ao canto da janela TfoMenuGeralCCE @ -8,-8)
$OFF = @{
    Empresa  = @(138, 147)   # TEdit interno do TfoFraConsulta
    MdfeIni  = @(138, 194)   # TEdit Nr MDF-e Inicial
    MdfeFim  = @(312, 193)   # TEdit Nr MDF-e Final
}

function Resolve-Form($ctrls) { $ctrls | Where-Object { $_.Class -eq "TfoMenuGeralCCE" } | Select-Object -First 1 }

# qual aba principal esta ativa? (a TTabSheet ativa fica visivel)
function Active-Tab($ctrls) {
    if ($ctrls | Where-Object { $_.Class -eq "TTabSheet" -and $_.Text -like "*Filtros*" -and $_.Vis }) { return "Filtros" }
    if ($ctrls | Where-Object { $_.Class -eq "TTabSheet" -and $_.Text -like "*Dados*"   -and $_.Vis }) { return "Dados" }
    return "?"
}

# clica na faixa de abas (fallback quando Ctrl+Tab nao pega o foco)
function Click-TabStrip($form, $xoff) {
    $x = $form.X + $xoff; $y = $form.Y + 129   # faixa de abas do TPageControl principal
    [Win]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 100
    [Win]::mouse_event($MOUSE_DOWN,0,0,0,[IntPtr]::Zero); [Win]::mouse_event($MOUSE_UP,0,0,0,[IntPtr]::Zero)
}

# clica botao de dialogo SEMPRE por mensagem (deterministico, sem foco/cursor)
function Click-Btn-Msg($btn) {
    if ($btn) { [Win]::PostMessage($btn.Hwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
}

# fecha qualquer caixa modal presa com botao SEGURO (Nao/Cancelar/Fechar/OK).
# NUNCA clica Sim. Roda em loop ate nao sobrar dialogo. Auto-cura do loop.
function Close-Modals($proc, $max = 6) {
    for ($i = 0; $i -lt $max; $i++) {
        $c = Get-Controls $proc.Id
        $dlg = $c | Where-Object { $_.Class -eq "TfoMensagemSistema" -and $_.Vis } | Select-Object -First 1
        if (-not $dlg) { return $true }
        $btn = ByLike $c "TButton" "&N*"                       # Nao
        if (-not $btn) { $btn = ByLike $c "TButton" "Cancel*" }
        if (-not $btn) { $btn = ByLike $c "TButton" "Fechar*" }
        if (-not $btn) { $btn = ByLike $c "TButton" "OK*" }
        if (-not $btn) { $btn = ByLike $c "TButton" "&O*" }
        if (-not $btn) { return $false }                        # so tem Sim? nao mexo (seguro)
        Click-Btn-Msg $btn
        Wait-Idle $proc.Id
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# identifica a tela atual e SEMPRE deixa a aba Filtros ativa. Devolve a tela inicial.
function Go-Filtros($proc) {
    Close-Modals $proc | Out-Null      # limpa caixa presa antes de qualquer coisa
    $c = Get-Controls $proc.Id
    $form = Resolve-Form $c
    if (-not $form) { throw "janela do CCE/MDFe nao encontrada" }
    if (-not $Background) { [Win]::SetForegroundWindow($form.Hwnd) | Out-Null; Start-Sleep -Milliseconds 120 }

    $start = Active-Tab $c
    if ($start -eq "Filtros") { return $start }

    # metodo robusto: TCM_SETCURFOCUS no TPageControl principal (maior visivel).
    # Delphi troca a pagina ao receber essa msg nativa; testo cada indice.
    $pc = $c | Where-Object { $_.Class -eq "TPageControl" -and $_.Vis } | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
    if ($pc) {
        $cnt = [int][Win]::MsgLen($pc.Hwnd, 0x1304, [IntPtr]::Zero, [IntPtr]::Zero)   # TCM_GETITEMCOUNT
        if ($cnt -le 0 -or $cnt -gt 12) { $cnt = 6 }
        for ($idx = 0; $idx -lt $cnt; $idx++) {
            [Win]::MsgLen($pc.Hwnd, 0x1330, [IntPtr]$idx, [IntPtr]::Zero) | Out-Null   # TCM_SETCURFOCUS
            Start-Sleep -Milliseconds 180
            if ((Active-Tab (Get-Controls $proc.Id)) -eq "Filtros") { return $start }
        }
    }
    # fallback 1: Ctrl+Tab
    for ($i = 0; $i -lt 3; $i++) {
        Send-CtrlTab; Start-Sleep -Milliseconds 300
        if ((Active-Tab (Get-Controls $proc.Id)) -eq "Filtros") { return $start }
    }
    # fallback 2: clica a faixa de abas em posicoes candidatas
    foreach ($xo in 30, 90, 150, 210, 270) {
        Click-TabStrip $form $xo; Start-Sleep -Milliseconds 250
        if ((Active-Tab (Get-Controls $proc.Id)) -eq "Filtros") { return $start }
    }
    throw "nao consegui ativar a aba Filtros (tela inicial detectada: $start)"
}

# ---------- painel fixo (in-place, atualiza no lugar) ----------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# glifos por codigo (nao dependem do encoding do arquivo)
$script:G_FULL  = [char]0x2501                                   # barra cheia
$script:G_EMPTY = [char]0x2500                                   # barra vazia
$script:G_CHECK = [char]0x2713                                   # check
$script:G_SPIN  = @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F | ForEach-Object { [char]$_ })
$script:BarW = 40
$script:Total = 1; $script:Done = 0; $script:Ok = 0; $script:Err = 0
$script:Step = 0; $script:Action = ""; $script:CurEmp = ""; $script:CurMdfe = ""
$script:SpinI = 0; $script:AnchorY = $null; $script:PanelLines = 5
$script:Modo = ""; $script:swAll = $null
# etapas e PESO (duracao tipica) -> barra anda proporcional ao tempo (linear)
$script:StepW    = @(2.0, 1.4, 0.7, 0.1, 1.9, 0.1, 1.7, 0.7)
$script:StepsPer = $script:StepW.Count
$script:StepWTot = ($script:StepW | Measure-Object -Sum).Sum

function Fmt-MMSS($ts) { "{0:mm\:ss}" -f $ts }

# fracao concluida DENTRO do item, ponderada por duracao das etapas
function Item-Frac {
    $k = [math]::Min($script:Step, $script:StepsPer)
    if ($k -le 0) { return 0.0 }
    $s = 0.0; for ($z = 0; $z -lt $k; $z++) { $s += $script:StepW[$z] }
    return $s / $script:StepWTot
}

function Panel-Init {
    Clear-Host
    Write-Host ""
    Write-Host ("  ENCERRAMENTO MDFe     {0}     {1} itens" -f $script:Modo, $script:Total) -ForegroundColor Cyan
    Write-Host ""
    try { $script:AnchorY = [Console]::CursorTop } catch { $script:AnchorY = $null }
    1..$script:PanelLines | ForEach-Object { Write-Host "" }   # reserva o espaco do painel
}

function L($label, $value, $col) {
    Write-Host ("   {0,-8}" -f $label) -NoNewline -ForegroundColor DarkGray
    Write-Host ($value.PadRight(58)) -ForegroundColor $col
}

function Redraw {
    param([switch]$Final)
    $frac = ($script:Done + (Item-Frac)) / [math]::Max($script:Total, 1)
    if ($Final) { $frac = 1 }
    if ($frac -gt 1) { $frac = 1 } elseif ($frac -lt 0) { $frac = 0 }
    $fill = [int][math]::Round($script:BarW * $frac)
    $pct  = [int]($frac * 100)
    $barCol = if ($script:Err -gt 0) { "Red" } elseif ($Final) { "Green" } else { "Cyan" }
    if ($Final) { $spin = $script:G_CHECK } else { $spin = $script:G_SPIN[$script:SpinI % $script:G_SPIN.Count]; $script:SpinI++ }

    $el  = if ($script:swAll) { Fmt-MMSS $script:swAll.Elapsed } else { "00:00" }
    $avg = if ($script:Done -gt 0) { $script:swAll.Elapsed.TotalSeconds / $script:Done } else { 0 }
    $eta = if ($script:Done -gt 0) { Fmt-MMSS ([TimeSpan]::FromSeconds([math]::Max(0, $avg * ($script:Total - $script:Done)))) } else { "--:--" }
    $cur = if ($Final) { $script:Total } else { [math]::Min($script:Done + 1, $script:Total) }
    $stCol = if ($script:Err -gt 0) { "Yellow" } else { "Green" }

    if ($null -ne $script:AnchorY) { try { [Console]::SetCursorPosition(0, $script:AnchorY) } catch {} }

    # linha da barra
    Write-Host ("   {0}  " -f $spin) -NoNewline -ForegroundColor $barCol
    Write-Host ($script:G_FULL.ToString()  * $fill) -NoNewline -ForegroundColor $barCol
    Write-Host ($script:G_EMPTY.ToString() * ($script:BarW - $fill)) -NoNewline -ForegroundColor DarkGray
    Write-Host (("  {0,3}%" -f $pct).PadRight(8)) -ForegroundColor White
    # infos
    L "Item"   ("{0}/{1}   empresa {2}  mdfe {3}" -f $cur, $script:Total, $script:CurEmp, $script:CurMdfe) "Gray"
    L "Etapa"  ("{0,-18} {1}/{2}" -f $script:Action, [math]::Min($script:Step, $script:StepsPer), $script:StepsPer) "White"
    L "Tempo"  ("{0}   ETA {1}   {2:n1}s/item" -f $el, $eta, $avg) "DarkGray"
    L "Status" ("{0} ok    {1} erro" -f $script:Ok, $script:Err) $stCol
    try { $Host.UI.RawUI.WindowTitle = "MDFe $($script:Done)/$($script:Total)  $pct%" } catch {}
}
# cada passo avanca a barra e atualiza a etapa exibida
function StepStart($m) { $script:Step++; $script:Action = $m; Redraw }
function StepEnd($extra = "") { }

function Processa-Item($proc, $empresa, $mdfe) {
    $script:sw = [System.Diagnostics.Stopwatch]::StartNew()

    StepStart "vai p/ Filtros"
    $telaInicial = Go-Filtros $proc
    StepEnd "(de $telaInicial)"
    $c = Get-Controls $proc.Id
    $form = Resolve-Form $c

    $eEmp = ByOffset $c $form "TEdit" $OFF.Empresa[0] $OFF.Empresa[1]
    $eIni = ByOffset $c $form "TEdit" $OFF.MdfeIni[0] $OFF.MdfeIni[1]
    $eFim = ByOffset $c $form "TEdit" $OFF.MdfeFim[0] $OFF.MdfeFim[1]

    # fallback robusto: se offset falhar (janela abriu deslocada), acha o par
    # Nr MDF-e ini/fim por geometria = os 2 TEdit ~90px na linha de baixo do filtro.
    if (-not $eIni -or -not $eFim) {
        $cands = @($c | Where-Object {
            $_.Class -eq "TEdit" -and $_.Vis -and $_.W -ge 86 -and $_.W -le 94 -and $_.H -ge 18 -and $_.H -le 26
        })
        if ($cands.Count -ge 2) {
            $rowY = ($cands | Sort-Object Y -Descending | Select-Object -First 1).Y   # linha de baixo = MDF-e
            $row = @($cands | Where-Object { [math]::Abs($_.Y - $rowY) -le 4 } | Sort-Object X)
            if ($row.Count -ge 2) {
                if (-not $eIni) { $eIni = $row[0] }
                if (-not $eFim) { $eFim = $row[-1] }
            }
        }
    }

    $bFiltrar = ByText $c "TBitBtn" "Filtrar"
    $grid = $c | Where-Object { $_.Class -eq "TDBAdvGrid" -and $_.Vis } | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1

    foreach ($pair in @(@("Empresa",$eEmp),@("MDF-e ini",$eIni),@("MDF-e fim",$eFim),@("Filtrar",$bFiltrar),@("Grade",$grid))) {
        if (-not $pair[1]) { throw "controle nao encontrado: $($pair[0])" }
    }

    if ($Diag) {
        Write-Host ("  Empresa   @{0},{1}" -f $eEmp.X,$eEmp.Y); Point-Ctl $eEmp; Start-Sleep 1
        Write-Host ("  MDFe ini  @{0},{1}" -f $eIni.X,$eIni.Y); Point-Ctl $eIni; Start-Sleep 1
        Write-Host ("  MDFe fim  @{0},{1}" -f $eFim.X,$eFim.Y); Point-Ctl $eFim; Start-Sleep 1
        Write-Host ("  Filtrar   @{0},{1}" -f $bFiltrar.X,$bFiltrar.Y); Point-Ctl $bFiltrar; Start-Sleep 1
        $gx = $grid.X + 40; $gy = $grid.Y + 32
        Write-Host ("  1a linha  @{0},{1}" -f $gx,$gy); [Win]::SetCursorPos($gx,$gy) | Out-Null; Start-Sleep 1
        Write-Host "  [Diag] nada foi clicado."
        return "diag"
    }

    StepStart "empresa + nr MDFe"
    [Win]::SetText($eEmp.Hwnd, [string]$empresa)
    [Win]::SetText($eIni.Hwnd, [string]$mdfe)
    [Win]::SetText($eFim.Hwnd, [string]$mdfe)
    Commit-Empresa $eEmp
    Wait-Idle $proc.Id
    StepEnd

    StepStart "filtrar"
    Click-Ctl $bFiltrar
    Wait-Idle $proc.Id
    StepEnd

    StepStart "seleciona linha"
    $c = Get-Controls $proc.Id
    $grid = $c | Where-Object { $_.Class -eq "TDBAdvGrid" -and $_.Vis } | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
    DblClick-Row $grid
    StepEnd

    # espera abrir a aba Dados: quando o botao Encerramento aparecer.
    # re-tenta o duplo-clique se demorar (grade TMS as vezes ignora 1 clique)
    StepStart "abre registro"
    $bEnc = $null
    for ($k = 0; $k -lt 30; $k++) {
        Wait-Idle $proc.Id
        $c = Get-Controls $proc.Id
        $bEnc = ByText $c "TBitBtn" "En&cerramento"
        if ($bEnc) { break }
        if ($k -eq 8 -or $k -eq 16) {
            $grid = $c | Where-Object { $_.Class -eq "TDBAdvGrid" -and $_.Vis } | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
            if ($grid) {
                DblClick-Row $grid
                # reforco: Enter na grade (abre registro sem depender do duplo-clique)
                [Win]::PostMessage($grid.Hwnd, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero) | Out-Null
                [Win]::PostMessage($grid.Hwnd, $WM_KEYUP,   [IntPtr]$VK_RETURN, [IntPtr]::Zero) | Out-Null
            }
        }
        Start-Sleep -Milliseconds 120
    }
    if (-not $bEnc) { throw "botao Encerramento nao encontrado (a linha abriu?)" }
    StepEnd

    StepStart "clica Encerrar"
    Click-Ctl $bEnc
    StepEnd

    StepStart "confirmacao"
    $dlg = $null
    for ($w = 0; $w -lt 40; $w++) {
        $c = Get-Controls $proc.Id
        $dlg = $c | Where-Object { $_.Class -eq "TfoMensagemSistema" -and $_.Vis } | Select-Object -First 1
        if ($dlg) { break }
        Start-Sleep -Milliseconds 80
    }
    if (-not $dlg) { throw "caixa de confirmacao nao apareceu" }
    StepEnd

    if ($Execute) {
        Write-Host "  >>> PRODUCAO: encerrar empresa=$empresa mdfe=$mdfe" -ForegroundColor Red
        $resp = Read-Host "  digite ENCERRAR $mdfe para confirmar"
        if ($resp -ne "ENCERRAR $mdfe") {
            Close-Modals $proc | Out-Null
            throw "confirmacao humana negada; item cancelado"
        }
        $sim = ByLike $c "TButton" "&S*"
        if (-not $sim) { throw "botao Sim nao encontrado" }
        Click-Btn-Msg $sim
        return "ENCERRADO"
    } else {
        StepStart "cancela (Nao)"
        $nao = ByLike $c "TButton" "&N*"
        if (-not $nao) { throw "botao Nao nao encontrado" }
        Click-Btn-Msg $nao
        # confirma que a caixa fechou; se travou, forca limpeza
        $closed = $false
        for ($j = 0; $j -lt 15; $j++) {
            Start-Sleep -Milliseconds 120
            if (-not ((Get-Controls $proc.Id) | Where-Object { $_.Class -eq "TfoMensagemSistema" -and $_.Vis })) { $closed = $true; break }
        }
        if (-not $closed) { Close-Modals $proc | Out-Null }
        StepEnd
        return "cancelado(validacao)"
    }
}

# ---------------- main ----------------
$proc = Get-CCE
if (-not $proc) { Write-Host "CCE/MDFe nao encontrado. Abra o modulo Movimentacao de MDFe." -ForegroundColor Red; exit 1 }
Write-Host ("CCE PID {0}" -f $proc.Id) -ForegroundColor Green

if ($Diag) {
    Write-Host "MODO DIAG: apontando controles, sem clicar." -ForegroundColor Yellow
    Processa-Item $proc "1" "17854" | Out-Null
    exit 0
}

if (-not $Csv) { Write-Host "Informe -Csv lista.csv (cabecalho empresa;mdfe) ou use -Diag." -ForegroundColor Yellow; exit 1 }
$itens = @(Import-Csv -Path $Csv -Delimiter ';')
$log = "encerra_mdfe_log.jsonl"
$total = $itens.Count

$script:Total = $total; $script:Ok = 0; $script:Err = 0; $script:Done = 0
$script:swAll = [System.Diagnostics.Stopwatch]::StartNew()
$script:Modo  = if ($Execute) { "PRODUCAO" } else { "VALIDACAO" }
if ($Background) { $script:Modo += " (bg)" }

Panel-Init
Redraw

foreach ($it in $itens) {
    $script:CurEmp = $it.empresa; $script:CurMdfe = $it.mdfe
    $script:Step = 0; $script:Action = "iniciando"
    Redraw
    try {
        $r = Processa-Item $proc $it.empresa $it.mdfe
        $script:Ok++; $status = $r
    } catch {
        $script:Err++; $status = "erro: $_"
    }
    $script:Done++; $script:Step = 0; $script:Action = "concluido"
    Redraw
    @{ at = (Get-Date).ToString("o"); empresa = $it.empresa; mdfe = $it.mdfe; status = "$status" } |
        ConvertTo-Json -Compress | Add-Content -Path $log -Encoding utf8
    Start-Sleep -Milliseconds $Pause
}

Redraw -Final
if ($null -ne $script:AnchorY) { try { [Console]::SetCursorPosition(0, $script:AnchorY + $script:PanelLines) } catch {} }
Write-Host ""
$col = if ($script:Err -gt 0) { "Yellow" } else { "Green" }
Write-Host ("  {0} ok, {1} erro  em {2}     Log: {3}" -f $script:Ok, $script:Err, (Fmt-MMSS $script:swAll.Elapsed), $log) -ForegroundColor $col
Write-Host ""
