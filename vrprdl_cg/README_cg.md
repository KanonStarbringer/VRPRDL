# VRPRDL — Column Generation com VRPSolver como gerador externo

Framework de **Column Generation (CG)** para o *Vehicle Routing Problem
with Roaming Delivery Locations* (VRPRDL) — seguindo a formulação de
Özbayğın et al. (2017) — onde o **Master Problem** está em
`JuMP + CPLEX` e o **pool de rotas candidatas** é alimentado pelo
**VRPSolver** (aplicado sobre a projeção CVRP da instância).

O VRPSolver aqui **não é o pricer exato** do VRPRDL; ele entra apenas
como **gerador externo** de *backbones* (sequências de clientes). Um
**expander** então transforma cada backbone em uma rota VRPRDL
viável, escolhendo a melhor localização por cliente respeitando as
janelas de tempo.

---

## Visão geral

```text
┌─────────────────────────────────────────────────────┐
│                   CG LOOP (Julia)                   │
│                                                     │
│   ┌─────────────────┐     π_c      ┌────────────┐   │
│   │  RMP (Master)   │ ───────────▶ │  PRICING   │   │
│   │  JuMP + CPLEX   │              │ (filtro)   │   │
│   │  Set Partition. │ ◀──────────  │            │   │
│   └─────────────────┘  rotas r     └─────┬──────┘   │
└──────────────────────────────────────────┼──────────┘
                                           │
               ┌───────────────────────────┴──────────────────┐
               │       POOL de rotas candidatas VRPRDL        │
               │                                              │
               │  (1) backbones = sequências de clientes      │
               │       lidas dos logs do VRPSolver (CVRP)     │
               │                                              │
               │  (2) expander: para cada backbone, DP com    │
               │       labeling para escolher 1 local por     │
               │       cliente respeitando janelas (+ wait    │
               │       penalizado por α).                     │
               │                                              │
               │  (3) variantes locais (reverse, 2-swap) +    │
               │       singletons → garantia de viabilidade.  │
               └──────────────────────────────────────────────┘
```

---

## Estrutura

```text
vrprdl_cg/
├── bg_bridge/                     # bridge C++ (ABI C) para bucket-graph-spprc
├── Project.toml
├── bootstrap.jl                  # instala/precompila deps (1x)
├── run_cg.jl                     # entry point CLI (single instance)
├── run_batch.jl                  # roda TODAS numa única sessão Julia
├── rodar_vrprdl_cg_batch.sh      # batch WSL (40 instâncias)
├── logs_cg/                      # logs gerados pela CG (+ _summary.csv)
├── README_cg.md
└── src/
    ├── instance.jl               # loader do JSON + estruturas
    ├── route.jl                  # struct Route + validação
    ├── expander.jl               # DP labeling com Pareto (top-1)
    ├── vrpsolver_bridge.jl       # parser OFFLINE dos logs VRPSolver
    ├── master.jl                 # RMP em JuMP + CPLEX
    ├── pricing.jl                # custo reduzido + filtro do pool (fallback)
    ├── pricing_bucket.jl         # pricing online via bridge C++ (bucket graph)
    └── cg_loop.jl                # orquestração da CG
```

### Build da bridge C++ (bucket graph)

No WSL (recomendado, gera `libbg_pricing_bridge.so`):

```bash
cd vrprdl_cg
git clone https://github.com/spoorendonk/bucket-graph-spprc.git third_party/bucket-graph-spprc
cmake -S bg_bridge -B bg_bridge/build
cmake --build bg_bridge/build -j
```

O mesmo build gera o executável `bgp_solve_once` no diretório `bg_bridge/build/`
(ao lado de `libbg_pricing_bridge.so`). Ele é usado quando `max_solve_seconds > 0`
em `BucketPricingConfig`, em conjunto com o utilitário GNU `timeout` no `PATH`,
para que o kernel possa encerrar o pricing se o SPPR-C demorar demais.

