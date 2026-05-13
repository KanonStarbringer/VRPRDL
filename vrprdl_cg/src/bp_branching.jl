# =========================================================
# bp_branching.jl
# Mapeamento e *hooks* para Branch-and-Price no estilo Özbayğın et al. (2017),
# Sec. 3.3: ramificar em arcos da formulação compacta; filtrar colunas;
# proibir arcos no grafo do pricing.
#
# Convenção de arco (espelho do paper, adaptado ao JSON VRPRDL):
#   `LocArc = (location_id_from, location_id_to)` — transição consecutiva
#   numa rota, incluindo depots (`inst.depot_start_loc`, `inst.depot_end_loc`).
#
# O grafo BG em `pricing_bucket.jl` usa um vértice por par (cliente, local);
# cada arco BG corresponde a um `LocArc` único (origem/destino físicos).
#
# Implementação parcial (extensível):
#   - Ramo "proibir (i,j)": acrescenta só o arco (li,lj) ao conjunto proibido.
#   - Ramo "forçar (i,j)": proíbe (δ+(i)\\{(i,j)}) ∪ (δ-(j)\\{(i,j)}) em termos
#     de `location_id`, derivado das chaves de `inst.travel`.
#   - O termo extra com δ-(l) para l ∈ (N_c(i)\\{i}) ∪ (N_c(j)\\{j}) do artigo
#     pode ser acrescentado depois se necessário (depende da duplicação exata
#     de nós no grafo do paper vs. o nosso).
# =========================================================

using JuMP

"""Arco elementar no espaço de `location_id` (como na Sec. 3.3 do artigo)."""
const LocArc = Tuple{Int,Int}

"""
Estado de ramificação acumulado num nó da árvore B&P: arcos locais que não
podem aparecer como transição consecutiva em nenhuma rota / coluna.
"""
mutable struct BPNodeState
    forbidden_loc_arcs::Set{LocArc}
end

BPNodeState() = BPNodeState(Set{LocArc}())

Base.copy(s::BPNodeState) = BPNodeState(copy(s.forbidden_loc_arcs))

function Base.union!(s::BPNodeState, arcs::AbstractVector{LocArc})
    for a in arcs
        push!(s.forbidden_loc_arcs, a)
    end
    return s
end

function Base.union!(s::BPNodeState, o::Set{LocArc})
    union!(s.forbidden_loc_arcs, o)
    return s
end

"""Sequência de `LocArc` ao longo da rota `r` (depot inicial → … → depot final)."""
function route_loc_arcs(inst::VRPRDLInstance, r::Route)::Vector{LocArc}
    arcs = LocArc[]
    isempty(r.customer_seq) && return arcs
    prev = inst.depot_start_loc
    for (c, l) in zip(r.customer_seq, r.location_seq)
        push!(arcs, (prev, l))
        prev = l
    end
    push!(arcs, (prev, inst.depot_end_loc))
    return arcs
end

function route_uses_loc_arc(r::Route, inst::VRPRDLInstance, a::LocArc)
    return a in route_loc_arcs(inst, r)
end

"""True se a rota usa algum arco proibido."""
function route_violates_bp(r::Route, inst::VRPRDLInstance, st::BPNodeState)
    isempty(st.forbidden_loc_arcs) && return false
    for a in route_loc_arcs(inst, r)
        a in st.forbidden_loc_arcs && return true
    end
    return false
end

"""Filtra vetor de rotas incompatíveis com o nó."""
function filter_routes_bp(routes::Vector{Route}, inst::VRPRDLInstance, st::BPNodeState)
    isempty(st.forbidden_loc_arcs) && return routes
    return Route[r for r in routes if !route_violates_bp(r, inst, st)]
end

function _outgoing_neighbors(inst::VRPRDLInstance, loc_i::Int)
    nbr = Int[]
    for (a, b) in keys(inst.travel)
        a == loc_i && push!(nbr, b)
    end
    return unique!(sort!(nbr))
