import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import pandas as pd
from pathlib import Path
xlsx = Path(r"C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\VRPRDL_VRPSolver_\resultados_adicionais.xlsx")
for sh in ["variant_1", "variant_2", "Comparativo v1xv2"]:
    df = pd.read_excel(xlsx, sheet_name=sh)
    print(f"=== {sh} ===")
    print(df.to_string(index=False))
    print()
