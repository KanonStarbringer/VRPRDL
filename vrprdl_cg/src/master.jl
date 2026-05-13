# =========================================================
# master.jl
# Restricted Master Problem (RMP) do VRPRDL em JuMP + CPLEX.
#
# Formulação (Set Partitioning):
#
#     min  Σ_r c_r λ_r
#     s.a. Σ_r a_{c,r} λ_r = 1           ∀ c = 1..n
#          λ_r ≥ 0                       (relaxado na CG)
#          λ_r ∈ {0,1}                   (inteiro no final)
#
# onde:
#   - r percorre as rotas do pool
#   - a_{c,r} = 1 se a rota r cobre o cliente c, 0 c.c.
#
# Obs.: usamos "=" (partição). Se preferir cobertura use ">=".
#       Para problemas de set partitioning, relaxar para "<=" +
#       forçar unicidade via IP no fim costuma bastar.
# =========================================================

using JuMP
using CPLEX
import MathOptInterface
const MOI = MathOptInterface

"""
Mantém o estado incremental do RMP: modelo, variáveis, restrições
e espelho das rotas (Route) já inseridas como colunas.
"""
mutable struct RestrictedMaster
    inst::VRPRDLInstance
    model::Model
    # uma variável λ_r para cada rota já inserida
    lambdas::Vector{VariableRef}
    # as rotas, na mesma ordem das lambdas
    routes::Vector{Route}
    # restrições de cobertura, indexadas por customer_id (1..n)
    cover::Vector{ConstraintRef}
    # pega duais rapidamente
    sense::Symbol    # :partition (=) ou :cover (>=)
end

"""
Constrói o RMP vazio (sem colunas). `initial_routes` pode ser vazio e
populado depois via `add_columns!`. Para viabilidade, é ESSENCIAL que
haja ao menos uma rota cobrindo cada cliente em algum momento.
"""
function build_master(inst::VRPRDLInstance;
                      initial_routes::Vector{Route}=Route[],
                      sense::Symbol=:partition,
                      silent::Bool=true)
    @assert sense in (:partition, :cover)

    model = Model(CPLEX.Optimizer)
    silent && set_silent(model)

    # artificial variables para viabilidade caso o pool não cubra tudo
    # (paga uma penalidade grande; vão pra zero se existir solução viável)
    big_M = _estimate_big_M(inst)
    @variable(model, art[1:inst.n_customers] >= 0)
    @objective(model, Min, big_M * sum(art))

    # restrições: uma por cliente
    cover = ConstraintRef[]
    for c in 1:inst.n_customers
        if sense == :partition
            push!(cover, @constraint(model, art[c] == 1))
        else
            push!(cover, @constraint(model, art[c] >= 1))
        end
    end

    rmp = RestrictedMaster(inst, model, VariableRef[], Route[], cover, sense)

    if !isempty(initial_routes)
        add_columns!(rmp, initial_routes)
    end

    return rmp
end

"Heurística simples para o big-M das artificiais."
function _estimate_big_M(inst::VRPRDLInstance)
    # um limite superior razoável: soma de todos os tempos de viagem
    # de ida-volta do depot para todos os locais
    upper = 0
    for c in inst.customers, w in c.locations
        t_go  = get(inst.travel, (inst.depot_start_loc, w.location_id), 0)
        t_ret = get(inst.travel, (w.location_id, inst.depot_end_loc), 0)
        upper += (t_go + t_ret)
    end
    return max(upper, 10^6)
end

"""
Adiciona uma lista de rotas como novas colunas do RMP.
Atualiza todas as estruturas internas (`lambdas`, `routes`, objetivo,
e coeficientes nas restrições de cobertura).
"""
function add_columns!(rmp::RestrictedMaster, new_routes::Vector{Route})
    isempty(new_routes) && return 0
    m = rmp.model
    added = 0

    for r in new_routes
        λ = @variable(m, lower_bound = 0)
        set_name(λ, "lambda_" * string(length(rmp.lambdas) + 1))

        # coeficiente no custo
        set_objective_coefficient(m, λ, r.cost)

        # coeficientes nas restrições de cobertura (um por cliente visitado)
        seen = falses(rmp.inst.n_customers)
        for c in r.customer_seq
            if !seen[c]
                set_normalized_coefficient(rmp.cover[c], λ, 1.0)
                seen[c] = true
            end
        end

        push!(rmp.lambdas, λ)
        push!(rmp.routes, r)
        added += 1
    end

    return added
end

"""
Resolve a relaxação LP do RMP e devolve:
- `status` (termination_status)
- `obj`    (valor ótimo do LP, ou NaN se infeasible)
- `duals`  (vetor de duais das restrições de cobertura, tamanho n)
"""
function solve_rmp_lp!(rmp::RestrictedMaster)
    optimize!(rmp.model)
    st = termination_status(rmp.model)

    if st != MOI.OPTIMAL
        return (st, NaN, fill(NaN, rmp.inst.n_customers))
    end

    obj = objective_value(rmp.model)
    duals = [dual(c) for c in rmp.cover]
    return (st, obj, duals)
end

"""
Resolve o RMP como MIP (fixando λ_r ∈ {0,1} e zerando artificiais).
Retorna (status, obj, selected_routes::Vector{Route}).
"""
function solve_rmp_mip!(rmp::RestrictedMaster; time_limit::Float64=300.0)
    m = rmp.model

    # zera artificiais (fixa em 0 para forçar uso apenas das rotas reais)
    for v in all_variables(m)
        if startswith(name(v), "art[")
            fix(v, 0.0; force=true)
        end
    end

    # binariza λ
    for λ in rmp.lambdas
        set_binary(λ)
    end

    set_time_limit_sec(m, time_limit)
    optimize!(m)
    st = termination_status(m)

    if st ∉ (MOI.OPTIMAL, MOI.TIME_LIMIT)
        return (st, NaN, Route[])
    end

    obj = objective_value(m)
    selected = Route[]
    for (i, λ) in enumerate(rmp.lambdas)
        val = value(λ)
        if val > 0.5
            push!(selected, rmp.routes[i])
        end
    end

    return (st, obj, selected)
end
