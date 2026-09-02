"""
Inspetor de árvore de controles — RODAR DENTRO DA SESSÃO TSplus.

Uso:
  1) pip install pywinauto uiautomation comtypes
  2) Deixe o app legado ABERTO e visível.
  3) python inspect_app.py            -> lista as janelas de topo (pega o "title")
  4) python inspect_app.py "Parte do titulo"  -> despeja a árvore dessa janela

Compare a saída UIA vs WIN32: o backend que mostrar AutomationId/auto_id
e nomes úteis é o que vamos usar pra escrever o robô.
"""
import sys
from pywinauto import Desktop


def listar_janelas():
    print("=== Janelas de topo (backend uia) ===")
    for w in Desktop(backend="uia").windows():
        try:
            t = w.window_text()
            if t.strip():
                print(f"  [{w.class_name():30}] {t!r}")
        except Exception:
            pass


def dump(titulo, backend):
    print(f"\n\n########## BACKEND = {backend} ##########")
    try:
        dlg = Desktop(backend=backend).window(title_re=f".*{titulo}.*")
        dlg.wait("exists ready", timeout=10)
        # imprime a árvore com auto_id, control_type, class_name, texto
        dlg.print_control_identifiers(depth=None)
    except Exception as e:
        print(f"  ({backend}) falhou: {e}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        listar_janelas()
        print("\nAgora rode:  python inspect_app.py \"trecho do titulo da janela\"")
    else:
        alvo = sys.argv[1]
        dump(alvo, "uia")
        dump(alvo, "win32")
