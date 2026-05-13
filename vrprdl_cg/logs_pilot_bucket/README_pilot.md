# Piloto Bucket Graph (CG VRPRDL)

## Escopo executado

- `pool` (baseline): `logs_pilot_pool/_summary.csv` em 8 instancias.
- `bucket_graph`:
  - `logs_pilot_bucket_small/_summary.csv` com 5 instancias concluidas;
  - tentativa em `logs_pilot_bucket/_summary.csv` com travamento em `instance_20-triangle` (n=60).

## Resultado

- Qualidade: igual ao baseline nas instancias concluidas (mesmo `mip_obj`).
- Tempo: muito superior ao baseline no estado atual da modelagem de pricing.

Comparacao (instancias comuns concluidas):

| Instancia | Tempo pool (s) | Tempo bucket (s) | Fator bucket/pool |
|---|---:|---:|---:|
| instance_0-triangle | 3.86 | 65.03 | 16.85x |
| instance_1-triangle | 0.24 | 63.94 | 266.42x |
| instance_11-triangle | 0.12 | 117.32 | 977.67x |
| instance_12-triangle | 0.13 | 112.81 | 867.77x |
| instance_6-triangle | 0.09 | 135.97 | 1510.78x |

Medias:
- `time_s_pool = 0.888`
- `time_s_bg = 99.014`
- `bucket/pool = 727.90x`

## Decisao para batch 60

No-go para escalar para 60 instancias com `pricing_mode=bucket_graph` neste estado.

Motivo:
- comportamento instavel/lento ja no piloto;
- travamento observado em instancia n=60 (`instance_20-triangle`) antes de concluir o conjunto.

Recomendacao:
1. manter `pricing_mode=pool` como default de producao;
2. otimizar bridge/modelagem de pricing BG (reduzir grafo, limites de enumeracao, controle de tempo por chamada);
3. repetir piloto antes de novo batch de 60.
