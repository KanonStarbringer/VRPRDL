using Unicode: Unicode
using Printf

mutable struct StopWindow
    location_id::Int
    open::Float64
    close::Float64
end

mutable struct Location
    id::Int
    customer_id::Int
    x::Float64
    y::Float64
    open::Float64
    close::Float64
end

mutable struct DataVRPRDL
    name::String
    n_customers::Int                  # clientes reais (sem os depósitos)
    n_locations::Int                  # número total de localizações do arquivo
    horizon::Float64
    capacity::Float64
    source_customer::Int
    sink_customer::Int
    source_loc::Int
    sink_loc::Int
    real_customers::Vector{Int}
    all_customers::Vector{Int}
    locations::Dict{Int,Location}     # todas as localizações do arquivo
    active_locations::Vector{Int}     # localizações após pré-processamento
    locs_of_customer::Dict{Int,Vector{Int}}  # localizações ativas por cliente
    demand_of_customer::Dict{Int,Float64}
    travel_time::Dict{Tuple{Int,Int},Float64}
    travel_cost::Dict{Tuple{Int,Int},Float64}
    arcs::Vector{Tuple{Int,Int}}
end

locidx(i::Integer) = Int(i) + 1
contains(p, s) = findnext(s, p, 1) !== nothing

function _assert(cond::Bool, msg::AbstractString)
    cond || error(msg)
end

strip_comment(line::AbstractString) = strip(replace(line, r"#.*$" => ""))

function _parse_general_parameters(line::AbstractString)
    toks = split(line)
    _assert(length(toks) == 4,
        "A linha de parâmetros gerais deve conter 4 valores: n_customers n_locations horizon capacity")
    return parse(Int, toks[1]), parse(Int, toks[2]), parse(Float64, toks[3]), parse(Float64, toks[4])
end

function _parse_customer_schedule(line::AbstractString)
    toks = split(line)
    _assert(length(toks) >= 4, "Linha inválida em Customer schedules: '$line'")
    customer_id = parse(Int, toks[1])
    demand = parse(Float64, toks[2])
    stops = StopWindow[]
    rx = r"(\d+)\s*\[\s*([-+]?\d+(?:\.\d+)?)\s*,\s*([-+]?\d+(?:\.\d+)?)\s*\]"
    for m in eachmatch(rx, line)
        push!(stops,
            StopWindow(
                parse(Int, m.captures[1]),
                parse(Float64, m.captures[2]),
                parse(Float64, m.captures[3]),
            ))
    end
    _assert(!isempty(stops), "Nenhuma localização encontrada na linha '$line'")
    return customer_id, demand, stops
end

function _parse_coordinate_line(line::AbstractString)
    m = match(r"^(\d+)\s+([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s+([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)$", line)
    _assert(m !== nothing, "Linha inválida em Location coordinates: '$line'")
    return parse(Int, m.captures[1]), parse(Float64, m.captures[2]), parse(Float64, m.captures[3])
end

function _parse_tt_line(line::AbstractString)
    m = match(r"^\(\s*(\d+)\s*,\s*(\d+)\s*\)\s+([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)$", line)
    _assert(m !== nothing, "Linha inválida em Travel time matrix: '$line'")
    return parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Float64, m.captures[3])
end

function _euclidean_rounded(xi::Float64, yi::Float64, xj::Float64, yj::Float64)
    return floor(sqrt((xi - xj)^2 + (yi - yj)^2) + 0.5)
end

function _build_metric_closure_cost(coords::Dict{Int,Tuple{Float64,Float64}}, n_locations::Int)
    # Artigo: custo = distância euclidiana arredondada, seguida do menor caminho
    # entre cada par para garantir desigualdade triangular.
    D = fill(Inf, n_locations, n_locations)
    for i in 0:(n_locations - 1)
        D[locidx(i), locidx(i)] = 0.0
    end
    for i in 0:(n_locations - 1), j in 0:(n_locations - 1)
        xi, yi = coords[i]
        xj, yj = coords[j]
        D[locidx(i), locidx(j)] = _euclidean_rounded(xi, yi, xj, yj)
    end
    for k in 1:n_locations
        @inbounds for i in 1:n_locations
            dik = D[i, k]
            for j in 1:n_locations
                alt = dik + D[k, j]
                if alt < D[i, j]
                    D[i, j] = alt
                end
            end
        end
    end
    cost = Dict{Tuple{Int,Int},Float64}()
    for i in 0:(n_locations - 1), j in 0:(n_locations - 1)
        cost[(i, j)] = D[locidx(i), locidx(j)]
    end
    return cost
end

function _is_active_node(locations::Dict{Int,Location}, travel_time::Dict{Tuple{Int,Int},Float64}, horizon::Float64, source_loc::Int, sink_loc::Int, loc::Int)
    loc == source_loc && return true
    loc == sink_loc && return true
    node = locations[loc]
    ei = node.open
    li = node.close
    t0i = travel_time[(source_loc, loc)]
    ti0 = travel_time[(loc, sink_loc)]
    # Preprocessamento do artigo.
    if t0i > li
        return false
    end
    if ei + ti0 > horizon
        return false
    end
    return true
