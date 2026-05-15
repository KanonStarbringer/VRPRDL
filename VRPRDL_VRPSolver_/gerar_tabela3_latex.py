"""
Gera código LaTeX da tabela de resultados do VRPSolver no formato da Tabela 3
de Özbaygın et al. (2017), em português, com duas colunas extras:
- colunas geradas
- Δ tempo vs. artigo (%)

Saídas:
- stdout: código LaTeX (copiar/colar no Overleaf)
- tabela3_resultados.tex (mesmo conteúdo, para \\input{} se preferir)
"""
from pathlib import Path
import re
import io
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import pandas as pd

ROOT = Path(r"C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\VRPRDL_VRPSolver_")
XLSX = ROOT / "tabela3_comparativo.xlsx"
OUT_TEX = ROOT / "tabela3_resultados.tex"

OZBAYGIN_TL_S = {k: (2 * 3600) for k in range(1, 31)} | {k: (6 * 3600) for k in range(31, 41)}

OZBAYGIN_TIME = {
    1: 0.58, 2: 0.27, 3: 0.43, 4: 0.27, 5: 0.04,
    6: 2.30, 7: 30.47, 8: 0.18, 9: 3.32, 10: 0.55,
    11: 14.28, 12: 120.38, 13: 23.33, 14: 30.83, 15: 22.78,
    16: 57.13, 17: 5.75, 18: 2.10, 19: 93.55, 20: 78.70,
    21: 606.60, 22: 272.43, 23: 238.27, 24: 382.37, 25: None,
    26: 78.61, 27: 296.23, 28: None, 29: None, 30: 45.22,
    **{k: None for k in range(31, 41)},
}


def fmt_int_br(n):
    if n is None:
        return "--"
    s = f"{int(n):,}".replace(",", "\\,")
    return s


def fmt_float_br(x, nd=2):
    if x is None or (isinstance(x, float) and pd.isna(x)):
        return "--"
    s = f"{float(x):.{nd}f}".replace(".", "{,}")
    return s


def fmt_signed_pct(x, nd=2, le=False):
    if x is None:
        return "--"
    sign = "+" if x >= 0 else "-"
    body = f"{abs(x):.{nd}f}".replace(".", "{,}")
    prefix = "$\\leq " if le else "$"
    return f"{prefix}{sign}{body}\\,\\%$"


def main():
    df = pd.read_excel(XLSX, sheet_name=0)

    caption = (
        r"Resultados computacionais obtidos com o \textsc{VrpSolver} para as 40 "
        r"instâncias do primeiro conjunto de Özbaygın et al.~(2017), em formato análogo ao da "
        r"Tabela~3 do referido artigo, acrescidas de duas colunas: o número total de colunas "
        r"geradas pela geração de colunas e a diferença percentual de tempo de execução em "
        r"relação aos tempos reportados na Tabela~3 de Özbaygın et al.~(2017)."
    )
    header_row = (
        r"    Instância & \shortstack{Melhor\\solução} & \shortstack{Gap na\\raiz (\%)} & "
        r"\shortstack{Tempo de\\solução (s)} & \shortstack{Iterações\\(CG)} & Nós & "
        r"\shortstack{Colunas\\geradas} & \shortstack{$\Delta$ tempo vs.\\Özbaygın (\%)} \\"
    )
    ncols_tab = 8
    note = (
        r"\multicolumn{" + str(ncols_tab) + r"}{@{}p{0.98\linewidth}@{}}{\footnotesize "
        r"$^{\dagger}$ Instância para a qual Özbaygın et al.~(2017) reportam tempo-limite (TL), "
        r"sem provar otimalidade. Nesses casos, a coluna ``$\Delta$ tempo'' indica um "
        r"\emph{limite superior} da redução percentual, calculado substituindo o tempo real por "
        r"$\mathrm{TL}=7\,200$~s (instâncias 25, 28 e 29, com $n=60$) ou "
        r"$\mathrm{TL}=21\,600$~s (instâncias 31--40, com $n=120$).} \\"
    )

    lines = []
    lines.append(r"% Requer no preâmbulo: \usepackage{booktabs}  \usepackage{longtable}")
    lines.append(r"\begingroup")
    lines.append(r"\footnotesize")
    lines.append(r"\setlength{\tabcolsep}{4pt}")
    lines.append(r"\renewcommand{\arraystretch}{1.05}")
    lines.append(r"\begin{longtable}{@{}r r r r r r r r@{}}")
    lines.append(r"  \caption{" + caption + r"}")
    lines.append(r"  \label{tab:resultados-vrpsolver} \\")
    lines.append(r"  \toprule")
    lines.append(header_row)
    lines.append(r"  \midrule")
    lines.append(r"  \endfirsthead")
    lines.append(r"  \multicolumn{" + str(ncols_tab) + r"}{@{}l}{\footnotesize\itshape "
                 r"Tabela~\ref{tab:resultados-vrpsolver} -- continuação da página anterior.} \\")
    lines.append(r"  \toprule")
    lines.append(header_row)
    lines.append(r"  \midrule")
    lines.append(r"  \endhead")
    lines.append(r"  \midrule")
    lines.append(r"  \multicolumn{" + str(ncols_tab) + r"}{r@{}}{\footnotesize\itshape "
                 r"Continua na próxima página\dots} \\")
    lines.append(r"  \endfoot")
    lines.append(r"  \bottomrule")
    lines.append(r"  " + note)
    lines.append(r"  \endlastfoot")

    for _, row in df.iterrows():
        k = int(row["Instance"])
        best = int(row["Best solution"])
        gap = float(row["Integrality gap (%)"])
        our_time = float(row["Solution time (s)"])
        iters = int(row["Iterations (CG)"])
        nodes = int(row["Nodes"])
        ncols = int(row["Columns generated (total)"])

        oz_t = OZBAYGIN_TIME[k]
        if oz_t is not None:
            delta = (our_time - oz_t) / oz_t * 100.0
            delta_str = fmt_signed_pct(delta, nd=2, le=False)
        else:
            tl = OZBAYGIN_TL_S[k]
            delta = (our_time - tl) / tl * 100.0
            delta_str = fmt_signed_pct(delta, nd=2, le=True) + r"\,$^{\dagger}$"

        lines.append(
            f"  {k} & {fmt_int_br(best)} & {fmt_float_br(gap, 2)} & "
            f"{fmt_float_br(our_time, 2)} & {fmt_int_br(iters)} & {fmt_int_br(nodes)} & "
            f"{fmt_int_br(ncols)} & {delta_str} \\\\"
        )

    lines.append(r"\end{longtable}")
    lines.append(r"\endgroup")

    content = "\n".join(lines) + "\n"
    OUT_TEX.write_text(content, encoding="utf-8")

    print(content)
    print(f"% arquivo salvo em: {OUT_TEX}", file=sys.stderr)


if __name__ == "__main__":
    main()
