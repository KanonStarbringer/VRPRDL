# =========================================================
# vrpsolver_bridge.jl
# Integração OFFLINE com o VRPSolver (VRPSolverDemos).
#
# Estratégia: o VRPSolver já rodou no CVRP projetado (via
# `rodar_vrps_turco.sh`), deixando logs em `logs_vrp_convertidos/`.
# Este módulo faz apenas o parse desses logs para extrair os
# *backbones* (sequências de clientes) que servirão de entrada
# para o expander VRPRDL.
#
# Convenção importante (validada nos logs): o VRPSolver imprime
# as rotas como "Route #k: id1 id2 ..." onde cada id é o
# customer_id do VRPRDL (1..n), *não* o nó .vrp.
# =========================================================

"""
Um backbone = uma sequência de clientes produzida pelo VRPSolver
no CVRP projetado. Mantemos também o índice da rota (1,2,...)
e o custo bruto reportado (para fins informativos).
"""
struct VRPSolverBackbone
    customer_seq::Vector{Int}
    route_index::Int              # #1, #2, ... no log
    raw_cost::Union{Int,Nothing}  # "Cost XXX" quando presente
end

"""
Lê um log de uma única instância e extrai todas as rotas
(`Route #k: ...`) bem como o `Cost` final (comum às rotas).
"""
function parse_vrpsolver_log(log_path::AbstractString)
    isfile(log_path) || error("Log não encontrado: $log_path")

    backbones = VRPSolverBackbone[]
    cost = nothing

    for line in eachline(log_path)
        ls = strip(line)

        m = match(r"^Route\s+#(\d+)\s*:\s*(.+)$", ls)
        if m !== nothing
            idx = parse(Int, m.captures[1])
            ids = [parse(Int, s) for s in split(strip(m.captures[2])) if !isempty(s)]
            push!(backbones, VRPSolverBackbone(ids, idx, nothing))
            continue
        end

        mc = match(r"^Cost\s+(\d+)", ls)
        if mc !== nothing
            cost = parse(Int, mc.captures[1])
        end
    end

    # propaga o `Cost` para todos os backbones (informativo apenas)
    if cost !== nothing
        for i in eachindex(backbones)
            backbones[i] = VRPSolverBackbone(
                backbones[i].customer_seq,
                backbones[i].route_index,
                cost,
            )
        end
    end

    return backbones
end

"""
Gera backbones extras a partir de um conjunto base, usando heurísticas
locais simples que preservam a partição de clientes por veículo.
Isto é *opcional*: enriquece o pool inicial com variações.

- reversão (`[a,b,c,d] → [d,c,b,a]`): simétrica em instâncias triangulares
  pode ter custo diferente por conta das janelas, então vale testar.
- 2-opt simples (swap de pares adjacentes em posições internas).

Retorna uma lista de backbones adicionais (sem duplicatas com a original).
"""
function generate_variants(backbone::VRPSolverBackbone; k_2opt::Int=3)
    seq = backbone.customer_seq
    n = length(seq)
    n <= 2 && return VRPSolverBackbone[]

    seen = Set{Vector{Int}}()
    push!(seen, seq)
    variants = VRPSolverBackbone[]

    # reversão completa
    rev = reverse(seq)
    if rev ∉ seen
        push!(seen, rev)
        push!(variants, VRPSolverBackbone(rev, backbone.route_index, backbone.raw_cost))
    end

    # alguns swaps de pares adjacentes
    swaps_done = 0
    for i in 1:(n-1)
        swaps_done >= k_2opt && break
        new_seq = copy(seq)
        new_seq[i], new_seq[i+1] = new_seq[i+1], new_seq[i]
        if new_seq ∉ seen
            push!(seen, new_seq)
            push!(variants, VRPSolverBackbone(new_seq, backbone.route_index, backbone.raw_cost))
            swaps_done += 1
        end
    end

    return variants
end

"""
Monta o pool inicial de *rotas VRPRDL viáveis* a partir dos backbones de um log.
Cada backbone passa pelo `expand_backbone`; só entram no pool os que produzem
rota viável.

Também inclui as *singletons* (uma rota por cliente) como garantia de
viabilidade do RMP.

Opcionalmente, também tenta variantes simples (reverse + swaps).
"""
function build_initial_pool(inst::VRPRDLInstance,
                            backbones::Vector{VRPSolverBackbone};
                            use_variants::Bool=true,
                            verbose::Bool=true)
    pool = Route[]
    seen = Set{Tuple{Vector{Int},Vector{Int}}}()

    function _try_add!(seq::Vector{Int})
        r = expand_backbone(inst, seq)
        r === nothing && return false
        key = (r.customer_seq, r.location_seq)
        key in seen && return false
        push!(seen, key)
        push!(pool, r)
        return true
    end

    # (a) backbones do VRPSolver (inteiros)
    n_from_bb = 0
    for bb in backbones
        _try_add!(bb.customer_seq) && (n_from_bb += 1)
        if use_variants
            for v in generate_variants(bb)
                _try_add!(v.customer_seq) && (n_from_bb += 1)
            end
        end
    end

    # (b) singletons — garantia de viabilidade da partição no RMP
    n_singletons = 0
    for c in 1:inst.n_customers
        _try_add!([c]) && (n_singletons += 1)
    end

    if verbose
        println("[pool] rotas do VRPSolver/variantes: ", n_from_bb)
        println("[pool] singletons viáveis           : ", n_singletons, " / ", inst.n_customers)
        println("[pool] total inicial                : ", length(pool))
    end

    return pool
end