end

function _incoming_neighbors(inst::VRPRDLInstance, loc_j::Int)
    nbr = Int[]
    for (a, b) in keys(inst.travel)
        b == loc_j && push!(nbr, a)
    end
    return unique!(sort!(nbr))
end

"""Ramo filho em que o arco (li,lj) é proibido (Sec. 3.3)."""
function bp_child_forbid_arc!(child::BPNodeState, li::Int, lj::Int)
    push!(child.forbidden_loc_arcs, (li, lj))
    return child
end

"""
Ramo filho em que o arco (li,lj) é **forçado**: proíbe-se os outros arcos que
saem de `li` (exceto (li,lj)) e os que entram em `lj` (exceto (li,lj)),
como no artigo (primeiros dois termos da união).
"""
function bp_child_force_arc!(child::BPNodeState, inst::VRPRDLInstance, li::Int, lj::Int)
    for k in _outgoing_neighbors(inst, li)
        k == lj && continue
        push!(child.forbidden_loc_arcs, (li, k))
    end
    for k in _incoming_neighbors(inst, lj)
        k == li && continue
        push!(child.forbidden_loc_arcs, (k, lj))
    end
    # Terceiro termo do paper (δ-(l) para l em outros nós do mesmo cliente):
    cust_i = _customer_at_location(inst, li)
    cust_j = _customer_at_location(inst, lj)
    for l in _sibling_locations(inst, cust_i, li)
        for k in _incoming_neighbors(inst, l)
            push!(child.forbidden_loc_arcs, (k, l))
        end
    end
    for l in _sibling_locations(inst, cust_j, lj)
        for k in _incoming_neighbors(inst, l)
            push!(child.forbidden_loc_arcs, (k, l))
        end
    end
    return child
end

function _customer_at_location(inst::VRPRDLInstance, loc::Int)
    loc == inst.depot_start_loc && return 0
    loc == inst.depot_end_loc && return 0
    for c in 1:inst.n_customers
        for w in inst.customers[c].locations
            w.location_id == loc && return c
        end
    end
    return 0
end

"""Outros `location_id` do mesmo cliente (exclui `loc`)."""
function _sibling_locations(inst::VRPRDLInstance, customer::Int, loc::Int)::Vector{Int}
    customer <= 0 && return Int[]
    out = Int[]
    for w in inst.customers[customer].locations
        w.location_id == loc && continue
        push!(out, w.location_id)
    end
    return out
end

"""
Fluxo agregado `x_ij = Σ_r z_r` sobre arcos `LocArc` (soma dos `value(λ_r)`
das rotas que contêm o arco). Só válido após `solve_rmp_lp!` com status ótimo.
"""
function aggregate_loc_arc_flows(rmp::RestrictedMaster)::Dict{LocArc,Float64}
    flows = Dict{LocArc,Float64}()
    inst = rmp.inst
    for (λ, r) in zip(rmp.lambdas, rmp.routes)
        v = value(λ)
        v <= 1e-9 && continue
        for a in route_loc_arcs(inst, r)
            flows[a] = get(flows, a, 0.0) + v
        end
    end
    return flows
end

"""
Escolhe um arco de ramificação **CB** (mais próximo de 0.5), só entre arcos
com ambos extremos em locais de **cliente** (não depot), valor &lt; 1,
como na Sec. 3.3.
"""
function pick_branch_arc_cb(inst::VRPRDLInstance, flows::Dict{LocArc,Float64})
    best = nothing
    best_dist = Inf
    for ((li, lj), fv) in flows
        (0.0 < fv < 1.0) || continue
        _customer_at_location(inst, li) == 0 && continue
        _customer_at_location(inst, lj) == 0 && continue
        d = abs(fv - 0.5)
        if d < best_dist
            best_dist = d
            best = (li, lj)
        end
    end
    return best  # `nothing` se não houver candidato
end