end

function readVRPRDLData(app::Dict{String,Any})
    lines = readlines(app["instance"])
    name = splitext(basename(app["instance"]))[1]

    section = :none
    n_customers = 0
    n_locations = 0
    horizon = 0.0
    capacity = 0.0

    schedule = Dict{Int,Vector{StopWindow}}()
    demand_of_customer = Dict{Int,Float64}()
    coords = Dict{Int,Tuple{Float64,Float64}}()
    travel_time = Dict{Tuple{Int,Int},Float64}()

    for raw in lines
        line = strip_comment(Unicode.normalize(raw; stripcc=true))
        isempty(line) && continue
        lower = lowercase(line)
        if startswith(lower, "general parameters")
            section = :general
            continue
        elseif startswith(lower, "customer schedules")
            section = :schedule
            continue
        elseif startswith(lower, "location coordinates")
            section = :coords
            continue
        elseif startswith(lower, "travel time matrix")
            section = :tt
            continue
        end

        if section == :general
            n_customers, n_locations, horizon, capacity = _parse_general_parameters(line)
            section = :general_done
        elseif section == :schedule
            c, dmd, stops = _parse_customer_schedule(line)
            schedule[c] = stops
            demand_of_customer[c] = dmd
        elseif section == :coords
            loc, x, y = _parse_coordinate_line(line)
            coords[loc] = (x, y)
        elseif section == :tt
            i, j, tij = _parse_tt_line(line)
            travel_time[(i, j)] = tij
        else
            error("Linha fora de seção reconhecida: '$line'")
        end
    end

    _assert(n_customers > 0, "Falha ao ler General parameters")
    _assert(!isempty(schedule), "Nenhuma linha lida em Customer schedules")

    all_customers = sort!(collect(keys(schedule)))
    _assert(length(all_customers) >= 3, "Era esperado ao menos depósito inicial, clientes reais e depósito final")
    source_customer = first(all_customers)
    sink_customer = last(all_customers)
    real_customers = [c for c in all_customers if c != source_customer && c != sink_customer]
    _assert(length(real_customers) == n_customers,
        "O arquivo informa $n_customers clientes, mas foram encontrados $(length(real_customers)) clientes reais")

    _assert(length(schedule[source_customer]) == 1, "O depósito inicial deve ter exatamente uma localização")
    _assert(length(schedule[sink_customer]) == 1, "O depósito final deve ter exatamente uma localização")
    source_loc = schedule[source_customer][1].location_id
    sink_loc = schedule[sink_customer][1].location_id

    locations = Dict{Int,Location}()
    seen_locs = Set{Int}()

    for c in all_customers
        for st in schedule[c]
            _assert(0 <= st.location_id < n_locations,
                "location_id=$(st.location_id) fora do intervalo 0..$(n_locations - 1)")
            _assert(st.open <= st.close,
                "Janela inválida na localização $(st.location_id): [$(st.open), $(st.close)]")
            xy = get(coords, st.location_id, nothing)
            _assert(xy !== nothing, "Faltam coordenadas para a localização $(st.location_id)")
            x, y = xy
            locations[st.location_id] = Location(st.location_id, c, x, y, st.open, st.close)
            push!(seen_locs, st.location_id)
        end
    end

    _assert(length(seen_locs) == n_locations,
        "Foram encontradas $(length(seen_locs)) localizações em Customer schedules, mas o cabeçalho informa $n_locations")
    _assert(length(coords) == n_locations,
        "Foram encontradas $(length(coords)) coordenadas, mas o cabeçalho informa $n_locations localizações")

    for i in 0:(n_locations - 1), j in 0:(n_locations - 1)
        _assert(haskey(travel_time, (i, j)), "A matriz de tempos está incompleta: falta o arco ($i,$j)")
    end

    travel_cost = _build_metric_closure_cost(coords, n_locations)

    active_locations = Int[]
    for loc in sort!(collect(keys(locations)))
        if _is_active_node(locations, travel_time, horizon, source_loc, sink_loc, loc)
            push!(active_locations, loc)
        end
    end

    active_set = Set(active_locations)
    locs_of_customer = Dict{Int,Vector{Int}}()
    for c in all_customers
        locs = [st.location_id for st in schedule[c] if st.location_id in active_set]
        if c in real_customers
            _assert(!isempty(locs), "O cliente $c perdeu todas as localizações após o pré-processamento")
        else
            _assert(length(locs) == 1, "O depósito deve permanecer com uma única localização ativa")
        end
        locs_of_customer[c] = locs
    end

    data = DataVRPRDL(
        name,
        n_customers,
        n_locations,
        horizon,
        capacity,
        source_customer,
        sink_customer,
        source_loc,
        sink_loc,
        real_customers,
        all_customers,
        locations,
        active_locations,
        locs_of_customer,
        demand_of_customer,
        travel_time,
        travel_cost,
        Tuple{Int,Int}[],
    )
    data.arcs = build_arcs(data)
    return data
