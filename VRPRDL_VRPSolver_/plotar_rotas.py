"""
Plota as rotas encontradas pelo VRPSolver para cada instância VRPRDL.

Entradas:
  - data_vrprdl/instance_{k}-triangle.txt   (coordenadas e scheduling)
  - sol_instance_{k}.txt                    (rotas encontradas)

Saídas:
  - plots/instance_{k}-triangle.png
  - plots/_index.html  (galeria rápida com todas as figuras)

Uso:
  python plotar_rotas.py                 # todas as 40 instâncias
  python plotar_rotas.py 0 5 31          # só 0, 5 e 31
  ONLY=0,5,31 python plotar_rotas.py
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import colors as mcolors
from matplotlib.lines import Line2D
from matplotlib.patches import FancyArrowPatch

ROOT = Path(r"C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\VRPRDL_VRPSolver_")
INST_DIR = ROOT / "data_vrprdl"
PLOTS_DIR = ROOT / "plots"
PLOTS_DIR.mkdir(exist_ok=True)


# -------------------------- parsers --------------------------

def parse_instance(path: Path) -> dict:
    """Lê n_customers, horizon, capacity, coords de cada loc, e mapa cliente→locs."""
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    section = None
    n_customers = n_locations = 0
    horizon = capacity = 0.0
    coords: dict[int, tuple[float, float]] = {}
    cust_locs: dict[int, list[tuple[int, float, float]]] = {}
    demands: dict[int, float] = {}

    for raw in lines:
        line = re.sub(r"#.*$", "", raw).strip()
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
            toks = line.split()
            n_customers = int(toks[0])
            n_locations = int(toks[1])
            horizon = float(toks[2])
            capacity = float(toks[3])
            section = None
        elif section == "schedule":
            toks = line.split()
            c = int(toks[0])
            demand = float(toks[1])
            demands[c] = demand
            stops = []
            for m in re.finditer(r"(\d+)\s*\[\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\]", line):
                stops.append((int(m.group(1)), float(m.group(2)), float(m.group(3))))
            cust_locs[c] = stops
        elif section == "coords":
            m = re.match(r"^(\d+)\s+([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s+([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)$", line)
            if m:
                loc = int(m.group(1))
                coords[loc] = (float(m.group(2)), float(m.group(3)))
        elif section == "tt":
            break

    loc_to_customer: dict[int, int] = {}
    for c, stops in cust_locs.items():
        for loc, _o, _cl in stops:
            loc_to_customer[loc] = c

    all_custs = sorted(cust_locs.keys())
    source_customer = all_custs[0]
    sink_customer = all_custs[-1]
    source_loc = cust_locs[source_customer][0][0]
    sink_loc = cust_locs[sink_customer][0][0]
    real_customers = [c for c in all_custs if c != source_customer and c != sink_customer]

    return {
        "n_customers": n_customers,
        "n_locations": n_locations,
        "horizon": horizon,
        "capacity": capacity,
        "coords": coords,
        "cust_locs": cust_locs,
        "loc_to_customer": loc_to_customer,
        "demands": demands,
        "source_customer": source_customer,
        "sink_customer": sink_customer,
        "source_loc": source_loc,
        "sink_loc": sink_loc,
        "real_customers": real_customers,
    }


def parse_solution(path: Path) -> dict:
    """Lê rotas e custo do sol_instance_{k}.txt."""
    routes: list[list[int]] = []
    cost = None
    instance_name = None
    optimal = None
    if not path.exists():
        return {"routes": [], "cost": None, "instance_name": None, "optimal": None}
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if line.startswith("statistics:"):
            parts = [p.strip() for p in line[len("statistics:"):].split("&")]
            if len(parts) >= 2:
                instance_name = parts[0]
                optimal = parts[1] == "1"
        if line.startswith("Route"):
            m = re.match(r"Route\s*#\d+:\s*(.*)$", line)
            if m:
                rest = m.group(1).strip()
                if rest:
                    routes.append([int(tok) for tok in rest.split()])
        elif line.startswith("Cost"):
            m = re.match(r"Cost\s+([-+]?\d+(?:\.\d+)?)", line)
            if m:
                cost = float(m.group(1))
    return {"routes": routes, "cost": cost, "instance_name": instance_name, "optimal": optimal}


# -------------------------- plot --------------------------

def _nice_colors(n: int):
    if n <= 10:
        cmap = plt.get_cmap("tab10")
        return [cmap(i) for i in range(n)]
    if n <= 20:
        cmap = plt.get_cmap("tab20")
        return [cmap(i) for i in range(n)]
    cmap = plt.get_cmap("hsv")
    return [cmap(i / n) for i in range(n)]


def plot_instance(k: int) -> Path | None:
    inst_path = INST_DIR / f"instance_{k}-triangle.txt"
    sol_path = ROOT / f"sol_instance_{k}.txt"
    if not inst_path.exists():
        print(f"[{k}] instância não encontrada: {inst_path}")
        return None
    if not sol_path.exists():
        print(f"[{k}] solução não encontrada: {sol_path}")
        return None

    inst = parse_instance(inst_path)
    sol = parse_solution(sol_path)

    coords = inst["coords"]
    loc_to_cust = inst["loc_to_customer"]
    source_loc = inst["source_loc"]
    sink_loc = inst["sink_loc"]
    routes = sol["routes"]
    cost = sol["cost"]

    fig_w = 11
    fig_h = 8.5
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    used_locs: set[int] = set()
    for r in routes:
        used_locs.update(r)

    cust_to_locs = {c: [lid for lid, *_ in stops] for c, stops in inst["cust_locs"].items()}
    real_custs = inst["real_customers"]

    for c in real_custs:
        locs = cust_to_locs.get(c, [])
        xs = [coords[l][0] for l in locs if l not in used_locs and l in coords]
        ys = [coords[l][1] for l in locs if l not in used_locs and l in coords]
        if xs:
            ax.scatter(xs, ys, s=18, c="lightgray", edgecolors="gray", linewidths=0.3, zorder=1)

    for c in real_custs:
        locs = cust_to_locs.get(c, [])
        xs = [coords[l][0] for l in locs if l in coords]
        ys = [coords[l][1] for l in locs if l in coords]
        if len(xs) >= 2:
            ax.plot(xs, ys, "-", color="lightgray", linewidth=0.6, alpha=0.6, zorder=1)

    n_routes = len(routes)
    route_colors = _nice_colors(max(1, n_routes))

    for ridx, r in enumerate(routes):
        color = route_colors[ridx]
        seq = [source_loc] + r + [sink_loc]
        xs = [coords[l][0] for l in seq if l in coords]
        ys = [coords[l][1] for l in seq if l in coords]
        ax.plot(xs, ys, "-", color=color, linewidth=1.9, zorder=3, label=f"Route #{ridx+1} ({len(r)} cli.)")
        for i in range(len(seq) - 1):
            a = coords.get(seq[i])
            b = coords.get(seq[i + 1])
            if a is None or b is None:
                continue
            arrow = FancyArrowPatch(
                a, b,
                arrowstyle="->,head_length=6,head_width=4",
                mutation_scale=10,
                color=color, linewidth=0.0, alpha=0.85, zorder=4,
            )
            ax.add_patch(arrow)
        xs_u = [coords[l][0] for l in r if l in coords]
        ys_u = [coords[l][1] for l in r if l in coords]
        ax.scatter(xs_u, ys_u, s=55, color=color, edgecolors="black", linewidths=0.6, zorder=5)
        for l in r:
            if l not in coords:
                continue
            cust = loc_to_cust.get(l, "?")
            ax.annotate(f"{cust}", coords[l], fontsize=6.5,
                        textcoords="offset points", xytext=(4, 4), color="black", zorder=6)

    dx, dy = coords[source_loc]
    ax.scatter([dx], [dy], s=180, marker="s", color="black",
               edgecolors="white", linewidths=1.5, zorder=10, label="Depot")
    ax.annotate("Depot", (dx, dy), fontsize=8, fontweight="bold",
                textcoords="offset points", xytext=(6, 6), color="black", zorder=11)

    title = (
        f"VRPRDL  —  instance_{k}-triangle   "
        f"(n = {inst['n_customers']}, Q = {int(inst['capacity'])}, "
        f"T = {int(inst['horizon'])})"
    )
    subtitle_parts = []
    if cost is not None:
        subtitle_parts.append(f"cost = {cost:g}")
    subtitle_parts.append(f"#routes = {n_routes}")
    if sol["optimal"] is True:
        subtitle_parts.append("optimal")
    ax.set_title(title + "\n" + "   |   ".join(subtitle_parts), fontsize=11)
    ax.set_xlabel("x")
    ax.set_ylabel("y")
    ax.set_aspect("equal", adjustable="datalim")
    ax.grid(True, which="both", linestyle=":", linewidth=0.4, alpha=0.6)

    legend_elems = [
        Line2D([0], [0], marker="s", color="w", markerfacecolor="black",
               markersize=10, label="Depot"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="lightgray",
               markeredgecolor="gray", markersize=7, label="Unused location"),
    ] + [
        Line2D([0], [0], marker="o", color=route_colors[i],
               markerfacecolor=route_colors[i], markeredgecolor="black",
               markersize=8, linewidth=2, label=f"Route #{i+1}")
        for i in range(min(n_routes, 20))
    ]
    if n_routes > 20:
        legend_elems.append(Line2D([0], [0], marker="", color="w",
                                   label=f"... (+{n_routes - 20} routes)"))
    ax.legend(handles=legend_elems, loc="center left", bbox_to_anchor=(1.01, 0.5),
              fontsize=8, frameon=True)

    fig.tight_layout()
    out = PLOTS_DIR / f"instance_{k}-triangle.png"
    fig.savefig(out, dpi=140, bbox_inches="tight")
    plt.close(fig)
    return out


def build_index(pngs: list[Path]):
    html = ["<!doctype html><meta charset='utf-8'>",
            "<title>VRPRDL — rotas</title>",
            "<style>body{font-family:sans-serif;margin:20px}h1{font-size:20px}",
            ".grid{display:grid;grid-template-columns:repeat(2,1fr);gap:16px}",
            ".card{border:1px solid #ddd;border-radius:6px;padding:8px}",
            ".card img{width:100%;height:auto;display:block}",
            "h2{font-size:13px;margin:4px 0 8px 0}</style>",
            "<h1>VRPRDL — rotas plotadas</h1>",
            "<div class='grid'>"]
    for p in pngs:
        html.append(
            f"<div class='card'><h2>{p.stem}</h2>"
            f"<a href='{p.name}' target='_blank'><img src='{p.name}'></a></div>"
        )
    html.append("</div>")
    (PLOTS_DIR / "_index.html").write_text("\n".join(html), encoding="utf-8")


def main():
    only = []
    if os.environ.get("ONLY"):
        only = [int(x) for x in os.environ["ONLY"].split(",") if x.strip()]
    elif len(sys.argv) > 1:
        only = [int(x) for x in sys.argv[1:]]

    if not only:
        only = sorted([
            int(re.search(r"instance_(\d+)-triangle", p.stem).group(1))
            for p in INST_DIR.glob("instance_*-triangle.txt")
        ])

    pngs = []
    for k in only:
        try:
            out = plot_instance(k)
            if out is not None:
                pngs.append(out)
                print(f"[{k}] OK -> {out.name}")
        except Exception as e:
            print(f"[{k}] ERRO: {e}")

    pngs.sort(key=lambda p: int(re.search(r"instance_(\d+)", p.stem).group(1)))
    build_index(pngs)
    print(f"\n{len(pngs)} figura(s) em {PLOTS_DIR}")
    print(f"Galeria: {PLOTS_DIR / '_index.html'}")


if __name__ == "__main__":
    main()
