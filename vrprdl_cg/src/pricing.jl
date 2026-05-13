# =========================================================
# pricing.jl
# Pricing como *filtro* sobre um pool de rotas pré-geradas.
#
# Idéia: o VRPSolver (+ expander) nos deu um pool P de rotas
# VRPRDL viáveis. A cada iteração da CG, dado o vetor de duais
# π, calculamos o custo reduzido de cada rota ainda não
# inserida no RMP e retornamos as "mais promissoras"
# (custo reduzido < -ε), até `max_add` colunas.
#
# Este NÃO é um pricer exato para o VRPRDL — é um heurístico
# que explora um pool finito. Substituível futuramente por
# um RCSP exato ou pelo próprio VRPSolver em modo online.
# =========================================================

"""
Custo reduzido de uma rota `r` dado o vetor de duais `π` (de tamanho n_customers).
rc = c_r - Σ_{c ∈ r} π_c
"""
function reduced_cost(r::Route, π::Vector{Float64})
    s = 0.0
    for c in r.customer_seq
        s += π[c]
    end
    return r.cost - s
end

"""
Filtra um pool para as rotas com menor custo reduzido.
- `already_in`: rotas já dentro do RMP (evita duplicar)
- `eps`: tolerância para considerar rc negativo
- `max_add`: quantas rotas no máximo retornar por chamada
Devolve as rotas escolhidas, ordenadas por rc ascendente.
"""
function price_from_pool(pool::Vector{Route},
                         π::Vector{Float64},
                         already_in::Set{Tuple{Vector{Int},Vector{Int}}};
                         eps::Float64=1e-6,
                         max_add::Int=50)
    cand = Tuple{Float64,Route}[]
    for r in pool
        key = (r.customer_seq, r.location_seq)
        key in already_in && continue
        rc = reduced_cost(r, π)
        if rc < -eps
            push!(cand, (rc, r))
        end
    end

    sort!(cand; by = x -> x[1])
    n_take = min(length(cand), max_add)
    return [cand[i][2] for i in 1:n_take]
end
