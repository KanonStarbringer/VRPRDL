"""VRPRDL resolvido com o Hexaly Optimizer 14.x.

Fluxo geral:

* leitura do mesmo formato usado pelo solver Julia do amigo
  (`General parameters` / `Customer schedules` / `Location coordinates` /
  `Travel time matrix`);
* fechamento métrico euclidiano (Floyd-Warshall) para a matriz de custos
  (idêntico ao usado no VRPSolver, função `_build_metric_closure_cost`);
* pré-processamento de localizações inviáveis
  (`t0i > li`  ou  `ei + ti0 > horizon`);
* modelo Hexaly:
    - uma `model.list(N)` por veículo, com `N = nº de clientes reais`;
    - `model.partition(...)` impede repetição de cliente entre veículos;
    - cada cliente `i` tem uma decisão inteira `loc_choice[i]`
      escolhendo um dos seus locais admissíveis;
    - capacidade, janelas de tempo (com tempo de viagem lido da matriz
      do arquivo) e horizonte são impostos como restrições;
    - função objetivo lexicográfica: (lateness, nº de veículos, custo).

Saída:
    <output>.sol  – cabeçalho `nb_trucks total_cost` seguido de uma linha
                    por veículo `loc_id loc_id ...` (nós visitados, sem
                    incluir source/sink).
"""

from __future__ import annotations

import argparse
import math
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple


# --------------------------------------------------------------------------- #
# 1) Leitura de instância (mesmo dialeto do solver Julia)
# --------------------------------------------------------------------------- #


def _strip_comment(line: str) -> str:
    idx = line.find("#")
    if idx >= 0:
        line = line[:idx]
    return line.strip()


def _parse_general(line: str) -> Tuple[int, int, float, float]:
    toks = line.split()
    if len(toks) != 4:
        raise ValueError(f"General parameters inválido: '{line}'")
    return int(toks[0]), int(toks[1]), float(toks[2]), float(toks[3])


_RX_STOP = None  # initialised lazily to avoid importing re at module load


def _parse_schedule(line: str) -> Tuple[int, float, List[Tuple[int, float, float]]]:
    import re

    global _RX_STOP
    if _RX_STOP is None:
        _RX_STOP = re.compile(
            r"(\d+)\s*\[\s*([-+]?\d+(?:\.\d+)?)\s*,\s*([-+]?\d+(?:\.\d+)?)\s*\]"
        )
    toks = line.split()
    cust = int(toks[0])
    demand = float(toks[1])
    stops = [
        (int(m.group(1)), float(m.group(2)), float(m.group(3)))
        for m in _RX_STOP.finditer(line)
    ]
    if not stops:
        raise ValueError(f"sem locais em Customer schedules: '{line}'")
    return cust, demand, stops


def _parse_coord(line: str) -> Tuple[int, float, float]:
    toks = line.split()
    return int(toks[0]), float(toks[1]), float(toks[2])


def _parse_tt(line: str) -> Tuple[int, int, float]:
    import re

    m = re.match(
        r"^\(\s*(\d+)\s*,\s*(\d+)\s*\)\s+([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)$",
        line,
    )
    if m is None:
        raise ValueError(f"linha de Travel time inválida: '{line}'")
    return int(m.group(1)), int(m.group(2)), float(m.group(3))


def _euclidean_rounded(xa: float, ya: float, xb: float, yb: float) -> float:
    return math.floor(math.hypot(xa - xb, ya - yb) + 0.5)


def _floyd_warshall(d: List[List[float]]) -> None:
    n = len(d)
    for k in range(n):
        dk = d[k]
        for i in range(n):
            di = d[i]
            dik = di[k]
            if dik == math.inf:
                continue
            for j in range(n):
                alt = dik + dk[j]
                if alt < di[j]:
                    di[j] = alt