> No Windows puro, para usar `pricing_mode=bucket_graph`, é necessário compilar
> uma DLL equivalente e apontar `BGP_LIB_PATH` para ela.

---

## Formulação matemática

### RMP (Set Partitioning)

$$
\min \sum_{r \in R} c_r \lambda_r
\quad \text{s.a.} \quad
\sum_{r \in R} a_{c,r} \lambda_r = 1 \quad \forall c \in \{1,\dots,n\},
\quad \lambda_r \geq 0 \text{ (LP) / } \in \{0,1\} \text{ (IP)}
$$

onde:

- $R$ é o **pool** atual de rotas VRPRDL já inseridas como colunas
- $c_r$ é o custo da rota $r$ (tempo de viagem + $\alpha\cdot$espera)
- $a_{c,r} = 1$ se a rota $r$ visita o cliente $c$

### Pricing heurístico

A cada iteração, dados os duais $\pi_c$ das restrições de cobertura,
o custo reduzido de uma rota $r$ já no pool (mas ainda não no RMP) é

$$
\bar{c}_r = c_r - \sum_{c \in r} \pi_c
$$

e inserimos todas as rotas do pool com $\bar{c}_r < -\varepsilon$
(até um máximo por iteração). A CG termina quando nenhuma rota do
pool tem custo reduzido negativo.

> **Observação.** Como o pool é finito, este é um *pricing
> heurístico*. Ele converge para o ótimo da CG *restrito ao pool*,
> não para o ótimo da CG com todas as rotas possíveis do VRPRDL.
> A substituição futura é trocar `pricing.jl` por um RCSP exato
> (ou chamar o VRPSolver no modo online com custos perturbados
> pelos duais).

---

## Pipeline completo

```text
(já existente) TXT ──► JSON ──► VRP (projeção CVRP)
                                       │
                                       ▼
                           VRPSolver (logs_vrp_convertidos/)
                                       │
                                       ▼  ← este framework começa aqui
                          parse_vrpsolver_log (offline)
                                       │
                                       ▼
                          expand_backbone  (por cliente: locais + TW)
                                       │
                                       ▼
                          pool = rotas VRPRDL viáveis
                                       │
                                       ▼
                          CG  = RMP(JuMP+CPLEX)  ⇄  pricing(pool, π)
                                       │
                                       ▼
                          MIP final sobre o pool expandido
```

---

## Como usar

### 1. Bootstrap (instala/precompila dependências) — uma vez só

```bash
cd vrprdl_cg
julia --project=. bootstrap.jl
```

> Precisa ter CPLEX instalado e `CPLEX.jl` configurado (variáveis de
> ambiente `CPLEX_STUDIO_BINARIES` ou `CPLEX_STUDIO_DIR` antes do
> primeiro `Pkg.build`).

### 2. Rodar uma única instância (debug)

```bash
julia --project=. run_cg.jl \
    ../VRPRDL-triangle/json_convertidos/instance_0-triangle.json \
    ../VRPRDL-triangle/logs_vrptw_convertidos/instance_0-triangle.log \
    0.0 \
    pool
```

Por padrão o script procura o log do VRPSolver em
`../VRPRDL-triangle/logs_vrp_convertidos/<nome>.log`.

Você pode também passar explicitamente:

```bash
julia --project=. run_cg.jl \
    caminho/instance.json \
    caminho/log.log \
    1.0 \
    bucket_graph
```

`pricing_mode`:
- `pool` (padrão): pricing heurístico no pool pré-gerado.
- `bucket_graph`: pricing online via `bucket-graph-spprc` (bridge C++).

### Branch-and-Price (Özbayğın et al. 2017, Sec. 3.3) — *hooks*

