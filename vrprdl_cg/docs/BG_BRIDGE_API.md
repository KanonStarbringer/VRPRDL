# BG Pricing Bridge API (C ABI)

Este documento especifica a API C usada pelo `vrprdl_cg` para chamar o motor
de pricing baseado em `bucket-graph-spprc` via `ccall` no Julia.

## Objetivo

- Expor ABI estavel (C) para evitar acoplamento de templates C++ no Julia.
- Receber um grafo de pricing (vertices, arcos, recursos, custos reduzidos).
- Retornar caminhos candidatos com custo reduzido negativo.

## Header

Arquivo: `bg_bridge/include/bg_pricing_c.h`

### Struct de entrada

- `BGPInput`
  - `n_vertices`, `source`, `sink`
  - `n_arcs`, `arc_from`, `arc_to`, `arc_base_cost`
  - `arc_time`, `arc_load` (2 recursos principais)
  - `vertex_time_lb`, `vertex_time_ub`
  - `vehicle_capacity`
  - `vertex_customer`, `vertex_location`
  - parametros (`theta`, `max_paths`, `bidirectional`, `parallel_bidir`)

### Struct de saida

- `BGPResult`
  - `status` (`0` sucesso)
  - `n_paths`
  - `total_vertices`
  - `path_offsets` (tamanho `n_paths + 1`)
  - `path_vertex_ids` (tamanho `total_vertices`)
  - `path_reduced_costs` (tamanho `n_paths`)
  - `path_original_costs` (tamanho `n_paths`)

### Funcoes C

- `int bgp_solve(const BGPInput* in, BGPResult* out);`
- `void bgp_free_result(BGPResult* out);`
- `const char* bgp_last_error(void);`
- `int bgp_abi_version(void);`

## Convencoes

- Memoria de saida e alocada no C++; Julia chama `bgp_free_result`.
- Indices de vertices/arcos na API C sao **0-based**.
- `vertex_customer[v] = 0` para source/sink.
- `vertex_location[v] = 0` para source/sink.

## Mapeamento Julia (`ccall`)

- O adaptador Julia converte arrays para buffers contiguos (`Vector{Cint}`,
  `Vector{Cdouble}`) e passa ponteiros para `BGPInput`.
- O retorno (`BGPResult`) e lido como fatias:
  - caminho `k` = `path_vertex_ids[path_offsets[k] : path_offsets[k+1]-1]`
- Os vertices retornados sao convertidos para `(customer_seq, location_seq)`,
  validados por `build_route` e transformados em `Route`.

## Observacao de modelagem (piloto)

- O motor BG resolve SPPRC com recursos tempo/capacidade.
- Restricao de visita unica por cliente (clusters VRPRDL) e aplicada no
  adaptador Julia na reconstrucao da rota (descartando caminhos com cliente
  repetido), mantendo o piloto seguro sem alterar o master.

## Executavel auxiliar `bgp_solve_once`

Gerado pelo mesmo `CMake` da shared library. Entrada/saida em texto ASCII
(documentado no cabecalho de `bg_bridge/tools/bgp_solve_once.cpp`). O Julia
pode invoca-lo num subprocesso com `timeout` (GNU coreutils) quando
`max_solve_seconds > 0` em `BucketPricingConfig`, para permitir encerramento
externo do processo nativo sem bloquear indefinidamente o interpretador Julia.
