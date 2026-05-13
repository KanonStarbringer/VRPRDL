using JSON3
using Printf

# =========================================================
# Configuração
# =========================================================

function get_base_dir()
    return joinpath(@__DIR__, "VRPRDL-triangle")
end

# =========================================================
# Utilidades
# =========================================================

function is_customer_real(customer::Dict{String,Any})
    cid = customer["customer_id"]
    demand = customer["demand"]

    # No formato original:
    # customer_id = 0  -> depot inicial
    # customer_id = n+1 -> depot final
    # ambos com demanda 0
    return cid != 0 && demand > 0
end

function first_location(customer::Dict{String,Any})
    locs = customer["locations"]
    isempty(locs) && error("Cliente sem localizações.")
    return locs[1]
end

# =========================================================
# Escrita .vrp
# =========================================================

function write_vrp(instance::Dict{String,Any}, output_path::AbstractString)
    gp = instance["general_parameters"]
    customers = instance["customer_schedules"]
    coords = instance["location_coordinates"]

    real_customers = [c for c in customers if is_customer_real(c)]

    name = replace(instance["source_file"], ".txt" => "")
    capacity = gp["vehicle_capacity"]

    open(output_path, "w") do io
        println(io, "NAME : ", name)
        println(io, "TYPE : CVRP")
        println(io, "COMMENT : Simplified projection from VRPRDL JSON using first location of each real customer")
        println(io, "DIMENSION : ", length(real_customers) + 1)
        println(io, "EDGE_WEIGHT_TYPE : EUC_2D")
        println(io, "CAPACITY : ", capacity)
        println(io)

        println(io, "NODE_COORD_SECTION")
        # depósito
        println(io, "1 0 0")

        # clientes reais numerados de 2 em diante no .vrp
        for (idx, c) in enumerate(real_customers)
            loc = first_location(c)
            loc_id = string(loc["location_id"])
            xy = coords[loc_id]
            x = round(Int, xy["x"])
            y = round(Int, xy["y"])
            println(io, "$(idx + 1) $x $y")
        end

        println(io)
        println(io, "DEMAND_SECTION")
        println(io, "1 0")
        for (idx, c) in enumerate(real_customers)
            println(io, "$(idx + 1) ", c["demand"])
        end

        println(io)
        println(io, "DEPOT_SECTION")
        println(io, "1")
        println(io, "-1")
        println(io, "EOF")
    end
end

# =========================================================
# Batch
# =========================================================

function convert_all_json_to_vrp()
    base_dir = get_base_dir()
    json_dir = joinpath(base_dir, "json_convertidos")
    vrp_dir = joinpath(base_dir, "vrp_convertidos")

    isdir(json_dir) || error("Pasta de JSONs não encontrada: $json_dir")
    isdir(vrp_dir) || mkdir(vrp_dir)

    files = sort(filter(f -> endswith(lowercase(f), ".json"), readdir(json_dir)))
    converted = 0
    failed = 0

    println("========================================")
    println("Pasta de JSONs: $json_dir")
    println("Pasta de VRPs:  $vrp_dir")
    println("========================================")

    for file in files
        input_path = joinpath(json_dir, file)
        output_name = replace(file, r"\.json$" => ".vrp")
        output_path = joinpath(vrp_dir, output_name)

        try
            println("Convertendo: $file")
            instance = JSON3.read(read(input_path, String), Dict{String,Any})
            write_vrp(instance, output_path)
            converted += 1
        catch err
            failed += 1
            println("  [ERRO] $file")
            println("         ", err)
        end
    end

    println("========================================")
    println("Conversão concluída.")
    println("Convertidos: $converted")
    println("Falharam:    $failed")
    println("========================================")
end

# =========================================================
# Main
# =========================================================

convert_all_json_to_vrp()