O ficheiro `src/bp_branching.jl` define `BPNodeState` (conjunto de arcos
`(location_id_from, location_id_to)` proibidos), filtragem de rotas,
agregação de fluxo `x_ij` a partir do LP do RMP, escolha de arco **CB**,
e ramos `bp_child_forbid_arc!` / `bp_child_force_arc!` alinhados ao artigo.
Em `CGConfig`, o campo opcional `bp_node` (default `nothing`) aplica esse
estado na raiz: filtra o pool inicial e repassa proibições ao
`build_bg_graph` durante o pricing em `bucket_graph`.

Há também um *entry point* experimental `run_bp.jl` que monta um esqueleto
funcional de árvore B&P (DFS, branch CB em arcos fracionários, filhos
`forbid/force`, CG por nó e UB por MIP do RMP do nó):

```bash
julia --project=. run_bp.jl caminho/instance.json caminho/log.log 0.0
```

**Limite de tempo no `bucket_graph`.** O `ccall` ao solver nativo bloqueia o
processo Julia até o fim da chamada. Para evitar travamentos em instâncias
grandes, use `max_solve_seconds > 0` em `BucketPricingConfig` (campo
`bg_cfg` de `CGConfig`): o problema é escrito em arquivo temporário e o Julia
invoca `bgp_solve_once` sob `timeout` (GNU coreutils; típico em Linux/WSL).
Se o limite for atingido, a iteração de pricing devolve zero colunas e a CG
segue. Sem `timeout` no `PATH` ou sem o executável `bgp_solve_once` ao lado da
biblioteca, o código volta ao `ccall` in-process (sem limite duro) e emite
avisos quando `verbose=true`. O script `run_cg.jl` aceita um quinto argumento
opcional com esse limite em segundos (ex.: `120`).

### 3. Rodar todas as 40 em batch — fluxo CVRP (original)

```bash
dos2unix rodar_vrprdl_cg_batch.sh
chmod +x rodar_vrprdl_cg_batch.sh
./rodar_vrprdl_cg_batch.sh 0.0 pool
./rodar_vrprdl_cg_batch.sh 0.0 bucket_graph
```

O script faz em sequência:

1. `bootstrap.jl` — instala/precompila (se já instalado, é rápido)
2. `run_batch.jl` — processa TODAS as instâncias **numa única sessão Julia**
   (evita pagar ~15s de precompile do JuMP/CPLEX a cada instância)

Saídas em `vrprdl_cg/logs_cg/`:

- `<instance>.log`   — log completo da CG de cada instância
- `_bootstrap.log`   — log do bootstrap
- `_batch.log`       — log do batch (progresso resumido)
- `_summary.csv`     — uma linha por instância (para análises agregadas)

> **Observação importante.** Com backbones vindos do CVRP, a
> projeção **descarta as janelas de tempo**, o que leva a pool
> quase inteiramente de *singletons* (rota 1 cliente). Se isso
> acontecer, use o fluxo VRPTW abaixo.

---

### 4. Rodar todas as 40 em batch — fluxo VRPTW (recomendado)

Troca a projeção CVRP por uma projeção **VRPTW** (formato Solomon),
rodada pelo demo `~/VRPSolver/VRPSolverDemos/other/VRPTW/`. Os
backbones passam a respeitar uma janela por cliente (a "mais larga"
entre as candidatas), de modo que o expander no VRPRDL encontra
muito mais rotas viáveis.

**Passo 1.** Converter JSONs para formato Solomon (na pasta
`instancias_turco/`):

```bash
julia ../converter_jsons_para_vrptw.jl
```

Gera arquivos em `VRPRDL-triangle/vrptw_convertidos/*.txt`.

**Passo 2.** Rodar o demo VRPTW do VRPSolver nas 40 instâncias:

```bash
cd ..
dos2unix rodar_vrps_vrptw_turco.sh
chmod +x rodar_vrps_vrptw_turco.sh
./rodar_vrps_vrptw_turco.sh
```

Gera logs em `VRPRDL-triangle/logs_vrptw_convertidos/*.log`.

**Passo 3.** Rodar a CG apontando para esses logs:

