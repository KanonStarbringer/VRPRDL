import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import pandas as pd
path = r'C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\VRPRDL_VRPSolver_\tabela3_comparativo.xlsx'
df = pd.read_excel(path, sheet_name=0)
print(df.columns.tolist())
print(df.to_string(index=False))
