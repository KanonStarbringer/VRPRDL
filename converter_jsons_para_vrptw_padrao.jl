# =========================================================
# converter_jsons_para_vrptw_padrao.jl
#
# Converte os JSONs do VRPRDL (em VRPRDL-triangle/json_convertidos/)
# para o formato Solomon (VRPTW) aceito pelo demo
#   https://github.com/artalvpes/VRPSolverDemos/tree/main/VRPTW
#
# Formato Solomon (o mesmo dos arquivos em data/100/*.txt do demo):
#
#   <nome>
#
#   VEHICLE
#   NUMBER     CAPACITY
#     <K>        <Q>
#
#   CUSTOMER
#   CUST NO.  XCOORD.  YCOORD.  DEMAND  READY TIME  DUE DATE  SERVICE TIME
#
#       0    <x0> <y0>   0    0       <T>           0
#       1    <x1> <y1>   <d>  <e1>    <l1>          <s>
#       ...
#
# Observações sobre o parser do demo (other/VRPTW/src/data.jl):
# - Linhas contendo "VEH", "NUMBER" ou "CUST" são descartadas.
# - Depois do descarte, os tokens restantes são concatenados;
#   espera-se <nome> <K> <Q> seguido por blocos de 7 tokens por vértice.
# - Distâncias: `floor(sqrt(dx^2+dy^2) * 10) / 10` (1 casa decimal).
#
# Estratégia de projeção VRPRDL -> VRPTW (mesma do "caminho B"
# refinada: pick_enclose singleton-feasible):
#   - Para cada cliente real, tenta escolher UMA localização + janela
#     [open, close] do VRPRDL original tal que a rota degenerada
#     `0 -> c -> 0` seja VIÁVEL em relação ao horizonte:
#         d_eucl(depot, loc) <= close
#         max(open, d) + service + d <= time_horizon
#     Entre as viáveis, prefere a de janela mais larga.
#   - Se nenhuma localização for singleton-feasible, usa a mais próxima
#     do depot e ajusta a janela para [0, time_horizon - ceil(d) - s].
#     Caso nem isso dê, cai em [0, time_horizon] e marca como "relaxada".
#
# Também produz um CSV `_params.csv` com:
#   instance, n_customers, capacity, k_ub, ub_trivial, time_horizon,
#   n_relaxed
# que é consumido pelo shell batch correspondente.
#
# Saída: VRPRDL-triangle/vrptw_padrao_convertidos/*.txt
# =========================================================

using JSON3
using Printf

function get_base_dir()
    return joinpath(@__DIR__, "VRPRDL-triangle")
end

"Cliente real = não é o depot inicial (cid=0) nem o depot final (demand=0)."
function is_customer_real(c::Dict{String,Any})
    return c["customer_id"] != 0 && c["demand"] > 0
end

"""
Distância Euclidiana arredondada exatamente como o demo VRPTW:
`floor(sqrt(dx^2 + dy^2) * 10) / 10` (1 casa decimal).
"""
function dist_vrptw(x1, y1, x2, y2)
    dx = x1 - x2
    dy = y1 - y2
    return floor(sqrt(dx * dx + dy * dy) * 10) / 10
end

"""
Para um cliente VRPRDL, escolhe `(loc, open, close, d_depot, reachable)`
seguindo a regra `pick_enclose` singleton-feasible com fallback.

- `reachable = true`  ⇒ existe (loc, janela) no VRPRDL original viável.
- `reachable = false` ⇒ fallback: localização mais próxima com janela
  ajustada (ou [0, T] se nem isso for possível).
"""
function pick_singleton_feasible(customer::Dict{String,Any},
                                  coords::Dict{String,Any},
                                  depot_xy::Dict;
                                  service_time::Int,
                                  time_horizon::Int)
    locs = customer["locations"]
    isempty(locs) && error("Cliente sem localizações.")

    closest_loc = locs[1]
    closest_d = Inf
    best_loc = nothing
    best_width = -1
    best_d = Inf
    best_open = 0
    best_close = 0

    for l in locs
        xy = coords[string(l["location_id"])]
        d = sqrt((xy["x"] - depot_xy["x"])^2 + (xy["y"] - depot_xy["y"])^2)

        if d < closest_d
            closest_d = d
            closest_loc = l
        end

        open_l  = l["time_opening"]
        close_l = l["time_closing"]
        earliest_start = max(open_l, d)
        latest_return  = earliest_start + service_time + d
        reachable = (d <= close_l) && (latest_return <= time_horizon)

        if reachable
            width = close_l - open_l
            if width > best_width
                best_width = width
                best_loc = l
                best_d = d
                best_open = open_l
                best_close = close_l
            end
        end
    end

    if best_loc !== nothing
        return (best_loc, best_open, best_close, best_d, true)
    else
        close_eff = time_horizon - Int(ceil(closest_d)) - service_time
        if close_eff > 0
            return (closest_loc, 0, close_eff, closest_d, false)
        else
            return (closest_loc, 0, time_horizon, closest_d, false)
        end
    end
end