class Instance:
    """Representação compacta de uma instância VRPRDL pronta para o Hexaly."""

    def __init__(self, path: str | os.PathLike) -> None:
        self.path = str(path)
        self.name = Path(path).stem

        section = "none"
        nb_cust = nb_loc = 0
        horizon = capacity = 0.0
        schedule: Dict[int, List[Tuple[int, float, float]]] = {}
        demand: Dict[int, float] = {}
        coords: Dict[int, Tuple[float, float]] = {}
        travel_time: Dict[Tuple[int, int], float] = {}

        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = _strip_comment(raw)
                if not line:
                    continue
                low = line.lower()
                if low.startswith("general parameters"):
                    section = "general"
                    continue
                if low.startswith("customer schedules"):
                    section = "schedule"
                    continue
                if low.startswith("location coordinates"):
                    section = "coords"
                    continue
                if low.startswith("travel time matrix"):
                    section = "tt"
                    continue

                if section == "general":
                    nb_cust, nb_loc, horizon, capacity = _parse_general(line)
                    section = "general_done"
                elif section == "schedule":
                    cust, dmd, stops = _parse_schedule(line)
                    schedule[cust] = stops
                    demand[cust] = dmd
                elif section == "coords":
                    loc, x, y = _parse_coord(line)
                    coords[loc] = (x, y)
                elif section == "tt":
                    i, j, tij = _parse_tt(line)
                    travel_time[(i, j)] = tij

        all_customers = sorted(schedule)
        if len(all_customers) < 3:
            raise ValueError(
                "Era esperado pelo menos depósito inicial, clientes reais e depósito final"
            )

        self.source_customer = all_customers[0]
        self.sink_customer = all_customers[-1]
        self.real_customers = [
            c for c in all_customers
            if c not in (self.source_customer, self.sink_customer)
        ]
        if len(self.real_customers) != nb_cust:
            raise ValueError(
                f"Cabeçalho diz {nb_cust} clientes, mas há {len(self.real_customers)} reais"
            )
        if len(schedule[self.source_customer]) != 1 or len(schedule[self.sink_customer]) != 1:
            raise ValueError("depósitos devem possuir exatamente um local cada")

        self.source_loc = schedule[self.source_customer][0][0]
        self.sink_loc = schedule[self.sink_customer][0][0]
        self.horizon = horizon
        self.capacity = capacity

        # ---------------- pré-processamento de locais inviáveis ---------------- #
        active = []
        active_open: Dict[int, float] = {}
        active_close: Dict[int, float] = {}
        active_xy: Dict[int, Tuple[float, float]] = {}
        active_cust: Dict[int, int] = {}

        for cust in all_customers:
            for loc, op, cl in schedule[cust]:
                if loc in active_cust:  # já vimos (não deveria acontecer)
                    continue
                ti0 = travel_time.get((loc, self.sink_loc), math.inf)
                t0i = travel_time.get((self.source_loc, loc), math.inf)
                if loc not in (self.source_loc, self.sink_loc):
                    if t0i > cl + 1e-9:
                        continue
                    if op + ti0 > horizon + 1e-9:
                        continue
                active.append(loc)
                active_open[loc] = op
                active_close[loc] = cl
                active_xy[loc] = coords[loc]
                active_cust[loc] = cust

        active.sort()
        self.active_locations = active
        # Reindexação 0..A-1 para o Hexaly (`local_idx[loc] = posição`)
        self.local_idx = {loc: idx for idx, loc in enumerate(active)}
        A = len(active)

        # demandas e janelas alinhadas com a reindexação:
        self.demand_per_loc = [
            demand[active_cust[loc]]
            if active_cust[loc] not in (self.source_customer, self.sink_customer)
            else 0.0
            for loc in active
        ]
        self.open_per_loc = [active_open[loc] for loc in active]
        self.close_per_loc = [active_close[loc] for loc in active]

        # locais de cada cliente (índices reindexados)
        self.locs_of_real_customer: List[List[int]] = []
        self.demand_per_real_customer: List[float] = []
        for cust in self.real_customers:
            opts = [
                self.local_idx[loc]
                for loc, _, _ in schedule[cust]
                if loc in self.local_idx
            ]
            if not opts:
                raise ValueError(f"cliente {cust} sem locais ativos")
            self.locs_of_real_customer.append(opts)
            self.demand_per_real_customer.append(demand[cust])

        # ---------------- matriz de custos com fechamento métrico ---------------- #
        cost = [[math.inf] * A for _ in range(A)]
        for i, li in enumerate(active):
            xi, yi = active_xy[li]
            cost[i][i] = 0.0
            for j, lj in enumerate(active):
                xj, yj = active_xy[lj]
                cost[i][j] = float(_euclidean_rounded(xi, yi, xj, yj))
        _floyd_warshall(cost)
        self.cost_matrix = cost

        # ---------------- matriz de tempos (lida; sem fechamento) -------------- #
        tt = [[math.inf] * A for _ in range(A)]
        for i, li in enumerate(active):
            for j, lj in enumerate(active):
                tt[i][j] = float(travel_time.get((li, lj), math.inf))
            tt[i][i] = 0.0
        self.time_matrix = tt

        self.source_idx = self.local_idx[self.source_loc]
        self.sink_idx = self.local_idx[self.sink_loc]

    # ---- helpers ---- #
    @property
    def nb_real_customers(self) -> int:
        return len(self.real_customers)

    def upper_bound_vehicles(self) -> int:
        return self.nb_real_customers


