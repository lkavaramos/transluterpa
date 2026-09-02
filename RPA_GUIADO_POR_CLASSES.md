# RPA guiado por classes — encerramento de MDF-e no CCE

> Documento pra explicar o que foi feito no `encerra_mdfe.ps1` e por que ele é
> diferente (e mais robusto) do protótipo `mdfe_softran_local.py`.
> **Spoiler:** os dois têm o mesmo objetivo e a mesma governança fiscal. A
> diferença está em **como o robô enxerga a tela e age nela**.

---

## TL;DR

| | Protótipo (Ollama + Playwright) | `encerra_mdfe.ps1` (win32) |
|---|---|---|
| **Enxerga a tela** | Screenshot → modelo de visão devolve coordenada | Lê a **árvore de controles** do Windows (classe, texto, retângulo) |
| **Age** | Move o mouse e clica em `x,y` | Manda mensagem pro controle (`WM_SETTEXT`, `BM_CLICK`) |
| **Depende de** | Zoom, resolução, layout de pixels, confiança do LLM | Classe/`ClassName` do componente Delphi |
| **Quebra se** | Botão muda de lugar, tela rola, fonte muda | Praticamente só se recompilarem o form |
| **Precisa de** | GPU/modelo de visão, navegador aberto, cursor livre | Nada além do Windows (P/Invoke puro) |
| **Roda em 2º plano** | Não (usa o cursor real e a tela) | **Sim** (PostMessage, sem tocar no mouse) |
| **Velocidade** | Cada passo = 1 screenshot + inferência | Cada passo = 1 chamada de API do Windows |

Ambos param antes do clique fiscal, exigem confirmação humana e só consideram
sucesso com retorno **135** da SEFAZ. Isso o teu protótipo acertou em cheio e
**foi mantido**.

---

## 1. O ponto de partida é o mesmo

O CCE é um app **Delphi (VCL + componentes TMS)** publicado via TSplus. O
encerramento de MDF-e é um **evento fiscal**: o app monta o XML, assina com
certificado, manda pra SEFAZ e só então grava. Nenhum dos dois robôs tenta
"burlar" isso — os dois dirigem o app de verdade.

A diferença começa em **o que existe do lado do cliente**:

- No HTML5 do TSplus, o navegador só recebe **pixels** (um vídeo do desktop
  remoto). Sem árvore, sem DOM útil do app. Por isso o protótipo foi por
  **visão computacional**: era a única superfície disponível de dentro do
  navegador.
- Rodando **dentro da sessão** (onde o app realmente está), o Windows expõe a
  **árvore de controles** de cada janela. Aí some a necessidade de "ler pixel":
  dá pra perguntar ao sistema "quais controles existem, de que classe, com que
  texto, em que posição".

**A virada de chave foi mover a execução pra dentro da sessão.** Tudo o resto
decorre disso.

---

## 2. A diferença central: olhos e mãos

### Protótipo — olhos de visão, mãos de coordenada
```
screenshot → LLM → {"target": {"x": 634, "y": 155}} → mouse.click(634,155)
```
O modelo precisa **acertar o pixel** toda vez. Se a tela abrir com outro zoom,
se a linha da grade estiver em outra altura, se a fonte renderizar diferente no
HTML5, a coordenada erra. E pra saber *quando* a tela terminou de carregar, ele
tira outro screenshot e pergunta de novo. É engenhoso, mas cada passo é uma
aposta probabilística sobre pixels.

### win32 — olhos de árvore, mãos de mensagem
O robô lê os controles direto da API do Windows:

```powershell
# "me dá todos os controles do processo: classe, texto, retângulo, visível"
[Win]::GetClassName(...)   # -> "TBitBtn", "TDBAdvGrid", "TfoMensagemSistema"
[Win]::Text(...)           # -> "Filtrar", "En&cerramento", "&Não"  (via WM_GETTEXT)
[Win]::GetWindowRect(...)  # -> posição real, seja qual for
```

E age mandando **mensagem pro controle certo**, não clicando num ponto:

```powershell
[Win]::SetText($campo.Hwnd, "17854")                 # WM_SETTEXT  -> digita
[Win]::PostMessage($btn.Hwnd, 0x00F5, 0, 0)          # BM_CLICK    -> clica no botão
```

O botão "Encerramento" é achado **pelo texto `En&cerramento`**, não pela posição
`@634,155`. Se amanhã ele estiver 40px pra baixo, o robô acha do mesmo jeito,
porque a identidade dele é a **classe + o texto**, não o lugar.

---

## 3. Como o robô identifica cada coisa

Três formas de identificar um controle, em ordem de robustez:

1. **Por texto** (a mais forte) — botões e abas têm caption:
   `Filtrar`, `Limpar`, `En&cerramento`, `&Não`, aba `Filtros`/`Dados`.
   Texto não muda quando o layout muda. É âncora sólida.

2. **Por classe + relação estrutural** — a grade de resultados é o
   `TDBAdvGrid` **visível de maior área**; a caixa de confirmação é a janela de
   classe `TfoMensagemSistema`. Não importa onde estejam.

3. **Por geometria relativa** (só quando não há texto) — os campos "Nr MDF-e
   Inicial/Final" são `TEdit` sem rótulo (no Delphi o `TLabel` nem tem HWND, então
   o rótulo é invisível pra API). Aí a gente identifica pela **estrutura**: são os
   dois `TEdit` de ~90px na **linha de baixo** do painel de filtro — o da esquerda
   é o Inicial, o da direita é o Final. Isso sobrevive a janela mudar de posição.

