# =========================================================
# instance.jl
# Carrega a instância VRPRDL (formato JSON convertido do Özbayğın)
# em estruturas nativas de Julia, prontas para a CG.
# =========================================================

using JSON3

# ---------------------------------------------------------
# Estruturas
# ---------------------------------------------------------

"Uma janela de tempo num local (um par cliente-local)."
struct LocationWindow
    location_id::Int       # id físico do local (chave em location_coordinates)
    time_opening::Int
    time_closing::Int
end

"Um cliente do VRPRDL, com sua demanda e seus locais candidatos."
struct Customer
    id::Int                         # customer_id do JSON (>= 1 para clientes reais)
    demand::Int
    locations::Vector{LocationWindow}
end

"""
Estrutura central com todos os dados de uma instância VRPRDL
já materializados de forma conveniente para acesso rápido.

Atenção à diferença entre:
- `customer_id`  : id do cliente real (1..n)
- `location_id`  : id físico do local (chave do dicionário de coordenadas)
"""
mutable struct VRPRDLInstance
    name::String

    # parâmetros gerais
    n_customers::Int              # número de clientes reais (sem depots)
    n_locations::Int              # número total de locais físicos
    time_horizon::Int
    capacity::Int

    # clientes reais (indexados por customer_id: 1..n_customers)
    customers::Vector{Customer}

    # informações do depot
    depot_start_loc::Int          # location_id do depot inicial
    depot_end_loc::Int            # location_id do depot final (pode coincidir fisicamente)
    depot_end_closing::Int        # janela final (tipicamente = time_horizon)

    # coordenadas (para debug / plot)
    coords::Dict{Int,Tuple{Float64,Float64}}

    # matriz de tempos de viagem: chave (origem_loc, destino_loc) => tempo
    travel::Dict{Tuple{Int,Int},Int}

    # penalidade opcional por tempo de espera (wait_penalized)
    alpha_wait::Float64
end

# ---------------------------------------------------------
# Parsing
# ---------------------------------------------------------

"""
Converte um `customer_schedule` do JSON em um `Customer`.
`is_depot=true` ignora a estrutura de locais múltiplos.
"""
function _parse_customer(raw::Dict{String,Any})
    locs = LocationWindow[]
    for l in raw["locations"]
        push!(locs, LocationWindow(
            Int(l["location_id"]),
            Int(l["time_opening"]),
            Int(l["time_closing"]),
        ))
    end
    return Customer(Int(raw["customer_id"]), Int(raw["demand"]), locs)
end

"""
Carrega uma instância JSON (gerada pelo `converter_instancias_turco_para_json.jl`).

`alpha_wait` é a penalidade por tempo de espera (default 0.0, i.e. espera
permitida e gratuita — equivalente ao Özbayğın). Passe >0 se quiser
desencorajar rotas que esperam muito.
"""
function load_instance(json_path::AbstractString; alpha_wait::Float64=0.0)
    raw = JSON3.read(read(json_path, String), Dict{String,Any})

    gp = raw["general_parameters"]
    n_customers = Int(gp["number_of_customers"])
    n_locations = Int(gp["number_of_locations"])
    time_horizon = Int(gp["time_horizon"])
    capacity = Int(gp["vehicle_capacity"])

    # separa depots (cid=0 e cid=n_customers+1 com demand=0) dos clientes reais
    all_customers = [ _parse_customer(c) for c in raw["customer_schedules"] ]
    depot_start = first(c for c in all_customers if c.id == 0)
    depot_end   = first(c for c in all_customers if c.id == n_customers + 1)

    real_customers = sort!(
        [c for c in all_customers if c.id != 0 && c.id != n_customers + 1];
        by = c -> c.id,
    )

    @assert length(real_customers) == n_customers "inconsistência entre n_customers e lista de clientes"
    @assert all(i -> real_customers[i].id == i, 1:n_customers) "ids dos clientes reais não são 1..n"

    # coordenadas
    coords = Dict{Int,Tuple{Float64,Float64}}()
    for (k, v) in raw["location_coordinates"]
        coords[parse(Int, String(k))] = (Float64(v["x"]), Float64(v["y"]))
    end

    # matriz de tempos
    travel = Dict{Tuple{Int,Int},Int}()
    for arc in raw["travel_time_matrix"]
        o = Int(arc["origin_location_id"])
        d = Int(arc["destination_location_id"])
        travel[(o, d)] = Int(arc["travel_time"])
    end

    return VRPRDLInstance(
        String(raw["source_file"]),
        n_customers,
        n_locations,
        time_horizon,
        capacity,
        real_customers,
        first(depot_start.locations).location_id,
        first(depot_end.locations).location_id,
        first(depot_end.locations).time_closing,
        coords,
        travel,
        alpha_wait,
    )
end

# ---------------------------------------------------------
# Acesso à matriz de tempo (com fallback seguro)
# ---------------------------------------------------------

"""
Devolve o tempo de viagem de `o` para `d`. Se o arco não estiver
no dicionário, devolve `typemax(Int)÷4` (efetivamente inviável).
"""
@inline function travel_time(inst::VRPRDLInstance, o::Int, d::Int)
    v = get(inst.travel, (o, d), nothing)
    return v === nothing ? typemax(Int) ÷ 4 : v
end