end

real_customers(data::DataVRPRDL) = data.real_customers
all_locations(data::DataVRPRDL) = data.active_locations
nb_customers(data::DataVRPRDL) = data.n_customers
veh_capacity(data::DataVRPRDL) = data.capacity
planning_horizon(data::DataVRPRDL) = data.horizon
locs_of_customer(data::DataVRPRDL, c::Int) = data.locs_of_customer[c]
customer_of_loc(data::DataVRPRDL, loc::Int) = data.locations[loc].customer_id
l(data::DataVRPRDL, loc::Int) = data.locations[loc].open
u(data::DataVRPRDL, loc::Int) = data.locations[loc].close
xcoord(data::DataVRPRDL, loc::Int) = data.locations[loc].x
ycoord(data::DataVRPRDL, loc::Int) = data.locations[loc].y

function d(data::DataVRPRDL, loc::Int)
    cst = customer_of_loc(data, loc)
    if cst == data.source_customer || cst == data.sink_customer
        return 0.0
    end
    return data.demand_of_customer[cst]
end

arcs(data::DataVRPRDL) = data.arcs
c(data::DataVRPRDL, a::Tuple{Int,Int}) = data.travel_cost[a]
t(data::DataVRPRDL, a::Tuple{Int,Int}) = data.travel_time[a]

function lowerBoundNbVehicles(data::DataVRPRDL)
    total_demand = sum(data.demand_of_customer[c] for c in data.real_customers)
    return max(1, Int(ceil(total_demand / data.capacity)))
end

function upperBoundNbVehicles(data::DataVRPRDL)
    return data.n_customers
end

function earliest_feasible_arrival(data::DataVRPRDL, i::Int, j::Int)
    return max(l(data, j), l(data, i) + t(data, (i, j)))
end

function is_feasible_arc(data::DataVRPRDL, i::Int, j::Int; atol::Float64 = 1e-9)
    i == j && return false
    j == data.source_loc && return false
    i == data.sink_loc && return false
    (i == data.source_loc && j == data.sink_loc) && return false
    (i in data.active_locations) || return false
    (j in data.active_locations) || return false

    ci = customer_of_loc(data, i)
    cj = customer_of_loc(data, j)
    if ci == cj && ci != data.source_customer && ci != data.sink_customer
        return false
    end

    ei = l(data, i)
    lj = u(data, j)
    t0i = t(data, (data.source_loc, i))
    tij = t(data, (i, j))
    tj0 = t(data, (j, data.sink_loc))
    earliest_at_i = max(t0i, ei)

    if earliest_at_i + tij > lj + atol
        return false
    end
    if earliest_at_i + tij + tj0 > planning_horizon(data) + atol
        return false
    end
    return true
end

function build_arcs(data::DataVRPRDL)
    A = Tuple{Int,Int}[]
    V = all_locations(data)
    for i in V, j in V
        if is_feasible_arc(data, i, j)
            push!(A, (i, j))
        end
    end
    return A
end

function cluster_distance_matrix(data::DataVRPRDL)
    customers = data.real_customers
    m = length(customers)
    matrix = [fill(0.0, m) for _ in 1:m]
    for (pi, ci) in enumerate(customers)
        Li = data.locs_of_customer[ci]
        for (pj, cj) in enumerate(customers)
            if pi == pj
                matrix[pi][pj] = 0.0
                continue
            end
            Lj = data.locs_of_customer[cj]
            best = Inf
            for i in Li, j in Lj
                cij = get(data.travel_cost, (i, j), Inf)
                if cij < best
                    best = cij
                end
            end
            matrix[pi][pj] = best
        end
    end
    return matrix
end

function summarize_instance(data::DataVRPRDL)
    avg_locs = sum(length(data.locs_of_customer[c]) for c in data.real_customers) / max(1, data.n_customers)
    io = IOBuffer()
    println(io, "Instância: ", data.name)
    println(io, "Clientes reais: ", data.n_customers)
    println(io, "Localizações totais no arquivo: ", data.n_locations)
    println(io, "Localizações ativas após pré-processamento: ", length(data.active_locations))
    println(io, "Horizonte: ", data.horizon)
    println(io, "Capacidade: ", data.capacity)
    println(io, "Depósito inicial: cliente ", data.source_customer, ", loc ", data.source_loc)
    println(io, "Depósito final: cliente ", data.sink_customer, ", loc ", data.sink_loc)
    println(io, @sprintf("Média de localizações ativas por cliente: %.2f", avg_locs))
    println(io, "Arcos viáveis: ", length(data.arcs))
    return String(take!(io))
end
