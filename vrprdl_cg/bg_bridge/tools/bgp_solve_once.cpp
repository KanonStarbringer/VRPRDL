// One-shot worker: lê instancia de pricing em texto, chama bgp_solve, escreve resultado.
// Formato de entrada (ASCII):
//   BGP_TEXT_V1
//   n_vertices source sink n_arcs vehicle_capacity theta max_paths bidirectional parallel_bidir
//   n_arcs linhas: from to arc_base_cost arc_time arc_load
//   n_vertices linhas: time_lb time_ub vertex_customer vertex_location
//
// Formato de saida (ASCII):
//   OK status n_paths total_vertices
//   OFFSETS o0 o1 ... o_{n_paths}
//   PATH k len v0 v1 ...
//   ...
//   REDUCED r0 r1 ...
//   ORIGINAL o0 o1 ...

#include "bg_pricing_c.h"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static bool read_line(std::ifstream& in, std::string& line) {
    if (!std::getline(in, line)) {
        return false;
    }
    // strip CR
    if (!line.empty() && line.back() == '\r') {
        line.pop_back();
    }
    return true;
}

static int fail(const char* msg) {
    std::fprintf(stderr, "bgp_solve_once: %s\n", msg);
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        return fail("uso: bgp_solve_once <entrada.txt> <saida.txt>");
    }

    std::ifstream fin(argv[1]);
    if (!fin) {
        return fail("nao abriu entrada");
    }

    std::string line;
    if (!read_line(fin, line) || line != "BGP_TEXT_V1") {
        return fail("cabecalho invalido (esperado BGP_TEXT_V1)");
    }

    if (!read_line(fin, line)) {
        return fail("linha de parametros ausente");
    }

    int n_vertices = 0;
    int source = 0;
    int sink = 0;
    int n_arcs = 0;
    double vehicle_capacity = 0.0;
    double theta = 0.0;
    int max_paths = 0;
    int bidir = 0;
    int pardir = 0;

    {
        std::istringstream iss(line);
        if (!(iss >> n_vertices >> source >> sink >> n_arcs >> vehicle_capacity >> theta >>
              max_paths >> bidir >> pardir)) {
            return fail("parametros invalidos");
        }
    }

    if (n_vertices <= 0 || n_arcs < 0) {
        return fail("n_vertices/n_arcs invalidos");
    }

    std::vector<int> arc_from(static_cast<size_t>(n_arcs));
    std::vector<int> arc_to(static_cast<size_t>(n_arcs));
    std::vector<double> arc_base(static_cast<size_t>(n_arcs));
    std::vector<double> arc_time(static_cast<size_t>(n_arcs));
    std::vector<double> arc_load(static_cast<size_t>(n_arcs));

    for (int a = 0; a < n_arcs; ++a) {
        if (!read_line(fin, line)) {
            return fail("fim prematuro nos arcos");
        }
        std::istringstream iss(line);
        int f = 0;
        int t = 0;
        double bc = 0.0;
        double tm = 0.0;
        double ld = 0.0;
        if (!(iss >> f >> t >> bc >> tm >> ld)) {
            return fail("linha de arco invalida");
        }
        arc_from[static_cast<size_t>(a)] = f;
        arc_to[static_cast<size_t>(a)] = t;
        arc_base[static_cast<size_t>(a)] = bc;
        arc_time[static_cast<size_t>(a)] = tm;
        arc_load[static_cast<size_t>(a)] = ld;
    }

    std::vector<double> v_time_lb(static_cast<size_t>(n_vertices));
    std::vector<double> v_time_ub(static_cast<size_t>(n_vertices));
    std::vector<int> v_cust(static_cast<size_t>(n_vertices));
    std::vector<int> v_loc(static_cast<size_t>(n_vertices));

    for (int v = 0; v < n_vertices; ++v) {
        if (!read_line(fin, line)) {
            return fail("fim prematuro nos vertices");
        }
        std::istringstream iss(line);
        double lb = 0.0;
        double ub = 0.0;
        int c = 0;
        int l = 0;
        if (!(iss >> lb >> ub >> c >> l)) {
            return fail("linha de vertice invalida");
        }
        v_time_lb[static_cast<size_t>(v)] = lb;
        v_time_ub[static_cast<size_t>(v)] = ub;
        v_cust[static_cast<size_t>(v)] = c;
        v_loc[static_cast<size_t>(v)] = l;
    }

    BGPInput in{};
    in.n_vertices = n_vertices;
    in.source = source;
    in.sink = sink;
    in.n_arcs = n_arcs;
    in.arc_from = arc_from.data();
    in.arc_to = arc_to.data();
    in.arc_base_cost = arc_base.data();
    in.arc_time = arc_time.data();
    in.arc_load = arc_load.data();
    in.vertex_time_lb = v_time_lb.data();
    in.vertex_time_ub = v_time_ub.data();
    in.vehicle_capacity = vehicle_capacity;
    in.vertex_customer = v_cust.data();
    in.vertex_location = v_loc.data();
    in.theta = theta;
    in.max_paths = max_paths;
    in.bidirectional = bidir;
    in.parallel_bidir = pardir;

    BGPResult out{};
    int st = bgp_solve(&in, &out);

    std::ofstream fout(argv[2], std::ios::trunc);
    if (!fout) {
        bgp_free_result(&out);
        return fail("nao criou saida");
    }

    fout << "OK " << st << " " << out.n_paths << " " << out.total_vertices << "\n";
    fout << "OFFSETS";
    for (int i = 0; i <= out.n_paths; ++i) {
        fout << " " << out.path_offsets[i];
    }
    fout << "\n";

    for (int k = 0; k < out.n_paths; ++k) {
        int a = out.path_offsets[k];
        int b = out.path_offsets[k + 1];
        int len = b - a;
        fout << "PATH " << k << " " << len;
        for (int i = a; i < b; ++i) {
            fout << " " << out.path_vertex_ids[i];
        }
        fout << "\n";
    }

    fout << "REDUCED";
    for (int k = 0; k < out.n_paths; ++k) {
        fout << " " << out.path_reduced_costs[k];
    }
    fout << "\n";

    fout << "ORIGINAL";
    for (int k = 0; k < out.n_paths; ++k) {
        fout << " " << out.path_original_costs[k];
    }
    fout << "\n";

    bgp_free_result(&out);
    return (st == 0) ? 0 : 2;
}
