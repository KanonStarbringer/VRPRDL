using JSON3
using Printf

# =========================================================
# Configuração
# =========================================================

# Se você rodar no Windows (Julia no Windows), use este caminho:
const BASE_DIR_WINDOWS = raw"C:\Users\porin\OneDrive\Documentos\Python-Mestrado\Modelagem Matemática\Programação Inteira - Uchoa\Problema VRPRDL\instancias_turco\VRPRDL-triangle"

# Se você rodar no WSL/Linux, use este caminho:
const BASE_DIR_WSL = "/mnt/c/Users/porin/OneDrive/Documentos/Python-Mestrado/Modelagem Matemática/Programação Inteira - Uchoa/Problema VRPRDL/instancias_turco/VRPRDL-triangle"

function get_base_dir()
    return normpath(joinpath(@__DIR__, "..", "VRPRDL-triangle"))
end
# =========================================================
# Utilidades de parsing
# =========================================================

"""
Remove comentários iniciados por '#', tira espaços e devolve linha limpa.
"""
function clean_line(line::AbstractString)
    line = replace(line, '\t' => ' ')
    line = split(line, '#'; limit=2)[1]
    return strip(line)
end

"""
Lê arquivo e devolve vetor de linhas já limpas, sem vazias.
"""
function read_clean_lines(filepath::AbstractString)
    raw = readlines(filepath)
    lines = String[]
    for line in raw
        cl = clean_line(line)
        isempty(cl) && continue
        push!(lines, cl)
    end
    return lines
end

"""
Converte um nome de seção em formato mais estável.
"""
function normalize_section_name(s::AbstractString)
    s = lowercase(strip(s))
    s = replace(s, ":" => "")
    return s
end

# =========================================================
# Split em seções
# =========================================================

function split_sections(lines::Vector{String})
    sections = Dict{String, Vector{String}}()
    current = ""

    valid_headers = Set([
        "general parameters",
        "customer schedules",
        "location coordinates",
        "travel time matrix"
    ])

    for line in lines
        lname = normalize_section_name(line)
        if lname in valid_headers
            current = lname
            sections[current] = String[]
        else
            if isempty(current)
                # ignora lixo antes de uma seção válida
                continue
            end
            push!(sections[current], line)
        end
    end

    return sections
end

# =========================================================
# Parsing de cada seção
# =========================================================

function parse_general_parameters(lines::Vector{String})
    isempty(lines) && error("Seção 'General parameters' vazia.")
    parts = split(lines[1])
    length(parts) < 4 && error("Linha de parâmetros gerais inválida: $(lines[1])")

    return Dict(
        "number_of_customers" => parse(Int, parts[1]),
        "number_of_locations" => parse(Int, parts[2]),
        "time_horizon" => parse(Int, parts[3]),
        "vehicle_capacity" => parse(Int, parts[4])
    )
end

"""
Exemplo:
1 75  1 [0,46]  2 [191,264]  3 [409,430]
"""
function parse_customer_schedule_line(line::String)
    # customer_id demand ...
    m = match(r"^(\d+)\s+(\d+)\s+(.*)$", line)
    m === nothing && error("Linha de agenda inválida: $line")

    customer_id = parse(Int, m.captures[1])
    demand = parse(Int, m.captures[2])
    rest = m.captures[3]

    # captura pares: location_id [open,close]
    loc_matches = collect(eachmatch(r"(\d+)\s*\[(\d+),(\d+)\]", rest))

    locations = Vector{Dict{String, Any}}()
    for lm in loc_matches
        push!(locations, Dict(
            "location_id" => parse(Int, lm.captures[1]),
            "time_opening" => parse(Int, lm.captures[2]),
            "time_closing" => parse(Int, lm.captures[3])
        ))
    end

    return Dict(
        "customer_id" => customer_id,
        "demand" => demand,
        "locations" => locations
    )
end

function parse_customer_schedules(lines::Vector{String})
    schedules = Vector{Dict{String, Any}}()
    for line in lines
        push!(schedules, parse_customer_schedule_line(line))
    end
    return schedules
end

"""
Exemplo:
0 0.0 0.0
1 -16.28 -67.68
"""
function parse_location_coordinates(lines::Vector{String})
    coords = Dict{String, Any}()

    for line in lines
        parts = split(line)
        length(parts) < 3 && error("Linha de coordenadas inválida: $line")

        loc_id = parse(Int, parts[1])
        x = parse(Float64, parts[2])
        y = parse(Float64, parts[3])

        coords[string(loc_id)] = Dict(
            "x" => x,
            "y" => y
        )
    end

    return coords
end

"""
Exemplo:
(32, 54) 174
"""
function parse_travel_time_line(line::String)
    m = match(r"^\((\d+),\s*(\d+)\)\s+(\d+)$", line)
    m === nothing && error("Linha de tempo de viagem inválida: $line")

    return Dict(
        "origin_location_id" => parse(Int, m.captures[1]),
        "destination_location_id" => parse(Int, m.captures[2]),
        "travel_time" => parse(Int, m.captures[3])
    )
end

function parse_travel_time_matrix(lines::Vector{String})
    arcs = Vector{Dict{String, Any}}()
    for line in lines
        push!(arcs, parse_travel_time_line(line))
    end
    return arcs
end

# =========================================================
# Parser principal de um arquivo
# =========================================================

function parse_instance_file(filepath::AbstractString)
    lines = read_clean_lines(filepath)
    sections = split_sections(lines)

    required = [
        "general parameters",
        "customer schedules",
        "location coordinates",
        "travel time matrix"
    ]

    for sec in required
        haskey(sections, sec) || error("Seção obrigatória ausente em $(filepath): '$sec'")
    end

    general = parse_general_parameters(sections["general parameters"])
    schedules = parse_customer_schedules(sections["customer schedules"])
    coords = parse_location_coordinates(sections["location coordinates"])
    travel = parse_travel_time_matrix(sections["travel time matrix"])

    return Dict(
        "source_file" => basename(filepath),
        "format" => "VRPRDL_triangle_original",
        "general_parameters" => general,
        "customer_schedules" => schedules,
        "location_coordinates" => coords,
        "travel_time_matrix" => travel
    )
end

# =========================================================
# Conversão em lote
# =========================================================

function should_skip_file(filename::String)
    lname = lowercase(filename)

    # ignora descrições de formato e arquivos que não pareçam instâncias
    if occursin("format", lname) || occursin("description", lname)
        return true
    end

    return !endswith(lname, ".txt")
end

function convert_all_txt_to_json()
    base_dir = get_base_dir()
    input_dir = base_dir
    output_dir = joinpath(base_dir, "json_convertidos")

    isdir(input_dir) || error("Pasta de entrada não encontrada: $input_dir")
    isdir(output_dir) || mkdir(output_dir)

    files = sort(readdir(input_dir))
    converted = 0
    skipped = 0
    failed = 0

    println("========================================")
    println("Pasta de entrada: $input_dir")
    println("Pasta de saída:   $output_dir")
    println("========================================")

    for file in files
        if should_skip_file(file)
            skipped += 1
            continue
        end

        input_path = joinpath(input_dir, file)
        isfile(input_path) || continue

        try
            println("Convertendo: $file")
            parsed = parse_instance_file(input_path)

            json_name = replace(file, r"\.txt$" => ".json")
            output_path = joinpath(output_dir, json_name)

            open(output_path, "w") do io
                JSON3.pretty(io, parsed)
            end

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
    println("Ignorados:   $skipped")
    println("Falharam:    $failed")
    println("========================================")
end

# =========================================================
# Main
# =========================================================

convert_all_txt_to_json()