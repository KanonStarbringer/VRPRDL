"""Reconstroi _summary.csv lendo todos os .sol em sols_hexaly/."""
from pathlib import Path
import re

base = Path(__file__).resolve().parent
sols_dir = base / "sols_hexaly"
out = base / "logs_hexaly" / "_summary.csv"
out.parent.mkdir(parents=True, exist_ok=True)

ORIG_DIR = "VRPRDL-triangle"
V1_DIR = "additional_instances/variant_1"
V2_DIR = "additional_instances/variant_2"


def family_of(stem: str) -> str:
    if stem.endswith("-triangle"):
        return "original"
    if stem.startswith("variant2_"):
        return "variant_2"
    return "variant_1"


rx_h1 = re.compile(r"instance=(\S+)\s+n_customers=(\d+)\s+nb_locations_active=(\d+)")
rx_h2 = re.compile(r"status=(\S+)\s+wall_time_s=([0-9.]+)\s+time_limit_s=(\d+)")
rx_h3 = re.compile(r"total_lateness=([0-9.eE+-]+)\s+nb_trucks_used=(\d+)\s+total_distance=([0-9.eE+-]+)")

rows = []
for sol in sorted(sols_dir.glob("*.sol")):
    txt = sol.read_text(encoding="utf-8").splitlines()
    h1 = h2 = h3 = ""
    for line in txt[:5]:
        if line.startswith("#"):
            if "instance=" in line:
                h1 = line
            elif "status=" in line:
                h2 = line
            elif "total_lateness=" in line:
                h3 = line
    m1 = rx_h1.search(h1)
    m2 = rx_h2.search(h2)
    m3 = rx_h3.search(h3)
    if not (m1 and m2 and m3):
        print(f"[skip] {sol.name}: cabecalho incompleto")
        continue
    name, ncust, nlocs = m1.group(1), m1.group(2), m1.group(3)
    status, wall, tl = m2.group(1), m2.group(2), m2.group(3)
    late, nbt, dist = m3.group(1), m3.group(2), m3.group(3)
    fam = family_of(name)
    rows.append({
        "family": fam,
        "instance": name,
        "n_customers": ncust,
        "locs_ativos": nlocs,
        "nb_trucks_used": nbt,
        "total_distance": dist,
        "total_lateness": late,
        "status": status,
        "time_limit_s": tl,
        "wall_time_s": wall,
        "sol_path": str(sol),
    })

rows.sort(key=lambda r: (r["family"], r["instance"]))

header = "family,instance,n_customers,locs_ativos,nb_trucks_used,total_distance,total_lateness,status,time_limit_s,wall_time_s,sol_path"
lines = [header]
for r in rows:
    lines.append(",".join(str(r[k]) for k in header.split(",")))
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"reconstruidas {len(rows)} linhas em {out}")
