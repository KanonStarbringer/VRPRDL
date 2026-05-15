"""
Gera código LaTeX (longtable) comparando nossos resultados das 20 instâncias
adicionais com a Tabela 7 do artigo Özbaygın et al. (2017).

Saídas:
- stdout: LaTeX (copiar/colar no Overleaf)
- tabela7_resultados.tex (mesmo conteúdo, para \\input)
"""

from __future__ import annotations
from pathlib import Path
import io
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

import pandas as pd

ROOT = Path(r"C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\VRPRDL_VRPSolver_")
XLSX = ROOT / "resultados_adicionais.xlsx"
OUT_TEX = ROOT / "tabela7_resultados.tex"

OZBAYGIN_TL_S = 7200  # 2h, n <= 60 (instâncias 41-50 têm n=40)

# Tabela 7 do artigo: (instance_label, best_sol, time_s_or_None_for_TL, iterations, nodes, gap_pct)
# Mapping com nossas pastas:
#   41_v1 -> variant_1/instance_0   ;  41_v2 -> variant_2/variant2_instance_0
#   ...
#   50_v1 -> variant_1/instance_9   ;  50_v2 -> variant_2/variant2_instance_9
OZBAYGIN_TABLE7 = [
    ("41_v1", 3203, 1249.35,   33672,  6147,  1.88),
    ("41_v2", 2133,  854.47,    7528,   805,  2.33),
    ("42_v1", 2799,    3.00,      58,     1,  0.00),
    ("42_v2", 1946, 1005.36,    6472,   743,  4.12),
    ("43_v1", 2607,    None,  111845, 14854,  3.68),  # TL
    ("43_v2", 1966,  270.72,    1644,   135,  1.09),
    ("44_v1", 2261,   98.52,    2342,   251,  2.03),
    ("44_v2", 1610,   41.59,     222,     1,  0.00),
    ("45_v1", 3217,    1.63,      34,     1,  0.00),
    ("45_v2", 2478,    9.76,      80,     1,  0.00),
    ("46_v1", 2805,    3.81,     126,     5,  0.91),
    ("46_v2", 2469,   27.37,     302,    39,  1.11),
    ("47_v1", 3339, 3710.35,   89246, 21169,  3.38),
    ("47_v2", 1946,   68.96,     556,    37,  1.22),
    ("48_v1", 3325,    1.15,      48,     1,  0.00),
    ("48_v2", 2380,  477.83,    8384,  1493,  1.65),
    ("49_v1", 3534,  104.26,    3084,   595,  1.82),
    ("49_v2", 2492,   13.62,     207,     9,  0.55),
    ("50_v1", 2752,    8.74,     114,     1,  0.00),
    ("50_v2", 2443,  164.37,    1038,   119,  0.38),
]


def fmt_int(n):
    if n is None:
        return "--"
    s = f"{int(n):,}".replace(",", "\\,")
    return s


def fmt_float(x, nd=2):
    if x is None or (isinstance(x, float) and pd.isna(x)):
        return "--"
    s = f"{float(x):.{nd}f}".replace(".", "{,}")
    return s


