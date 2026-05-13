# =========================================================
# expander.jl
# Dado um *backbone* = sequência ordenada de clientes (produzida
# pelo VRPSolver no CVRP projetado), escolher um local por cliente
# respeitando janelas de tempo, minimizando custo.
#
# Implementação: labeling com front de Pareto (custo, tempo) por
# (estágio, local). Estado dominado é descartado.
# Retorna a melhor (top-1) expansão viável ou nothing.
#
# Custo da rota = soma dos travel_times ao longo dos arcos
#               + alpha_wait * soma dos tempos de espera
# =========================================================

# cada rótulo carrega custo acumulado, tempo de partida desde aquele
# local, e um ponteiro para o rótulo-pai para reconstrução do caminho
struct _Label
    cost::Float64      # custo acumulado (travel + α·wait)
    travel::Int        # travel acumulado
    wait::Int          # wait acumulado
    t_depart::Int      # tempo de partida do local atual (service=0 ⇒ = t_opening-respected-arrival)
    parent::Int        # índice do rótulo-pai no vetor do estágio anterior (0 se é o depot)
    loc::Int           # location_id do local deste estágio
end

"""
Expande um backbone (sequência de customer_ids) em uma rota VRPRDL viável,
minimizando `travel + α_wait · wait`. Retorna `Route` ou `nothing`.

Complexidade: O(n · L^2 · F) onde L = max locais/cliente, F = tamanho do
front de Pareto (tipicamente muito pequeno).
"""
function expand_backbone(inst::VRPRDLInstance, customer_seq::Vector{Int})
    n = length(customer_seq)
    n == 0 && return nothing

    # capacidade: descarte precoce
    demand_total = sum(inst.customers[c].demand for c in customer_seq)
    demand_total > inst.capacity && return nothing

    α = inst.alpha_wait

    # rótulos por estágio: stages[k] = Vector{_Label} dos rótulos ao chegar no cliente k
    # estágio 0 = depot_start (único rótulo)
    stages = Vector{Vector{_Label}}()
    push!(stages, [_Label(0.0, 0, 0, 0, 0, inst.depot_start_loc)])

    for k in 1:n
        cust = inst.customers[customer_seq[k]]
        new_labels = _Label[]

        for (pidx, plab) in enumerate(stages[k])
            for win in cust.locations
                tt = travel_time(inst, plab.loc, win.location_id)
                tt >= typemax(Int) ÷ 4 && continue

                arrival = plab.t_depart + tt
                arrival > win.time_closing && continue
                w = max(0, win.time_opening - arrival)
                depart = arrival + w  # service time = 0

                lbl = _Label(
                    plab.cost + tt + α * w,
                    plab.travel + tt,
                    plab.wait + w,
                    depart,
                    pidx,
                    win.location_id,
                )
                push!(new_labels, lbl)
            end
        end

        isempty(new_labels) && return nothing

        # poda por dominância: agrupa por local e remove dominados
        # (c, t) domina (c', t') se c <= c' AND t <= t' (com pelo menos 1 estrito)
        kept = _prune_dominated(new_labels)
        push!(stages, kept)
    end

    # último arco: para o depot final
    best = nothing
    best_parent = 0
    for (pidx, lab) in enumerate(stages[end])
        tt = travel_time(inst, lab.loc, inst.depot_end_loc)
        tt >= typemax(Int) ÷ 4 && continue

        arrival = lab.t_depart + tt
        arrival > inst.depot_end_closing && continue

        final_cost = lab.cost + tt
        if best === nothing || final_cost < best.cost
            best = _Label(final_cost, lab.travel + tt, lab.wait, arrival, pidx, inst.depot_end_loc)
            best_parent = pidx
        end
    end

    best === nothing && return nothing

    # reconstrução: anda de trás pra frente recolhendo location_ids
    location_seq = Vector{Int}(undef, n)
    idx = best_parent
    for k in n:-1:1
        lab = stages[k+1][idx]
        location_seq[k] = lab.loc
        idx = lab.parent
    end

    return Route(
        copy(customer_seq),
        location_seq,
        best.cost,
        best.travel,
        best.wait,
        demand_total,
        best.t_depart,   # tempo de chegada no depot final
    )
end

# ---------------------------------------------------------
# poda por dominância dentro de um estágio
# ---------------------------------------------------------

"""
Remove rótulos dominados, agrupando por `loc`.
Dentro de um mesmo local, (c, t) domina (c', t') se c ≤ c' e t ≤ t'
(com pelo menos uma desigualdade estrita).
"""
function _prune_dominated(labels::Vector{_Label})
    # agrupa por local
    by_loc = Dict{Int,Vector{Int}}()
    for (i, l) in enumerate(labels)
        push!(get!(by_loc, l.loc, Int[]), i)
    end

    keep = falses(length(labels))
    for (_, idxs) in by_loc
        # ordena por (cost, t_depart); depois mantém um varredura de t mínimo
        sort!(idxs; by = i -> (labels[i].cost, labels[i].t_depart))
        best_t = typemax(Int)
        for i in idxs
            if labels[i].t_depart < best_t
                keep[i] = true
                best_t = labels[i].t_depart
            end
        end
    end

    return labels[keep]
end
