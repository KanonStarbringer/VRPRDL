# VRPRDL com o Hexaly Optimizer

Pasta auxiliar que resolve as 60 instâncias VRPRDL (40 originais
`VRPRDL-triangle/instance_*.txt` + 20 adicionais
`additional_instances/variant_{1,2}/...`) usando o **Hexaly 14.5** como
*solver heurístico* anytime, para servir de baseline ao VRPSolver/Bapcod.

## Conteúdo

- `vrprdl_hexaly.py` &mdash; parser do formato turco + modelo Hexaly em
  Python:
  - lista de clientes por veículo (`model.list(N)` + `model.partition`);
  - escolha de local (`model.int(0, |S_i|-1)` mapeado por `model.array`);
  - capacidade, janelas de tempo, horizonte;
  - função objetivo lex *(lateness, nº veículos, custo)*;
  - matriz de custos com fechamento métrico (Floyd-Warshall sobre
    distâncias euclidianas arredondadas), idêntica ao usado pelo solver
    Julia do amigo;
  - matriz de tempos lida diretamente do bloco *Travel time matrix*.
- `rodar_hexaly.ps1` &mdash; batch sequencial em PowerShell que percorre
  as 60 instâncias, fixa **TL = 7200 s** (n ≤ 60) e **TL = 21600 s**
  (n = 120) — mesma referência do artigo Özbaygın et al. (2017) — e
  consolida `_summary.csv` em `logs_hexaly/`.

## Pré-requisitos

- Hexaly 14.5 instalado em `C:\hexaly_14_5` (com licença válida em
  `license.dat`).
- Python 3.10+ no `PATH` (testado com 3.14.0).

O batch já cuida de:

```powershell
$env:PYTHONPATH      = "$HexalyDir\bin\python"
$env:HX_LICENSE_PATH = "$HexalyDir\license.dat"
```

## Uso rápido

Smoke test de 60 s por instância (todas as 60):
```powershell
cd VRPRDL_VRPSolver_\hexaly
.\rodar_hexaly.ps1 -SmokeTimeLimit 60
```

Bateria completa (TL conforme o artigo):
```powershell
.\rodar_hexaly.ps1
```

Recuperar de uma execução interrompida (pula `.sol` já existentes):
```powershell
.\rodar_hexaly.ps1 -SkipExisting
```

Apenas as 40 originais ou apenas as 20 adicionais:
```powershell
.\rodar_hexaly.ps1 -OnlyOriginal
.\rodar_hexaly.ps1 -OnlyExtra
```

## Saídas

- `logs_hexaly/<instance>.log` &mdash; log bruto do Hexaly com a curva
  *anytime* da função objetivo.
- `sols_hexaly/<instance>.sol` &mdash; cabeçalho `nb_trucks total_cost`
  e uma rota por linha (IDs globais de localização do arquivo de
  instância).
- `logs_hexaly/_summary.csv` &mdash; tabela consolidada para as
  comparações posteriores com a Tabela 3 (originais) e Tabela 7
  (adicionais) do artigo de referência.

## Tempo total estimado (sequencial)

| família | TL/inst | nº inst | total       |
| --- | --- | --- | --- |
| originais (n ≤ 60)    | 7200 s   | 40 | ~80 h |
| adicionais (n = 120)  | 21600 s  | 20 | ~120 h |
| **bateria completa**  |          | 60 | **~200 h** |

Para um *smoke run* com `-SmokeTimeLimit 600`: ~10 h totais.
