from pathlib import Path
import math
import re
import sys
import os

import matplotlib.pyplot as plt


def get_base_dir() -> Path:
    if os.name == "nt":
        return Path(
            r"C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\instancias_turco\VRPRDL-triangle"
        )
    return Path(
        "/mnt/c/Users/porin/OneDrive/Documentos/Python-Mestrado/Modelagem Matemática/Programação Inteira - Uchoa/Problema VRPRDL/instancias_turco/VRPRDL-triangle"
    )


def parse_vrp(vrp_path: Path):
    text = vrp_path.read_text(encoding="utf-8", errors="ignore").splitlines()

    coords = {}
    demands = {}
    depot_ids = []

    section = None
    for raw_line in text:
        line = raw_line.strip()
        if not line:
            continue

        if line.startswith("NODE_COORD_SECTION"):
            section = "coords"
            continue
        elif line.startswith("DEMAND_SECTION"):
            section = "demands"
            continue
        elif line.startswith("DEPOT_SECTION"):
            section = "depot"
            continue
        elif line.startswith("EOF"):
            section = None
            continue

        if section == "coords":
            parts = line.split()
            if len(parts) >= 3:
                node_id = int(parts[0])
                x = float(parts[1])
                y = float(parts[2])
                coords[node_id] = (x, y)

        elif section == "demands":
            parts = line.split()
            if len(parts) >= 2:
                node_id = int(parts[0])
                demand = int(parts[1])
                demands[node_id] = demand

        elif section == "depot":
            if line == "-1":
                section = None
            else:
                depot_ids.append(int(line))

    if not depot_ids:
        raise ValueError(f"Nenhum depósito encontrado em {vrp_path}")

    return coords, demands, depot_ids[0]


def parse_routes_from_log(log_path: Path):
    text = log_path.read_text(encoding="utf-8", errors="ignore").splitlines()

    route_pattern = re.compile(r"Route\s+#(\d+):\s+(.*)")
    cost_pattern = re.compile(r"Cost\s+([0-9]+(?:\.[0-9]+)?)")
    status_pattern = re.compile(r"Solution status = (.+)")

    routes = []
    cost = None
    status = ""

    for line in text:
        line = line.strip()

        m = route_pattern.match(line)
        if m:
            nodes_str = m.group(2).strip()
            if nodes_str:
                route_nodes = [int(x) for x in nodes_str.split()]
                routes.append(route_nodes)
            continue

        m = cost_pattern.match(line)
        if m:
            cost = float(m.group(1))
            continue

        m = status_pattern.match(line)
        if m:
            status = m.group(1).strip()

    return routes, cost, status


def compute_route_length(route, coords, depot_id):
    full_route = [depot_id] + route + [depot_id]
    length = 0.0
    for i in range(len(full_route) - 1):
        a = full_route[i]
        b = full_route[i + 1]
        x1, y1 = coords[a]
        x2, y2 = coords[b]
        length += math.hypot(x2 - x1, y2 - y1)
    return length


def plot_instance(vrp_path: Path, log_path: Path, output_path: Path):
    coords, demands, depot_id = parse_vrp(vrp_path)
    routes, cost, status = parse_routes_from_log(log_path)

    if not routes:
        raise ValueError(f"Nenhuma rota encontrada no log {log_path.name}")

    fig, ax = plt.subplots(figsize=(10, 8))

    customer_ids = [nid for nid in coords if nid != depot_id]
    xs = [coords[nid][0] for nid in customer_ids]
    ys = [coords[nid][1] for nid in customer_ids]

    ax.scatter(xs, ys, s=35, label="Clientes")
    depot_x, depot_y = coords[depot_id]
    ax.scatter([depot_x], [depot_y], s=130, marker="s", label="Depósito")

    for nid, (x, y) in coords.items():
        if nid == depot_id:
            ax.text(x, y, f"D{nid}", fontsize=9, ha="right", va="bottom")
        else:
            d = demands.get(nid, 0)
            ax.text(x, y, f"{nid}({d})", fontsize=7, ha="right", va="bottom")

    for idx, route in enumerate(routes, start=1):
        full_route = [depot_id] + route + [depot_id]
        rx = [coords[nid][0] for nid in full_route]
        ry = [coords[nid][1] for nid in full_route]
        route_len = compute_route_length(route, coords, depot_id)

        ax.plot(
            rx,
            ry,
            linewidth=2,
            marker="o",
            markersize=3.5,
            label=f"Rota {idx} (dist≈{route_len:.1f})",
        )

    title = vrp_path.stem
    if status:
        title += f" | {status}"
    if cost is not None:
        title += f" | Custo = {cost:.0f}"

    ax.set_title(title)
    ax.set_xlabel("X")
    ax.set_ylabel("Y")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=7)
    plt.tight_layout()

    output_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_path, dpi=220, bbox_inches="tight")
    plt.close(fig)


def main():
    base_dir = get_base_dir()
    vrp_dir = base_dir / "vrp_convertidos"
    logs_dir = base_dir / "logs_vrp_convertidos"
    figs_dir = base_dir / "figuras_vrp_convertidos"

    if not vrp_dir.exists():
        print(f"Erro: pasta de VRPs não encontrada: {vrp_dir}")
        sys.exit(1)

    if not logs_dir.exists():
        print(f"Erro: pasta de logs não encontrada: {logs_dir}")
        sys.exit(1)

    figs_dir.mkdir(parents=True, exist_ok=True)

    log_files = sorted(logs_dir.glob("*.log"))
    if not log_files:
        print(f"Nenhum .log encontrado em {logs_dir}")
        sys.exit(1)

    total = 0
    ok = 0
    skipped = 0
    failed = 0

    print("========================================")
    print(f"Pasta de VRPs:    {vrp_dir}")
    print(f"Pasta de logs:    {logs_dir}")
    print(f"Pasta de figuras: {figs_dir}")
    print(f"Total de logs:    {len(log_files)}")
    print("========================================")

    for log_path in log_files:
        total += 1
        base_name = log_path.stem
        vrp_path = vrp_dir / f"{base_name}.vrp"
        fig_path = figs_dir / f"{base_name}.png"

        print(f"\nProcessando: {base_name}")

        if not vrp_path.exists():
            print(f"  [SKIP] .vrp correspondente não encontrado: {vrp_path.name}")
            skipped += 1
            continue

        try:
            plot_instance(vrp_path, log_path, fig_path)
            print(f"  [OK] figura salva em: {fig_path}")
            ok += 1
        except Exception as e:
            print(f"  [FAIL] erro ao processar {base_name}: {e}")
            failed += 1

    print("\n========================================")
    print("Resumo")
    print("========================================")
    print(f"Total:    {total}")
    print(f"Sucesso:  {ok}")
    print(f"Pulados:  {skipped}")
    print(f"Falharam: {failed}")


if __name__ == "__main__":
    main()