def fmt_signed_pct(x, nd=2, le=False, hl=False):
    """Formata valor percentual com sinal explícito.
    le=True -> prefixa $\\leq$ (limite superior, p/ TL)
    hl=True -> envolve em \\textbf{...} para destacar (Δ negativo grande)
    """
    if x is None:
        return "--"
    sign = "+" if x >= 0 else "-"
    body = f"{abs(x):.{nd}f}".replace(".", "{,}")
    prefix = r"$\leq " if le else "$"
    inner = f"{prefix}{sign}{body}\\,\\%$"
    if hl:
        return r"\textbf{" + inner + r"}"
    return inner


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

    lines = []
    lines.append(r"% Requer no preâmbulo: \usepackage{booktabs}  \usepackage{longtable}")
    caption = (
        r"Resultados das 20 instâncias adicionais (pares $v_1$/$v_2$, instâncias 41--50 "
        r"de Özbaygın et al.~(2017)) obtidos pelo \textsc{VrpSolver}, comparados com a "
        r"Tabela~7 do mesmo artigo. As colunas $\Delta$ trazem a variação relativa do "
        r"tempo de execução e do custo entre as duas abordagens. As instâncias $v_1$ "
        r"posicionam os locais de entrega itinerantes mais distantes do depósito; as $v_2$, "
        r"mais próximas."
    )
    ncols = 11

    header_row1 = (
        r"  \multirow{2}{*}{Inst.} & "
        r"\multicolumn{4}{c}{Özbaygın et al.~(2017), Tab.~7} & "
        r"\multicolumn{4}{c}{\textsc{VrpSolver} (nosso)} & "
        r"\multirow{2}{*}{\shortstack{$\Delta$ tempo\\(\%)}} & "
        r"\multirow{2}{*}{\shortstack{$\Delta$ custo\\(\%)}} \\"
        "\n"
        r"  \cmidrule(lr){2-5}\cmidrule(lr){6-9}"
    )
    header_row2 = (
        r"  & Custo & \shortstack{Tempo\\(s)} & Iter. & Nós "
        r"& Custo & \shortstack{Tempo\\(s)} & \shortstack{Iter.\\(CG)} & Nós & & \\"
    )

    lines.append(r"\begingroup")
    lines.append(r"\scriptsize")
    lines.append(r"\setlength{\tabcolsep}{3.5pt}")
    lines.append(r"\renewcommand{\arraystretch}{1.05}")
    lines.append(r"\begin{longtable}{@{}l rrrr rrrr rr@{}}")
    lines.append(r"  \caption{" + caption + r"}")
    lines.append(r"  \label{tab:resultados-adicionais-vs-tab7} \\")
    lines.append(r"  \toprule")
    lines.append(header_row1)
    lines.append(header_row2)
    lines.append(r"  \midrule")
    lines.append(r"  \endfirsthead")
    lines.append(
        r"  \multicolumn{" + str(ncols) + r"}{@{}l}{\footnotesize\itshape "
        r"Tabela~\ref{tab:resultados-adicionais-vs-tab7} -- continuação da página anterior.} \\"
    )
    lines.append(r"  \toprule")
    lines.append(header_row1)
    lines.append(header_row2)
    lines.append(r"  \midrule")
    lines.append(r"  \endhead")
    lines.append(r"  \midrule")
    lines.append(
        r"  \multicolumn{" + str(ncols) + r"}{r@{}}{\footnotesize\itshape "
        r"Continua na próxima página\dots} \\"
    )
    lines.append(r"  \endfoot")
    lines.append(r"  \bottomrule")
    lines.append(
        r"  \multicolumn{" + str(ncols) + r"}{@{}p{0.99\linewidth}@{}}{\footnotesize "
        r"$^{\dagger}$ Instância para a qual Özbaygın et al.~(2017) atingiram o tempo-limite "
        r"de $\mathrm{TL}=7\,200$~s sem comprovar otimalidade. Nesses casos, $\Delta$ tempo "
        r"é um \emph{limite superior} da redução, calculado com $\mathrm{TL}$ no lugar do "
        r"tempo real, e o custo do artigo é apenas a melhor solução factível conhecida por "
        r"eles (não o ótimo). Quando o nosso custo é estritamente menor (em negrito), "
        r"melhoramos a melhor solução publicada. \par "
        r"Notas: \emph{Iter.}\ no artigo refere-se ao número de iterações reportado por "
        r"Özbaygın et al.~(2017); \emph{Iter.~(CG)} no nosso é o número de iterações de "
        r"geração de colunas extraído do log do \textsc{VrpSolver}. As duas grandezas "
        r"contam etapas afins, mas não são idênticas. Decimais em vírgula e separador de "
        r"milhar em \,, conforme convenção pt-BR.} \\"
    )
    lines.append(r"  \endlastfoot")

    base_id_to_idx = {n: n - 41 for n in range(41, 51)}

    for label, oz_cost, oz_time, oz_iter, oz_nodes, oz_gap in OZBAYGIN_TABLE7:
        base_id = int(label.split("_")[0])
        v_tag = label.split("_")[1]  # v1 ou v2
        idx = base_id_to_idx[base_id]
        row = nosso.get((v_tag, idx))
        if row is None:
            continue
        our_cost = int(row["Best solution"])
        our_time = float(row["Solution time (s)"])
        our_iter = int(row["Iterations (CG)"])
        our_nodes = int(row["Nodes"])

        if oz_time is not None:
            d_time = (our_time - oz_time) / oz_time * 100.0
            d_time_str = fmt_signed_pct(d_time, nd=2, le=False)
            oz_time_str = fmt_float(oz_time, 2)
        else:
            d_time = (our_time - OZBAYGIN_TL_S) / OZBAYGIN_TL_S * 100.0
            d_time_str = fmt_signed_pct(d_time, nd=2, le=True) + r"\,$^{\dagger}$"
            oz_time_str = r"$\mathrm{TL}^{\dagger}$"

        d_cost = (our_cost - oz_cost) / oz_cost * 100.0
        d_cost_str = fmt_signed_pct(d_cost, nd=2, hl=(d_cost < 0))
        our_cost_str = fmt_int(our_cost)
        if d_cost < 0:
            our_cost_str = r"\textbf{" + our_cost_str + r"}"

        latex_label = label.replace("_", r"\_")
        lines.append(
            f"  {latex_label} & "
            f"{fmt_int(oz_cost)} & {oz_time_str} & {fmt_int(oz_iter)} & {fmt_int(oz_nodes)} & "
            f"{our_cost_str} & {fmt_float(our_time, 2)} & {fmt_int(our_iter)} & {fmt_int(our_nodes)} & "
            f"{d_time_str} & {d_cost_str} \\\\"
        )

    lines.append(r"\end{longtable}")
    lines.append(r"\endgroup")

    content = "\n".join(lines) + "\n"
    OUT_TEX.write_text(content, encoding="utf-8")

    print(content)
    print(f"% arquivo salvo em: {OUT_TEX}", file=sys.stderr)


if __name__ == "__main__":
    main()