"""
Escreve uma instância VRPTW no formato Solomon a partir do JSON VRPRDL.

Retorna `(n_customers, capacity, k_ub, ub_trivial, time_horizon, n_relaxed)`.
"""
function write_solomon(instance::Dict{String,Any},
                      output_path::AbstractString;
                      service_time::Int = 0)
    gp = instance["general_parameters"]
    customers = instance["customer_schedules"]
    coords = instance["location_coordinates"]

    depot = first(c for c in customers if c["customer_id"] == 0)
    real_customers = sort!(
        [c for c in customers if is_customer_real(c)];
        by = c -> c["customer_id"],
    )

    name = replace(instance["source_file"], ".txt" => "")
    capacity = Int(gp["vehicle_capacity"])
    time_horizon = Int(gp["time_horizon"])
    n = length(real_customers)
    k_ub = n  # teto folgado: 1 veículo por cliente

    depot_loc = depot["locations"][1]
    depot_xy = coords[string(depot_loc["location_id"])]
    dx0 = round(Int, depot_xy["x"])
    dy0 = round(Int, depot_xy["y"])

    n_relaxed = 0
    ub_trivial = 0.0

    open(output_path, "w") do io
        println(io, name)
        println(io)
        println(io, "VEHICLE")
        println(io, "NUMBER     CAPACITY")
        @printf(io, "  %d         %d\n", k_ub, capacity)
        println(io)
        println(io, "CUSTOMER")
        println(io, "CUST NO.  XCOORD.    YCOORD.    DEMAND   READY TIME   DUE DATE   SERVICE TIME")
        println(io)

        @printf(io, "    %d      %d         %d          %d          %d       %d          %d\n",
                0, dx0, dy0, 0, 0, time_horizon, 0)

        for (idx, c) in enumerate(real_customers)
            loc, open_c, close_c, _d, reachable =
                pick_singleton_feasible(c, coords, depot_xy;
                                        service_time = service_time,
                                        time_horizon = time_horizon)
            xy = coords[string(loc["location_id"])]
            xc = round(Int, xy["x"])
            yc = round(Int, xy["y"])

            @printf(io, "    %d      %d         %d          %d         %d          %d          %d\n",
                    idx, xc, yc, c["demand"],
                    Int(open_c), Int(close_c), service_time)

            # UB trivial: soma de 2*d(depot, loc) arredondadas à la demo
            ub_trivial += 2 * dist_vrptw(dx0, dy0, xc, yc)
            reachable || (n_relaxed += 1)
        end
    end

    return (n_customers  = n,
            capacity     = capacity,
            k_ub         = k_ub,
            ub_trivial   = ub_trivial,
            time_horizon = time_horizon,
            n_relaxed    = n_relaxed)
end

"""
Converte todos os JSONs em VRPRDL-triangle/json_convertidos/ para
Solomon em VRPRDL-triangle/vrptw_padrao_convertidos/ e grava
`_params.csv` com os parâmetros usados pelo shell batch.
"""
function convert_all_json_to_vrptw_padrao(; service_time::Int = 0)
    base_dir = get_base_dir()
    json_dir = joinpath(base_dir, "json_convertidos")
    out_dir  = joinpath(base_dir, "vrptw_padrao_convertidos")

    isdir(json_dir) || error("Pasta de JSONs não encontrada: $json_dir")
    isdir(out_dir)  || mkpath(out_dir)

    files = sort(filter(f -> endswith(lowercase(f), ".json"), readdir(json_dir)))
    csv_path = joinpath(out_dir, "_params.csv")
    csv_io = open(csv_path, "w")
    println(csv_io, "instance,n_customers,capacity,k_ub,time_horizon,ub_trivial,n_relaxed")

    println("========================================")
    println("Pasta de JSONs  : $json_dir")
    println("Pasta de Solomon: $out_dir")
    println("service_time    : $service_time")
    println("========================================")

    converted = 0
    failed = 0
    total_relaxed = 0

    for file in files
        input_path = joinpath(json_dir, file)
        output_name = replace(file, r"\.json$" => ".txt")
        output_path = joinpath(out_dir, output_name)

        try
            print("Convertendo: $file ... ")
            instance = JSON3.read(read(input_path, String), Dict{String,Any})
            r = write_solomon(instance, output_path; service_time = service_time)
            total_relaxed += r.n_relaxed
            @printf("OK (n=%d, Q=%d, T=%d, K_ub=%d, UB_triv=%.1f, relaxed=%d)\n",
                    r.n_customers, r.capacity, r.time_horizon,
                    r.k_ub, r.ub_trivial, r.n_relaxed)
            base = replace(file, r"\.json$" => "")
            @printf(csv_io, "%s,%d,%d,%d,%d,%.1f,%d\n",
                    base, r.n_customers, r.capacity, r.k_ub,
                    r.time_horizon, r.ub_trivial, r.n_relaxed)
            converted += 1
        catch err
            failed += 1
            println("[ERRO]")
            println("       ", err)
        end
    end

    close(csv_io)

    println("========================================")
    println("Conversão concluída.")
    println("Convertidos        : $converted")
    println("Falharam           : $failed")
    println("Clientes relaxados : $total_relaxed")
    println("CSV params         : $csv_path")
    println("========================================")
end

convert_all_json_to_vrptw_padrao()
