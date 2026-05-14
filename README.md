# Problema de Roteamento de Veículos com Localidades Móveis - VRPRDL (Özbaygın et al., 2017)

Repositório com **instâncias** do *Vehicle Routing Problem with Roaming Delivery Locations* (VRPRDL), conversores entre formatos, scripts para acoplar ao **VRPSolver** e o subprojeto **Julia** `vrprdl_cg` (geração de colunas com **JuMP + CPLEX**).

Referência principal: **Özbaygın, G., Karasan, O. E., Savelsbergh, M., Yaman, H.** — *A branch-and-price algorithm for the vehicle routing problem with roaming delivery locations*, **Transportation Research Part B**, 100 (2017), 115–137. DOI: [10.1016/j.trb.2017.02.003](https://doi.org/10.1016/j.trb.2017.02.003).

Uma cópia local do artigo está em `ozbaygin2017.pdf` (somente para uso acadêmico pessoal; redistribuição pode estar sujeita à licença da Elsevier).

---

## Formulação matemática (VRPRDL)

Seguindo a Seção 2 de Özbaygın et al. (2017), seja um grafo direcionado completo $G=(N,A)$, com $N=\{0,1,\ldots,n\}$, nó $(0) = \text{depósito}$, arco $(i,j)\in A$ com tempo de viagem $t_{ij}$ e custo $w_{ij}$ (ambos satisfazem desigualdade triangular). Conjunto de clientes $C$; cada cliente $c\in C$ tem demanda $d_c$ e um conjunto de localizações possíveis $N_c\subset N$ (disjuntos entre clientes após duplicação de nós). Cada local $i\in N_c$ tem janela de tempo $[e_i,\ell_i]$ (não sobrepostas dentro do mesmo cliente). $c(i)$ denota o cliente do nó $i$, com $c(0)=0$. Frota homogênea de até $m$ veículos, capacidade $Q$, horizonte $T$.

### Modelo em arcos (MIP)

Variáveis: $x_{ij}\in\{0,1\}$ uso do arco $(i,j)$; $s_i$ instante de chegada em $i$; $y_i$ carga acumulada ao sair de $i$. Com $\delta^-(i)$, $\delta^+(i)$ conjuntos de arcos entrando/saindo de $i$, e $x(A')=\sum_{(i,j)\in A'} x_{ij}$:


```math
\min \sum_{(i,j)\in A} w_{ij}\,x_{ij}
```

sujeito a (notação do artigo):

1. **Fluxo:** $x(\delta^-(i)) - x(\delta^+(i)) = 0$ para todo $i\in N$.
2. **Exatamente uma visita por cliente:** $\sum_{i\in N_c} x(\delta^-(i)) = 1$ para todo $c\in C$.
3. **Limite de veículos:** $x(\delta^+(0)) \le m$.
4. **Tempos (MTZ-style com big-M em janelas):**  
   $s_j \ge s_i + t_{ij} x_{ij} + (e_j - \ell_i)(1-x_{ij})$ para todo $(i,j)\in A$, $j\neq 0$.
5. **Retorno ao depósito:** $s_i + t_{i0} x_{i0} \le \min\{\ell_i + t_{i0},\, T\}$ para todo $(i,0)\in A$.
6. **Janelas:** $e_i \le s_i \le \ell_i$ para todo $i\in N$.
7. **Capacidade (acoplada ao fluxo):**  
   $y_j \ge y_i + d_{c(j)} - Q(1-x_{ij})$ para todo $(i,j)\in A\), \(j\neq 0$.
8. **Limites de carga:** $d_{c(i)} \le y_i \le Q$ para todo $i\in N$.

O objetivo é minimizar o custo total das rotas respeitando capacidade, duração e janelas, visitando **exatamente um** nó de cada \(N_c\).

### Formulação por conjuntos (Dantzig–Wolfe)

Seja \(R\) o conjunto de **rotas factíveis** (sequências de visitas respeitando as restrições acima), \(w_r\) o custo da rota \(r\in R\), e \(a_{ir}\in\{0,1\}\) indicando se o nó \(i\in N\) é visitado na rota \(r\). Com variáveis \(z_r\in\mathbb{Z}_+\) (número de vezes que a rota \(r\) é usada):

\[
\min \sum_{r\in R} w_r\, z_r
\]

\[
\sum_{r\in R}\sum_{i\in N_c} a_{ir}\, z_r = 1 \quad \forall c\in C
\]

\[
\sum_{r\in R} z_r \le m
\]

\[
z_r \in \mathbb{Z}_+ \quad \forall r\in R
\]

O artigo observa que, sob custos de arco que satisfazem a desigualdade triangular, as igualdades de cobertura podem ser relaxadas para \(\ge 1\) (set covering), tornando os duais das restrições de cliente **não negativos** e, em geral, acelerando a geração de colunas.

O **problema de pricing** busca colunas (rotas) com **custo reduzido negativo** em relação aos duais \(\lambda^*\) do master restrito; ver equações (13)–(14) do artigo.

---

## O que há neste repositório

| Caminho | Conteúdo |
|--------|-----------|
| `VRPRDL-triangle/` | Instâncias no formato original (txt), JSON, projeções VRP/VRPTW/CVRP, logs de execução quando gerados. |
| `additional_instances/` | Instâncias adicionais (segundo conjunto do artigo / variantes). |
| `vrprdl_cg/` | Projeto Julia: **column generation** com master em JuMP+CPLEX e pricing via pool (logs VRPSolver) e/ou *bucket graph* (C++, biblioteca [bucket-graph-spprc](https://github.com/spoorendonk/bucket-graph-spprc) incluída em `third_party/`). |
| `converter_*.jl` | Conversão entre txt ↔ JSON ↔ formatos para demos do VRPSolver. |
| `rodar_*.sh` | *Batch* em Bash (pensado para **WSL/Linux**): VRPSolver sobre `.vrp`, CVRP padrão, VRPTW, etc. |
| `instance_format_description.txt` | Descrição do formato txt das instâncias Reyes/Özbaygın. |
| `plotar_rotas_turco_batch.py` | Utilitário Python para visualização de rotas (dependências próprias). |

Documentação complementar do CG: `vrprdl_cg/README_cg.md`.

---

## Pré-requisitos

1. **[Julia](https://julialang.org/)** (versão compatível com o `Manifest.toml` do projeto; recomenda-se Julia estável recente).
2. **IBM [CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio)** com licença válida e pacote `CPLEX.jl` funcional. Variáveis de ambiente típicas (Windows): `CPLEX_STUDIO_DIR` ou `CPLEX_STUDIO_BINARIES`; em Linux, `CPLEX_STUDIO_BINARIES` apontando para a pasta `bin/x86-64_linux` (ou equivalente).
3. Opcional — pipeline completo com **VRPSolver**: clone/localização do repositório **VRPSolverDemos** (os scripts assumem por defeito `~/VRPSolver/VRPSolverDemos` e `JULIA_BIN="$HOME/.juliaup/bin/julia"`). Ajuste essas variáveis no seu ambiente se necessário:
   - `export JULIA_BIN="$(command -v julia)"`  
   - `export VRP_DEMOS_DIR="/caminho/para/VRPSolverDemos"` (e equivalentes para demos VRPTW nos scripts).
4. Opcional — **pricing** com *bucket graph*: compilador C++17, **CMake**, e dependência `bucket-graph-spprc` (ver `vrprdl_cg/README_cg.md`).

---

## Passo a passo rápido (somente CG Julia + CPLEX)

A CG usa instâncias em **JSON** em `VRPRDL-triangle/json_convertidos/` e, por defeito, procura logs do VRPSolver em `VRPRDL-triangle/logs_vrp_convertidos/` com o mesmo nome base (ex.: `instance_0-triangle.json` ↔ `instance_0-triangle.log`).

```bash
# Na raiz do repositório (opcional: regenerar JSON a partir dos .txt)
julia converter_instancias_turco_para_json.jl

cd vrprdl_cg
julia --project=. bootstrap.jl                                 # 1×: instantiate + precompile
julia --project=. run_cg.jl ../VRPRDL-triangle/json_convertidos/instance_0-triangle.json
```

Argumentos extras de `run_cg.jl`: veja o cabeçalho de `vrprdl_cg/run_cg.jl` (log opcional, `alpha_wait`, `pricing_mode`, tempo máximo do pricing em modo *bucket*).

Batch (WSL), após ter logs VRPSolver:

```bash
cd vrprdl_cg
dos2unix rodar_vrprdl_cg_batch.sh
chmod +x rodar_vrprdl_cg_batch.sh
./rodar_vrprdl_cg_batch.sh [alpha_wait] [pricing_mode]
```

---

## Gerar JSON / projeções e rodar o VRPSolver

Os scripts `rodar_*.sh` na raiz usam caminhos **relativos à pasta do repositório** (não dependem mais do caminho absoluto da máquina original). Ajuste apenas `VRP_DEMOS_DIR`, `JULIA_BIN` e clones do VRPSolver conforme a sua instalação.

Exemplos:

- `rodar_vrps_turco.sh` — roda o demo CVRP clássico sobre `.vrp` em `VRPRDL-triangle/vrp_convertidos/`.
- `rodar_vrps_cvrp_padrao_turco.sh` — instâncias CVRP padrão + consolidação `_summary.csv`.
- `rodar_vrps_vrptw_turco.sh` / `rodar_vrps_vrptw_padrao_turco.sh` — variantes VRPTW.

Ordem típica de trabalho:

1. Converter instâncias txt → JSON: `julia converter_instancias_turco_para_json.jl` (executar na raiz do repositório).
2. Gerar `.vrp` ou outros formatos: `julia converter_jsons_para_vrp.jl`, `converter_jsons_para_cvrp_padrao.jl`, etc.
3. Executar o VRPSolver via scripts `rodar_*.sh` ou manualmente dentro de `VRPSolverDemos`.
4. Opcionalmente rodar `vrprdl_cg` sobre JSON + logs.

---

## Publicar no GitHub (push)

Na máquina onde o **Git** está instalado e autenticado (PAT, SSH ou GitHub Desktop):

```bash
cd /caminho/para/instancias_turco
git init -b main          # se ainda não for um repositório
git remote add origin https://github.com/SEU_USUARIO/SEU_REPO.git
git add -A
git commit -m "Initial commit: instâncias VRPRDL, conversores e vrprdl_cg"
git push -u origin main
```

Se o GitHub CLI (`gh`) estiver instalado e autenticado: `gh repo create SEU_REPO --public --source=. --remote=origin --push`.

**Neste ambiente** o comando `gh` não estava disponível e não havia `GITHUB_TOKEN` configurado; por isso o *push* final precisa ser feito na sua máquina (ou após instalar/autenticar o `gh`).

---

## Licença dos dados e do artigo

Instâncias derivadas da literatura (Reyes et al., 2016; Özbaygın et al., 2017) devem ser citadas nos trabalhos que as utilizarem. O PDF do artigo pode estar sujeito a direitos autorais da editora; use apenas conforme permitido pela sua instituição.