# --------------------------------------------------------------------------- #
# 2) Modelo Hexaly
# --------------------------------------------------------------------------- #


def solve(
    instance: Instance,
    time_limit: int,
    nb_threads: int | None = None,
    seed: int | None = None,
    verbosity: int = 1,
) -> dict:
    """Resolve a instância usando o Hexaly e devolve um dicionário-resumo."""

    import hexaly.optimizer  # type: ignore

    N = instance.nb_real_customers
    K = instance.upper_bound_vehicles()
    A = len(instance.active_locations)
    Q = instance.capacity
    H = instance.horizon

    src = instance.source_idx
    snk = instance.sink_idx

    cost_matrix = instance.cost_matrix
    time_matrix = instance.time_matrix
    open_loc = instance.open_per_loc
    close_loc = instance.close_per_loc
    demand_cust = instance.demand_per_real_customer
    loc_options = instance.locs_of_real_customer

    t0 = time.perf_counter()
    with hexaly.optimizer.HexalyOptimizer() as optimizer:
        m = optimizer.model

        # 1 lista de clientes por veículo (índices 0..N-1, reindexação interna)
        seqs = [m.list(N) for _ in range(K)]
        m.constraint(m.partition(seqs))

        # arrays "globais" (acessíveis por índices variáveis)
        cost_arr = m.array(cost_matrix)
        time_arr = m.array(time_matrix)
        open_arr = m.array(open_loc)
        close_arr = m.array(close_loc)
        demand_arr = m.array(demand_cust)

        # ----- escolha de local por cliente ----- #
        loc_choice = [m.int(0, len(loc_options[i]) - 1) for i in range(N)]
        # node_of_cust[i] = idx-global do local efetivamente usado pelo cliente i
        node_per_cust = [
            m.at(m.array(loc_options[i]), loc_choice[i]) for i in range(N)
        ]
        node_arr = m.array(node_per_cust)

        # ----- por veículo ----- #
        trucks_used = [(m.count(seqs[k]) > 0) for k in range(K)]
        nb_trucks_used = m.sum(trucks_used)

        dist_routes = [None] * K
        end_time = [None] * K
        lateness = [None] * K

        for k in range(K):
            seq = seqs[k]
            c = m.count(seq)

            # capacidade
            cap_lambda = m.lambda_function(lambda i: demand_arr[seq[i]])
            route_demand = m.sum(m.range(0, c), cap_lambda)
            m.constraint(route_demand <= Q)

            # distância
            dist_lambda = m.lambda_function(
                lambda i: m.at(cost_arr, node_arr[seq[i - 1]], node_arr[seq[i]])
            )
            inner = m.sum(m.range(1, c), dist_lambda)
            first_dist = m.iif(c > 0, m.at(cost_arr, src, node_arr[seq[0]]), 0)
            last_dist = m.iif(c > 0, m.at(cost_arr, node_arr[seq[c - 1]], snk), 0)
            dist_routes[k] = inner + first_dist + last_dist

            # tempo de chegada (sem service time: o formato turco já embute em open/close)
            end_lambda = m.lambda_function(
                lambda i, prev: m.max(
                    open_arr[node_arr[seq[i]]],
                    m.iif(
                        i == 0,
                        m.at(time_arr, src, node_arr[seq[0]]),
                        prev + m.at(time_arr, node_arr[seq[i - 1]], node_arr[seq[i]]),
                    ),
                )
            )
            end_time[k] = m.array(m.range(0, c), end_lambda, 0)

            # lateness por visita
            late_lambda = m.lambda_function(
                lambda i: m.max(0, end_time[k][i] - close_arr[node_arr[seq[i]]])
            )
            visit_lateness = m.sum(m.range(0, c), late_lambda)

            # lateness para chegada ao depósito final
            home_lateness = m.iif(
                trucks_used[k],
                m.max(
                    0,
                    end_time[k][c - 1]
                    + m.at(time_arr, node_arr[seq[c - 1]], snk)
                    - H,
                ),
                0,
            )
            lateness[k] = visit_lateness + home_lateness

        total_lateness = m.sum(lateness)
        total_distance = m.sum(dist_routes)

        # função objetivo lexicográfica: viabilidade -> nº veículos -> custo
        m.minimize(total_lateness)
        m.minimize(nb_trucks_used)
        m.minimize(total_distance)

        m.close()

        # parametrização do solver
        optimizer.param.time_limit = int(time_limit)
        optimizer.param.verbosity = int(verbosity)
        if nb_threads is not None:
            optimizer.param.nb_threads = int(nb_threads)
        if seed is not None:
            optimizer.param.seed = int(seed)

        optimizer.solve()

        elapsed = time.perf_counter() - t0
        status = optimizer.solution.status

        sol_routes: List[List[int]] = []
        for k in range(K):
            seq_value = list(seqs[k].value)
            if not seq_value:
                continue
            route = [instance.active_locations[node_per_cust[i].value] for i in seq_value]
            sol_routes.append(route)

        return {
            "name": instance.name,
            "n_customers": N,
            "nb_locations_active": A,
            "nb_vehicles_ub": K,
            "time_limit": int(time_limit),
            "wall_time_s": elapsed,
            "status": str(status),
            "total_lateness": float(total_lateness.value),
            "nb_trucks_used": int(nb_trucks_used.value),
            "total_distance": float(total_distance.value),
            "routes": sol_routes,
        }


