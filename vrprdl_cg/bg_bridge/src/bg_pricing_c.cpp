#include "bg_pricing_c.h"

#include <bgspprc/solver.h>

#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <string>
#include <vector>

namespace {
thread_local std::string g_last_error;

void set_error(const char* msg) {
    g_last_error = msg ? msg : "unknown error";
}

bool validate_input(const BGPInput* in) {
    if (!in) {
        set_error("BGPInput nulo");
        return false;
    }
    if (in->n_vertices <= 1 || in->n_arcs <= 0) {
        set_error("n_vertices/n_arcs invalidos");
        return false;
    }
    if (!in->arc_from || !in->arc_to || !in->arc_base_cost) {
        set_error("ponteiros de arcos invalidos");
        return false;
    }
    if (!in->arc_time || !in->arc_load || !in->vertex_time_lb || !in->vertex_time_ub) {
        set_error("ponteiros de recursos invalidos");
        return false;
    }
    if (in->source < 0 || in->source >= in->n_vertices || in->sink < 0 ||
        in->sink >= in->n_vertices) {
        set_error("source/sink fora de faixa");
        return false;
    }
    return true;
}
}  // namespace

int bgp_abi_version(void) {
    return 1;
}

const char* bgp_last_error(void) {
    return g_last_error.c_str();
}

int bgp_solve(const BGPInput* in, BGPResult* out) {
    if (!out) {
        set_error("BGPResult nulo");
        return 2;
    }
    std::memset(out, 0, sizeof(BGPResult));

    if (!validate_input(in)) {
        out->status = 2;
        return out->status;
    }

    try {
        using namespace bgspprc;

        const double* arc_res_arr[2] = {in->arc_time, in->arc_load};

        std::vector<double> cap_lb(static_cast<size_t>(in->n_vertices), 0.0);
        std::vector<double> cap_ub(static_cast<size_t>(in->n_vertices), in->vehicle_capacity);
        const double* v_lb_arr[2] = {in->vertex_time_lb, cap_lb.data()};
        const double* v_ub_arr[2] = {in->vertex_time_ub, cap_ub.data()};

        ProblemView pv;
        pv.n_vertices = in->n_vertices;
        pv.source = in->source;
        pv.sink = in->sink;
        pv.n_arcs = in->n_arcs;
        pv.arc_from = in->arc_from;
        pv.arc_to = in->arc_to;
        pv.arc_base_cost = in->arc_base_cost;
        pv.n_resources = 2;
        pv.n_main_resources = 2;
        pv.arc_resource = arc_res_arr;
        pv.vertex_lb = v_lb_arr;
        pv.vertex_ub = v_ub_arr;

        Solver<EmptyPack> solver(
            pv, EmptyPack{},
            {.bucket_steps = {10.0, 1.0},
             .bidirectional = in->bidirectional != 0,
             .parallel_bidir = in->parallel_bidir != 0,
             .max_paths = in->max_paths,
             .theta = in->theta});
        solver.set_stage(Stage::Exact);
        solver.build();

        auto paths = solver.solve();

        int n_paths = static_cast<int>(paths.size());
        int total_vertices = 0;
        for (const auto& p : paths) {
            total_vertices += static_cast<int>(p.vertices.size());
        }

        out->n_paths = n_paths;
        out->total_vertices = total_vertices;
        out->status = 0;

        out->path_offsets = new int[static_cast<size_t>(n_paths) + 1];
        out->path_vertex_ids = new int[static_cast<size_t>(total_vertices)];
        out->path_reduced_costs = new double[static_cast<size_t>(n_paths)];
        out->path_original_costs = new double[static_cast<size_t>(n_paths)];

        int pos = 0;
        out->path_offsets[0] = 0;
        for (int i = 0; i < n_paths; ++i) {
            const auto& p = paths[static_cast<size_t>(i)];
            out->path_reduced_costs[i] = p.reduced_cost;
            out->path_original_costs[i] = p.original_cost;
            for (int v : p.vertices) {
                out->path_vertex_ids[pos++] = v;
            }
            out->path_offsets[i + 1] = pos;
        }
        return 0;
    } catch (const std::bad_alloc&) {
        set_error("falha de alocacao");
        bgp_free_result(out);
        out->status = 3;
        return out->status;
    } catch (const std::exception& e) {
        set_error(e.what());
        bgp_free_result(out);
        out->status = 4;
        return out->status;
    } catch (...) {
        set_error("erro desconhecido no solver");
        bgp_free_result(out);
        out->status = 5;
        return out->status;
    }
}

void bgp_free_result(BGPResult* out) {
    if (!out) {
        return;
    }
    delete[] out->path_offsets;
    delete[] out->path_vertex_ids;
    delete[] out->path_reduced_costs;
    delete[] out->path_original_costs;
    out->path_offsets = nullptr;
    out->path_vertex_ids = nullptr;
    out->path_reduced_costs = nullptr;
    out->path_original_costs = nullptr;
    out->n_paths = 0;
    out->total_vertices = 0;
}
