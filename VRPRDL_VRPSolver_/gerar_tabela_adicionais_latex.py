# -*- coding: utf-8 -*-
"""
Gera codigo LaTeX (longtable) com os resultados computacionais do VrpSolver
para as 20 instancias adicionais (variant_1 + variant_2), no mesmo estilo da
longtable das 40 instancias originais (gerar_tabela3_latex.py), comparando
contra os tempos da Tabela 7 do artigo Ozbaygin et al. (2017).

Saidas:
- stdout: codigo LaTeX (copiar/colar no Overleaf)
- tabela_adicionais_resultados.tex (mesmo conteudo, para \\input{} se preferir)
"""
from pathlib import Path
import io
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

import pandas as pd

ROOT = Path(__file__).resolve().parent
XLSX = ROOT / "resultados_adicionais.xlsx"
OUT_TEX = ROOT / "tabela_adicionais_resultados.tex"

OZBAYGIN_TL_S = 7200  # n=40 <= 60 -> 2h no artigo

# Tabela 7 do artigo: tempo (s) reportado para cada uma das 20 instancias.
# None = TL atingido sem otimo provado no artigo (apenas "43_v1").
OZBAYGIN_TIME_TAB7 = {
    "41_v1": 1249.35, "41_v2":  854.47,
    "42_v1":    3.00, "42_v2": 1005.36,
    "43_v1":    None, "43_v2":  270.72,
    "44_v1":   98.52, "44_v2":   41.59,
    "45_v1":    1.63, "45_v2":    9.76,
    "46_v1":    3.81, "46_v2":   27.37,
    "47_v1": 3710.35, "47_v2":   68.96,
    "48_v1":    1.15, "48_v2":  477.83,
    "49_v1":  104.26, "49_v2":   13.62,
    "50_v1":    8.74, "50_v2":  164.37,
}


def fmt_int_br(n):
    if n is None:
        return "--"
    return f"{int(n):,}".replace(",", "\\,")


def fmt_float_br(x, nd=2):
    if x is None or (isinstance(x, float) and pd.isna(x)):
        return "--"
    return f"{float(x):.{nd}f}".replace(".", "{,}")


def fmt_signed_pct(x, nd=2, le=False):
    if x is None:
        return "--"
    sign = "+" if x >= 0 else "-"
    body = f"{abs(x):.{nd}f}".replace(".", "{,}")
    prefix = "$\\leq " if le else "$"
    return f"{prefix}{sign}{body}\\,\\%$"


def main():
    df_v1 = pd.read_excel(XLSX, sheet_name="variant_1")
    df_v2 = pd.read_excel(XLSX, sheet_name="variant_2")

    nosso = {}
    for _, row in df_v1.iterrows():
        idx = int(str(row["Instância"]).replace("instance_", ""))
        nosso[("v1", idx)] = row
    for _, row in df_v2.iterrows():
        idx = int(str(row["Instância"]).replace("variant2_instance_", ""))
        nosso[("v2", idx)] = row

    caption = (
        r"Resultados computacionais obtidos com o \textsc{VrpSolver} para as 20 "
        r"instâncias adicionais (pares $v_1$/$v_2$ derivados das instâncias 41--50 "
        r"de Özbaygın et al.~(2017), com $n = 40$ clientes), no mesmo formato da "
        r"Tabela~\ref{tab:resultados-vrpsolver}: melhor solução, gap na raiz, tempo "
        r"de solução, número de iterações de geração de colunas, número de nós no "
        r"\emph{Branch-Cut-and-Price}, número total de colunas geradas e diferença "
        r"percentual de tempo em relação aos valores reportados na Tabela~7 de "
        r"Özbaygın et al.~(2017). As instâncias do tipo $v_1$ posicionam os locais "
        r"itinerantes \emph{mais distantes} do depósito; as do tipo $v_2$, "
        r"\emph{mais próximos}."
    )
    header_row = (
        r"    Instância & \shortstack{Melhor\\solução} & \shortstack{Gap na\\raiz (\%)} & "
        r"\shortstack{Tempo de\\solução (s)} & \shortstack{Iterações\\(CG)} & Nós & "
        r"\shortstack{Colunas\\geradas} & \shortstack{$\Delta$ tempo vs.\\Özbaygın (\%)} \\"
    )
    ncols_tab = 8
    note = (
        r"\multicolumn{" + str(ncols_tab) + r"}{@{}p{0.98\linewidth}@{}}{\footnotesize "
        r"$^{\dagger}$ Instância para a qual Özbaygın et al.~(2017) reportam tempo-limite "
        r"(TL) na Tabela~7, sem provar otimalidade. Nesses casos, a coluna ``$\Delta$ "
        r"tempo'' indica um \emph{limite superior} da redução percentual, calculado "
        r"substituindo o tempo real por $\mathrm{TL} = 7\,200$~s (instâncias com "
        r"$n = 40 \leq 60$).} \\"
    )

    lines = []
    lines.append(r"% Requer no preâmbulo: \usepackage{booktabs}  \usepackage{longtable}")
    lines.append(r"\begingroup")
    lines.append(r"\footnotesize")
    lines.append(r"\setlength{\tabcolsep}{4pt}")
    lines.append(r"\renewcommand{\arraystretch}{1.05}")
    lines.append(r"\begin{longtable}{@{}l r r r r r r r@{}}")
    lines.append(r"  \caption{" + caption + r"}")
    lines.append(r"  \label{tab:resultados-vrpsolver-adicionais} \\")
    lines.append(r"  \toprule")
    lines.append(header_row)
    lines.append(r"  \midrule")
    lines.append(r"  \endfirsthead")
    lines.append(r"  \multicolumn{" + str(ncols_tab) + r"}{@{}l}{\footnotesize\itshape "
                 r"Tabela~\ref{tab:resultados-vrpsolver-adicionais} -- continuação da "
                 r"página anterior.} \\")
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

    for k_base in range(0, 10):                         # 0..9 -> instancias 41..50
        for var in ("v1", "v2"):
            label = f"{41 + k_base}_{var}"
            tex_label = f"$\\mathrm{{{41 + k_base}_{{{var}}}}}$"
            row = nosso[(var, k_base)]

            best = int(row["Best solution"])
            gap = float(row["Integrality gap (%)"])
            our_time = float(row["Solution time (s)"])
            iters = int(row["Iterations (CG)"])
            nodes = int(row["Nodes"])
            ncols = int(row["Columns generated (total)"])

            oz_t = OZBAYGIN_TIME_TAB7[label]
            if oz_t is not None:
                delta = (our_time - oz_t) / oz_t * 100.0
                delta_str = fmt_signed_pct(delta, nd=2, le=False)
            else:
                delta = (our_time - OZBAYGIN_TL_S) / OZBAYGIN_TL_S * 100.0
                delta_str = fmt_signed_pct(delta, nd=2, le=True) + r"\,$^{\dagger}$"

            lines.append(
                f"  {tex_label} & {fmt_int_br(best)} & {fmt_float_br(gap, 2)} & "
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