# --------------------------------------------------------------------------- #
# 3) CLI
# --------------------------------------------------------------------------- #


def _write_solution(path: str, summary: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "# instance=%s n_customers=%d nb_locations_active=%d\n"
            % (summary["name"], summary["n_customers"], summary["nb_locations_active"])
        )
        f.write(
            "# status=%s wall_time_s=%.3f time_limit_s=%d\n"
            % (summary["status"], summary["wall_time_s"], summary["time_limit"])
        )
        f.write(
            "# total_lateness=%.6f nb_trucks_used=%d total_distance=%.6f\n"
            % (summary["total_lateness"], summary["nb_trucks_used"], summary["total_distance"])
        )
        f.write("%d %.6f\n" % (summary["nb_trucks_used"], summary["total_distance"]))
        for route in summary["routes"]:
            f.write(" ".join(str(loc) for loc in route))
            f.write("\n")


def main(argv: List[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="VRPRDL via Hexaly Optimizer")
    p.add_argument("instance", help="caminho da instância .txt (formato turco)")
    p.add_argument("--out", "-o", help="arquivo de saída .sol", default=None)
    p.add_argument(
        "--time-limit", "-t", type=int, default=60,
        help="tempo limite em segundos (default 60)",
    )
    p.add_argument("--threads", type=int, default=None)
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--verbosity", type=int, default=1)
    args = p.parse_args(argv)

    inst = Instance(args.instance)
    print(
        f"[hexaly] {inst.name}: n_customers={inst.nb_real_customers} "
        f"locs_ativos={len(inst.active_locations)} horizon={inst.horizon} "
        f"capacity={inst.capacity} TL={args.time_limit}s",
        flush=True,
    )

    summary = solve(
        inst,
        time_limit=args.time_limit,
        nb_threads=args.threads,
        seed=args.seed,
        verbosity=args.verbosity,
    )

    print(
        "[hexaly] {name}: status={status} nb_trucks={nb_trucks_used} "
        "cost={total_distance:.2f} lateness={total_lateness:.2f} "
        "wall={wall_time_s:.2f}s".format(**summary),
        flush=True,
    )

    if args.out:
        _write_solution(args.out, summary)

    return 0 if summary["total_lateness"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
