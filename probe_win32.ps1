# Probe WIN32 v2 — RODAR DENTRO DA SESSAO. Zero-install.
# Novidades: le o VALOR do controle via WM_GETTEXT (atravessa processo, ao
# contrario do GetWindowText) e mostra a POSICAO (rect) de cada controle.
# Isso permite mapear campos sem rotulo (o TLabel do Delphi nao tem HWND).
#
# Uso:
#   1) Abra a tela REAL do MDFe e, se puder, digite um MDF-e conhecido no filtro.
#   2) powershell -ExecutionPolicy Bypass -File probe_win32.ps1 "MDF"
#      (ou o titulo que aparecer na barra da janela)

param(
    [Parameter(Mandatory=$true)][string]$Titulo,
    [int]$MaxDepth = 16
)

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, StringBuilder lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageT(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr[] Top(uint pid){
    var list = new List<IntPtr>();
    EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h, out p); if(p==pid) list.Add(h); return true; }, IntPtr.Zero);
    return list.ToArray();
  }
  public static string Text(IntPtr h){
    const uint WM_GETTEXTLENGTH=0x000E, WM_GETTEXT=0x000D;
    int len = (int)SendMessageT(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero);
    if(len<=0) return "";
    var sb = new StringBuilder(len+1);
    SendMessageW(h, WM_GETTEXT, (IntPtr)(len+1), sb);
    return sb.ToString();
  }
}
"@ -ReferencedAssemblies System.Drawing

$GW_CHILD = 5; $GW_HWNDNEXT = 2

$p = Get-Process | Where-Object { $_.MainWindowTitle -like "*$Titulo*" } | Select-Object -First 1
if (-not $p) { Write-Host "Nao achei processo com titulo *$Titulo*" -ForegroundColor Red; return }
Write-Host ("Processo: {0} (PID {1})`n" -f $p.ProcessName, $p.Id) -ForegroundColor Green

function Node($h, $depth) {
    $c = New-Object System.Text.StringBuilder 256
    [W]::GetClassName($h, $c, 256) | Out-Null
    $cls = $c.ToString()
    $txt = [W]::Text($h)
    $r = New-Object W+RECT
    [W]::GetWindowRect($h, [ref]$r) | Out-Null
    $v = if ([W]::IsWindowVisible($h)) { " " } else { "x" }
    $pos = "{0},{1} {2}x{3}" -f $r.L, $r.T, ($r.R - $r.L), ($r.B - $r.T)
    $val = if ($txt) { " val='$txt'" } else { "" }
    "{0}[{1}] {2,-24} @{3,-16}{4}" -f ("  " * $depth), $v, $cls, $pos, $val
    $child = [W]::GetWindow($h, $GW_CHILD)
    while ($child -ne [IntPtr]::Zero) {
        Node $child ($depth + 1)
        $child = [W]::GetWindow($child, $GW_HWNDNEXT)
    }
}

foreach ($h in [W]::Top([uint32]$p.Id)) {
    $c = New-Object System.Text.StringBuilder 256
    [W]::GetClassName($h, $c, 256) | Out-Null
    Write-Host ("===== TOP: [{0}] '{1}' =====" -f $c.ToString(), [W]::Text($h)) -ForegroundColor Yellow
    Node $h 0
    ""
}