```powershell
# par Nr MDF-e ini/fim por geometria (fallback quando o offset falha)
$cands = $c | Where-Object { $_.Class -eq "TEdit" -and $_.W -ge 86 -and $_.W -le 94 }
$rowY  = ($cands | Sort-Object Y -Descending | Select-Object -First 1).Y  # linha de baixo
$row   = $cands | Where-Object { [math]::Abs($_.Y - $rowY) -le 4 } | Sort-Object X
$eIni  = $row[0]; $eFim = $row[-1]
```

Repara: **em nenhum momento existe um `x,y` chumbado no código.** Todo alvo é
resolvido **ao vivo** a cada item, a partir do que a árvore mostra naquele
instante.

---

## 4. Robustez que a coordenada não dá

Coisas que caem "de graça" quando você fala com o controle em vez do pixel:

- **Sincronismo real, não `sleep` no chute.** O CCE publica uma janela de
  "ocupado" (`TfrmADGUIxFormsAsyncExecute` / AnyDAC). O robô **espera ela sumir**
  — é o sinal exato de "a query terminou", em vez de dormir um tempo fixo.

- **Troca de aba sem clicar em pixel.** Pra ir de "Dados" pra "Filtros", ele manda
  `TCM_SETCURFOCUS` direto no `TPageControl` — o Delphi troca a página sozinho.
  Nada de adivinhar onde fica o título da aba.

- **Roda em segundo plano.** Como age por `PostMessage`, **não usa o cursor**.
  Você pode mexer o mouse, usar a máquina, minimizar a janela — o robô continua.
  Isso é impossível quando você depende de mover o mouse físico até um `x,y`.

- **Auto-cura do loop.** Se uma caixa de confirmação ficar presa, o próximo item
  detecta e fecha **por botão seguro** (Não/Cancelar/OK — **nunca Sim**) antes de
  continuar. Um popup preso não derruba a fila inteira.

- **Não quebra quando a janela abre deslocada.** Offset calibrado como 1ª
  tentativa + fallback geométrico. Se ainda assim mudar, dá erro **claro naquele
  item** e segue — não vira clique perdido em lugar nenhum.

---

## 5. O que foi mantido do teu protótipo (crédito onde é devido)

A parte de **governança fiscal** do `mdfe_softran_local.py` é excelente e foi
preservada em espírito:

- **Modo validação por padrão** (clica "Não") — nada é encerrado sem intenção.
- **Confirmação humana** no modo produção (digitar `ENCERRAR <nr>`).
- **Nunca clicar "Sim" automaticamente** em limpeza de caixa.
- **Sucesso ≠ "arquivo enviado"**; sucesso é **135 + protocolo + Encerrado**.
- **Auditoria** (JSONL por item).
- **A tela é evidência, não instrução** — mesma postura de segurança.

A diferença é só o **motor de olhos e mãos** por baixo dessa governança.

---

## 6. Sendo honesto: quando cada abordagem é a certa

Isto não é "visão é ruim". É **usar a ferramenta certa pra cada superfície**:

- **Só tem pixel disponível** (HTML5 remoto sem acesso à sessão, app sem árvore
  de acessibilidade, canvas/jogo): **visão é o caminho** — às vezes o único.
- **Dá pra executar dentro da sessão** e o app expõe controles (Delphi/VCL, WinForms,
  Win32, a maioria dos ERPs desktop): **class-guided ganha** em robustez,
  velocidade, custo (sem GPU/LLM) e por rodar headless.

O protótipo não estava "errado" — ele estava **preso do lado de fora**, só com
pixels. No momento em que a gente conseguiu rodar **dentro da sessão**, a árvore
de controles apareceu e a estratégia melhor mudou junto.

---

## 7. Glossário rápido das técnicas

| Técnica | Pra quê |
|---|---|
| `EnumWindows` + `GetWindow(GW_CHILD)` | Percorrer a árvore de janelas/controles do processo |
| `GetClassName` | Identificar o tipo do componente (`TBitBtn`, `TDBAdvGrid`…) |
| `WM_GETTEXT` (`SendMessage`) | Ler o texto de um controle **entre processos** (o `GetWindowText` não lê campo de edição de outro processo) |
| `WM_SETTEXT` | Escrever num campo sem digitar tecla a tecla |
| `BM_CLICK` (`PostMessage`) | Clicar num botão sem foco/cursor, sem travar em modal |
| `WM_LBUTTONDBLCLK` (`PostMessage`) | Duplo-clique na grade em 2º plano |
| `TCM_SETCURFOCUS` | Trocar a aba de um `TPageControl` por mensagem nativa |
| Janela `AnyDAC` visível | Sinal de "app ocupado" pra sincronizar sem `sleep` cego |

Tudo isso é **API nativa do Windows via P/Invoke** — zero dependência instalada.
É a mesma base que o AutoIt e o `pywinauto` usam por baixo; aqui está cru, em
PowerShell, pra rodar sem instalar nada na sessão.

---

## 8. Resultado

- Roda **em segundo plano**, na velocidade real do app (~6–7s/item, quase tudo
  latência do CCE/TSplus, não do robô).
- **Não usa OCR, não usa coordenada fixa, não usa GPU/LLM.**
- Alvos resolvidos por **classe + texto + estrutura**, ao vivo, a cada item.
- Governança fiscal intacta (validação, confirmação humana, 135, auditoria).

É isso a vantagem de um RPA guiado por classes: você para de brigar com pixels
e passa a **conversar com os controles do app**. Menos mágica, mais engenharia —
e muito mais difícil de quebrar.
