# =========================================================
# converter_jsons_para_cvrp_padrao.jl
#
# Converte JSONs do VRPRDL (em VRPRDL-triangle/json_convertidos/)
# para o formato TSPLIB/CVRP padrão aceito pelo demo CVRP do
# VRPSolverDemos (https://github.com/artalvpes/VRPSolverDemos).
#
# Estratégia de projeção:
#   - Para cada cliente real do VRPRDL, escolhemos a localização
#     mais PRÓXIMA do depot em distância euclidiana. Isto é a
#     projeção "mais barata" por cliente individualmente e dá ao
#     VRPSolver CVRP a menor matriz de custos possível para aquela
#     escolha heurística.
#   - Janelas de tempo são ignoradas (CVRP puro).
#   - Coordenadas: arredondadas para inteiros (compatível com o
#     formato usado pelo VRPSolverDemos em data/A, data/B, etc.).
#   - O número de veículos não é fixado no .vrp (é passado na
#     linha de comando via -m / -M).
#
# Saída: arquivos .vrp em VRPRDL-triangle/cvrp_padrao_convertidos/
# =========================================================

using JSON3
using Printf

function get_base_dir()
    return normpath(joinpath(@__DIR__, "..", "VRPRDL-triangle"))
end

function is_customer_real(customer::Dict{String,Any})
    cid = customer["customer_id"]
    demand = customer["demand"]
    return cid != 0 && demand > 0
end

"""
Escolhe a localização de `customer` mais próxima do depot em
distância euclidiana. Retorna `(loc, d_depot)`.
"""
function pick_closest_to_depot(customer::Dict{String,Any},
                               coords::Dict{String,Any},
                               depot_xy::Dict)
    locs = customer["locations"]
    isempty(locs) && error("Cliente sem localizações.")

    best_loc = locs[1]
    best_d = Inf
    for l in locs
        xy = coords[string(l["location_id"])]
        dx = xy["x"] - depot_xy["x"]
        dy = xy["y"] - depot_xy["y"]
        d = sqrt(dx * dx + dy * dy)
        if d < best_d
            best_d = d
            best_loc = l
        end
    end
    return best_loc, best_d
end

"""
Escreve uma instância CVRP padrão TSPLIB (.vrp) a partir de um
JSON VRPRDL.

Retorna uma `NamedTuple` com `(n_customers, capacity, total_demand, k_lb)`,
onde `k_lb = ceil(total_demand/capacity)` é o menor número de veículos
necessário pela desigualdade de capacidade (útil para `-m K_LB` no
comando do VRPSolver).
"""
function write_tsplib_cvrp(instance::Dict{String,Any},
                           output_path::AbstractString)
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
    depot_loc = depot["locations"][1]
    depot_xy = coords[string(depot_loc["location_id"])]

    n = length(real_customers)
    dim = n + 1  # depot + clientes
    total_demand = sum(c["demand"] for c in real_customers; init = 0)
    k_lb = ceil(Int, total_demand / capacity)

    open(output_path, "w") do io
        println(io, "NAME : ", name)
        println(io, "COMMENT : VRPRDL projected to CVRP (closest location per customer; total_demand=",
                total_demand, ", k_lb=", k_lb, ")")
        println(io, "TYPE : CVRP")
        println(io, "DIMENSION : ", dim)
        println(io, "EDGE_WEIGHT_TYPE : EUC_2D ")
        println(io, "CAPACITY : ", capacity)

        println(io, "NODE_COORD_SECTION ")
        @printf(io, " %d %d %d\n",
                1,
                round(Int, depot_xy["x"]),
                round(Int, depot_xy["y"]))
        for (idx, c) in enumerate(real_customers)
            loc, _ = pick_closest_to_depot(c, coords, depot_xy)
            xy = coords[string(loc["location_id"])]
            @printf(io, " %d %d %d\n",
                    idx + 1,
                    round(Int, xy["x"]),
                    round(Int, xy["y"]))
        end

        println(io, "DEMAND_SECTION ")
        @printf(io, "%d %d \n", 1, 0)
        for (idx, c) in enumerate(real_customers)
            @printf(io, "%d %d \n", idx + 1, c["demand"])
        end

        println(io, "DEPOT_SECTION ")
        println(io, " 1  ")
        println(io, " -1  ")
        println(io, "EOF ")
    end

    return (n_customers = n,
            capacity = capacity,
            total_demand = total_demand,
            k_lb = k_lb)
end

"""
Converte todos os JSONs em VRPRDL-triangle/json_convertidos/
para arquivos .vrp em VRPRDL-triangle/cvrp_padrao_convertidos/.
Também escreve um CSV `_params.csv` com `instance,k_lb,k_ub,capacity,total_demand`
para alimentar o script de batch.
"""
function convert_all_json_to_cvrp_padrao()
    base_dir = get_base_dir()
    json_dir = joinpath(base_dir, "json_convertidos")
    out_dir  = joinpath(base_dir, "cvrp_padrao_convertidos")

    isdir(json_dir) || error("Pasta de JSONs não encontrada: $json_dir")
    isdir(out_dir)  || mkpath(out_dir)

    files = sort(filter(f -> endswith(lowercase(f), ".json"), readdir(json_dir)))
    converted = 0
    failed = 0

    csv_path = joinpath(out_dir, "_params.csv")
    csv_io = open(csv_path, "w")
    println(csv_io, "instance,n_customers,k_lb,k_ub,capacity,total_demand")

    println("========================================")
    println("Pasta de JSONs : $json_dir")
    println("Pasta de .vrp  : $out_dir")
    println("========================================")

    for file in files
        input_path = joinpath(json_dir, file)
        output_name = replace(file, r"\.json$" => ".vrp")
        output_path = joinpath(out_dir, output_name)

        try
            print("Convertendo: $file ... ")
            instance = JSON3.read(read(input_path, String), Dict{String,Any})
            r = write_tsplib_cvrp(instance, output_path)
            @printf("OK  (n=%d, demand=%d, cap=%d, k_lb=%d)\n",
                    r.n_customers, r.total_demand, r.capacity, r.k_lb)
            base = replace(file, r"\.json$" => "")
            println(csv_io, "$base,", r.n_customers, ",", r.k_lb, ",",
                    r.n_customers, ",", r.capacity, ",", r.total_demand)
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
    println("Convertidos: $converted")
    println("Falharam   : $failed")
    println("CSV params : $csv_path")
    println("========================================")
end

convert_all_json_to_cvrp_padrao()