```bash
cd vrprdl_cg
dos2unix rodar_vrprdl_cg_batch_vrptw.sh
chmod +x rodar_vrprdl_cg_batch_vrptw.sh
./rodar_vrprdl_cg_batch_vrptw.sh 0.0 pool
./rodar_vrprdl_cg_batch_vrptw.sh 0.0 bucket_graph
```

Saídas em `vrprdl_cg/logs_cg_vrptw/` (pasta separada da CVRP para
comparação).

**Esperado:** a coluna `iterations` do `_summary.csv` passa a ser
maior que 1, `vehicles` fica bem abaixo de `n_customers`, e o
objetivo MIP fica significativamente menor.

---

## Saída

No fim de cada rodada, o framework imprime:

```text
========================================
CG finalizado.
status MIP      : OPTIMAL
LP bound        : 812.00
MIP objetivo    : 812.00
veículos usados : 2
tempo total     : 3.47 s
========================================
Rotas selecionadas:
  Route #1  travel= 412  wait= 18  cost=412.00  demand=350
      customers: 1 4 7 10 12
      locations: 3 12 26 38 48
  Route #2  travel= 400  wait=  0  cost=400.00  demand=310
      customers: 2 3 5 6 8 9 11 13 14 15
      locations: 6 11 17 20 27 33 43 53 57 61

SUMMARY  status=OPTIMAL  LP=812.0  MIP=812.0  veh=2  cols=87  iters=8  time=3.47s
```

A linha `SUMMARY` é feita para ser grepada em análises agregadas.

---

## Decisões de modelagem

| Parâmetro       | Escolha padrão            | Observação                            |
|-----------------|---------------------------|---------------------------------------|
| Pricing         | filtro offline do pool    | substituível por RCSP exato no futuro |
| Expansão        | top-1 DP com labeling     | Pareto (custo, tempo) por local       |
| Espera no local | permitida, penalizada αw  | αw = 0 ⇒ Özbayğın puro                |
| Service time    | 0                         | padrão VRPRDL triangle                |
| Master          | Set Partitioning (=)      | `:cover` também disponível            |
| Artificiais     | big-M no LP; fixas 0 no IP| viabilidade do RMP antes do IP        |

---

## Limitações atuais

1. **Pool fixo pós-VRPSolver.** Só usa os backbones presentes nos
   logs já gerados, mais variantes locais (reverse + 2-swap) +
   singletons. Rotas com sequência *muito* diferente da ótima do CVRP
   projetado ficam fora do alcance.
2. **Pricing heurístico.** Explora apenas rotas já expandidas;
   não gera colunas "do zero" com base nos duais.
3. **Sem branch-and-price.** Resolve o IP diretamente sobre o pool
   final. Para instâncias com muitos clientes isso pode deixar um
   gap de integralidade.

---

## Próximos passos (roadmap)

- **Pricing exato (RCSP)** substituindo `pricing.jl` por labeling
  sobre o grafo completo de (cliente, local) com recursos de tempo
  e capacidade.
- **VRPSolver online com perturbação dos custos pelos duais.** Em
  cada iteração da CG, re-projetar o CVRP com custos
  $c'_{ij} = c_{ij} - \pi_i$ e chamar o VRPSolver para gerar novos
  backbones.
- **Branch-and-price** sobre $\lambda_r$ (ou sobre arcos
  originais, estilo Özbayğın).
- **Múltiplas expansões por backbone** (top-K via Yen/Eppstein
  sobre o grafo sequência×locais) para diversificar o pool
  sem precisar re-rodar o VRPSolver.

---

## Referências

- Özbayğın, G., et al. (2017). *A branch-and-price algorithm for the
  vehicle routing problem with roaming delivery locations.*
- Reyes, D., et al. (2017). *The Vehicle Routing Problem with
  Roaming Delivery Locations.*
- Sadykov, R., Uchoa, E., Pessoa, A. — BaPCod / VRPSolver.
