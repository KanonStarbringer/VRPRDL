# =========================================================
# route.jl
# Estrutura de uma rota VRPRDL pronta para ser uma coluna do RMP.
# =========================================================

"""
Uma rota VRPRDL *viável* e já expandida, i.e.:
- sequência de clientes (`customer_seq`)
- sequência de locais escolhidos para cada cliente (`location_seq`, mesmo tamanho)
- custo total (distância/tempo de viagem + α·espera)
- tempo de partida do depot até retorno (para debug)

Invariante:
- `length(customer_seq) == length(location_seq)`
- demanda_total <= capacidade
- janela de cada local é respeitada
- o depot inicial e o depot final NÃO entram em `customer_seq`
"""
struct Route
    customer_seq::Vector{Int}    # ids dos clientes VRPRDL (1..n)
    location_seq::Vector{Int}    # location_id escolhido para cada cliente
    cost::Float64                # custo de viagem + α·espera
    travel_cost::Int             # só o tempo/distância
    wait_total::Int              # tempo total de espera na rota
    demand_total::Int
    arrival_end::Int             # tempo de chegada no depot final
end

"id 'canônico' para dedup de rotas no pool (sequência de clientes + locais)."
route_key(r::Route) = (copy(r.customer_seq), copy(r.location_seq))

"""
Recalcula (ou valida) o custo/viabilidade de uma rota dada uma instância.
Retorna `(feasible::Bool, route_or_nothing)`.

Assume service time = 0 no local (modelo padrão do Özbayğın).
Espera permitida — se `alpha_wait > 0`, é penalizada no custo.
"""
function build_route(inst::VRPRDLInstance,
                     customer_seq::Vector{Int},
                     location_seq::Vector{Int})
    @assert length(customer_seq) == length(location_seq)
    isempty(customer_seq) && return (false, nothing)

    # capacidade
    demand_total = sum(inst.customers[c].demand for c in customer_seq)
    demand_total > inst.capacity && return (false, nothing)

    travel = 0
    wait   = 0
    t      = 0  # tempo de partida do depot
    prev_loc = inst.depot_start_loc

    for (c, l) in zip(customer_seq, location_seq)
        tt = travel_time(inst, prev_loc, l)
        tt >= typemax(Int) ÷ 4 && return (false, nothing)

        arrival = t + tt
        # descobre a janela desse (cliente, local)
        cust = inst.customers[c]
        win_idx = findfirst(w -> w.location_id == l, cust.locations)
        win_idx === nothing && return (false, nothing)  # local não pertence a esse cliente
        win = cust.locations[win_idx]

        arrival > win.time_closing && return (false, nothing)
        w = max(0, win.time_opening - arrival)
        wait   += w
        travel += tt
        t       = arrival + w   # service time = 0 → parte assim que a janela abre

        prev_loc = l
    end

    # retorno ao depot final
    tt_end = travel_time(inst, prev_loc, inst.depot_end_loc)
    tt_end >= typemax(Int) ÷ 4 && return (false, nothing)
    arrival_end = t + tt_end
    arrival_end > inst.depot_end_closing && return (false, nothing)
    travel += tt_end

    cost = travel + inst.alpha_wait * wait
    return (true, Route(copy(customer_seq),
                        copy(location_seq),
                        cost,
                        travel,
                        wait,
                        demand_total,
                        arrival_end))
end

"Imprime uma rota de forma amigável no log."
function Base.show(io::IO, r::Route)
    print(io, "Route(n=", length(r.customer_seq),
              ", cost=", round(r.cost; digits=2),
              ", travel=", r.travel_cost,
              ", wait=", r.wait_total,
              ", demand=", r.demand_total, ")")
end
