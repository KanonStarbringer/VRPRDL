# VRPRDL no VRPSolver (adaptação correta)

Este pacote adapta a demo do CVRP para o **VRPRDL** usando:
- leitura do formato `General parameters / Customer schedules / Location coordinates / Travel time matrix`;
- cobertura por **cliente**;
- múltiplas localizações por cliente tratadas como **packing sets de vértices**;
- recurso principal de **capacidade**;
- recurso principal de **tempo** com janelas em cada localização;
- depósitos de origem e destino separados (`source != sink`), conforme o arquivo da instância.

## Rodando

```bash
cd VRPRDL_VRPSolver_Corrected
export BAPCOD_RCSP_LIB=/caminho/para/libbapcod-shared
export LD_LIBRARY_PATH=$(dirname "$BAPCOD_RCSP_LIB"):$LD_LIBRARY_PATH
julia src/run.jl data_vrprdl/instance_0-triangle.txt -c config/VRPRDL.cfg -m 1 -M 15 -o sol_instance_0.txt
```

## Observações de modelagem

- cada **localização** é um vértice do grafo de pricing;
- cada **cliente** é um packing set contendo todas as suas localizações;
- a restrição de atendimento é:
  `sum(x[a] for a in A if head(a) ∈ N_c) == 1` para todo cliente real `c`;
- o recurso de tempo usa consumo `t_ij` e bounds `[e_i, l_i]` na chegada a cada vértice;
- o recurso de capacidade consome `demand(j)` ao entrar em `j`;
- a função objetivo usa **custo geométrico** (distância euclidiana arredondada com fechamento métrico), separado do **tempo de viagem** do arquivo;
- o pré-processamento elimina nós e arcos obviamente inviáveis conforme as regras do artigo de Ozbaygin et al. (2017).
