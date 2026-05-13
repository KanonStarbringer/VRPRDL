#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BGPInput {
    int n_vertices;
    int source;
    int sink;

    int n_arcs;
    const int* arc_from;            // [n_arcs]
    const int* arc_to;              // [n_arcs]
    const double* arc_base_cost;    // [n_arcs]

    // Recursos principais
    const double* arc_time;         // [n_arcs]
    const double* arc_load;         // [n_arcs]
    const double* vertex_time_lb;   // [n_vertices]
    const double* vertex_time_ub;   // [n_vertices]
    double vehicle_capacity;        // limite superior da capacidade

    // Mapeamento vertice -> cliente/local (0 para source/sink)
    const int* vertex_customer;     // [n_vertices]
    const int* vertex_location;     // [n_vertices]

    // Parametros do solver
    double theta;                   // threshold de custo reduzido
    int max_paths;                  // 0 = todos
    int bidirectional;              // bool int
    int parallel_bidir;             // bool int
} BGPInput;

typedef struct BGPResult {
    int status;                     // 0=ok; !=0 erro
    int n_paths;
    int total_vertices;

    int* path_offsets;              // [n_paths + 1]
    int* path_vertex_ids;           // [total_vertices]
    double* path_reduced_costs;     // [n_paths]
    double* path_original_costs;    // [n_paths]
} BGPResult;

int bgp_abi_version(void);
const char* bgp_last_error(void);
int bgp_solve(const BGPInput* in, BGPResult* out);
void bgp_free_result(BGPResult* out);

#ifdef __cplusplus
}
#endif
