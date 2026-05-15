"""Compara o _summary.csv do Hexaly com os otimos do VRPSolver."""
from pathlib import Path
import csv

base = Path(__file__).resolve().parents[1]  # VRPRDL_VRPSolver_/

hex_summary = base / "hexaly" / "logs_hexaly" / "_summary.csv"
vrp_orig = base / "logs" / "_summary.csv"
vrp_v1 = base / "logs_extra_v1" / "_summary.csv"
vrp_v2 = base / "logs_extra_v2" / "_summary.csv"


def load_vrp(path: Path, name_field: str = "instance") -> dict:
    out = {}
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out[row[name_field]] = row
    return out


vrp_data = {}
vrp_data.update(load_vrp(vrp_orig))
vrp_data.update(load_vrp(vrp_v1))
vrp_data.update(load_vrp(vrp_v2))

with hex_summary.open(encoding="utf-8") as f:
    hex_rows = list(csv.DictReader(f))

print(f"{'family':10s} {'instance':30s} {'n':>3s} {'VRPS_t':>8s} {'VRPS_c':>8s} {'HXLY_t':>8s} {'HXLY_c':>8s} {'gap%':>7s}")
print("-" * 95)

agg = {}  # family -> [gaps]
for h in hex_rows:
    inst = h["instance"]
    fam = h["family"]
    n = int(h["n_customers"])
    hex_cost = float(h["total_distance"])
    hex_t = float(h["wall_time_s"])
    v = vrp_data.get(inst)
    if v is None:
        print(f"  -- sem VRPSolver match para {inst}")
        continue
    vrp_cost = float(v.get("best_inc") or v.get("incumbent") or "nan")
    vrp_t = float(v.get("total_time_s") or v.get("wall_time_s") or "nan")
    gap = (hex_cost - vrp_cost) / vrp_cost * 100.0 if vrp_cost > 0 else float("nan")
    agg.setdefault(fam, []).append(gap)
    print(f"{fam:10s} {inst:30s} {n:>3d} {vrp_t:>8.1f} {vrp_cost:>8.0f} {hex_t:>8.1f} {hex_cost:>8.0f} {gap:>6.2f}%")

print()
print(f"{'familia':12s} {'#inst':>6s} {'gap medio %':>12s} {'gap max %':>12s} {'iguais (gap=0)':>15s}")
print("-" * 60)
for fam, gaps in agg.items():
    avg = sum(gaps) / len(gaps)
    mx = max(gaps)
    eq = sum(1 for g in gaps if abs(g) < 1e-6)
    print(f"{fam:12s} {len(gaps):>6d} {avg:>11.2f}  {mx:>11.2f}  {eq:>14d}")
