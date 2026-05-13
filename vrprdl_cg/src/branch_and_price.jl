using Printf
import MathOptInterface
const MOI_BP = MathOptInterface

Base.@kwdef mutable struct BPConfig
    cg_cfg::CGConfig = CGConfig(pricing_mode=:bucket_graph, verbose=false)
    max_nodes::Int = 200
    max_depth::Int = 50
    node_mip_time_limit::Float64 = 30.0
    dfs::Bool = true
    verbose::Bool = true
end

struct BPResult
    best_obj::Float64
    best_status::Any
    best_routes::Vector{Route}
    nodes_processed::Int
    nodes_pruned::Int
    elapsed_s::Float64
end

mutable struct _BPNode
    id::Int
    depth::Int
    state::BPNodeState
end

function _print_top_fractional_arcs(inst::VRPRDLInstance, flows::Dict{LocArc,Float64}; k::Int=4)
    frac_all = Tuple{Int,Int,Float64}[]
    frac_elig = Tuple{Int,Int,Float64}[]
    for ((li, lj), fv) in flows
        (1e-6 < fv < 1.0 - 1e-6) || continue
        push!(frac_all, (li, lj, fv))
        if _customer_at_location(inst, li) != 0 && _customer_at_location(inst, lj) != 0
            push!(frac_elig, (li, lj, fv))
        end
    end
    sort!(frac_all; by = x -> -x[3])
    sort!(frac_elig; by = x -> -x[3])

    n_all = min(k, length(frac_all))
    n_elig = min(k, length(frac_elig))
    if n_all == 0
        println("[bp] top frac(all): nenhum arco fracionário em (0,1)")
    else
        println("[bp] top frac(all):")
        for i in 1:n_all
            li, lj, fv = frac_all[i]
            @printf("  #%d (%d,%d)=%.6f\n", i, li, lj, fv)
        end
    end
    if n_elig == 0
        println("[bp] top frac(elegíveis): nenhum (ambos endpoints cliente)")
    else
        println("[bp] top frac(elegíveis):")
        for i in 1:n_elig
            li, lj, fv = frac_elig[i]
            @printf("  #%d (%d,%d)=%.6f\n", i, li, lj, fv)
        end
    end
end

function _cg_relaxation_at_node(inst::VRPRDLInstance,
                                base_pool::Vector{Route},
                                node_state::BPNodeState,
                                cfg::CGConfig)
    pool = filter_routes_bp(base_pool, inst, node_state)
    isempty(pool) && return (MOI_BP.INFEASIBLE, NaN, fill(NaN, inst.n_customers), nothing, 0)

    rmp = build_master(inst; initial_routes=pool, sense=:partition, silent=true)
    already_in = Set{Tuple{Vector{Int},Vector{Int}}}((r.customer_seq, r.location_seq) for r in rmp.routes)
    bg_graph_cache = cfg.pricing_mode == :bucket_graph ? nothing : nothing

    lp_obj = NaN
    lp_duals = fill(NaN, inst.n_customers)
    lp_st = MOI_BP.OTHER_ERROR
    iters_done = 0
    for it in 1:cfg.max_iters
        iters_done = it
        st, obj, π = solve_rmp_lp!(rmp)
        lp_st = st
        if st != MOI.OPTIMAL
            break
        end
        lp_obj = obj
        lp_duals = π

        if cfg.pricing_mode == :pool
            new_cols = price_from_pool(pool, π, already_in; eps=cfg.eps_rc, max_add=cfg.max_add_per_iter)
        elseif cfg.pricing_mode == :bucket_graph
            new_cols = price_with_bucket_graph(
                inst, π, already_in;
                cfg=cfg.bg_cfg,
                graph_cache=bg_graph_cache,
                forbidden_loc_arcs=node_state.forbidden_loc_arcs,
            )
            if length(new_cols) > cfg.max_add_per_iter
                new_cols = new_cols[1:cfg.max_add_per_iter]
            end
        else
            error("pricing_mode inválido: $(cfg.pricing_mode)")
        end

        if cfg.verbose
            rc_best = isempty(new_cols) ? 0.0 : reduced_cost(new_cols[1], π)
            @printf("[bp][cg] it=%d LP=%.4f cols=%d new=%d rc_min=%.4f\n",
                    it, obj, length(rmp.lambdas), length(new_cols), rc_best)
        end

        isempty(new_cols) && break
        add_columns!(rmp, new_cols)
        for r in new_cols
            push!(already_in, (r.customer_seq, r.location_seq))
        end
    end
    return (lp_st, lp_obj, lp_duals, rmp, iters_done)
end

function run_branch_and_price(json_path::AbstractString,
                              log_path::AbstractString;
                              cfg::BPConfig = BPConfig(),
                              alpha_wait::Float64 = 0.0)
    t0 = time()
    inst = load_instance(json_path; alpha_wait=alpha_wait)
    backbones = parse_vrpsolver_log(log_path)
    pool = build_initial_pool(inst, backbones; use_variants=true, verbose=cfg.verbose)
    isempty(pool) && error("Pool inicial vazio: não há colunas viáveis para iniciar B&P.")

    global_ub = Inf
    global_status = MOI_BP.NO_SOLUTION
    global_routes = Route[]

    node_id = 0
    nodes_processed = 0
    nodes_pruned = 0
    stack = _BPNode[]
    push!(stack, _BPNode(node_id += 1, 0, BPNodeState()))

    while !isempty(stack) && nodes_processed < cfg.max_nodes
        node = pop!(stack)
        nodes_processed += 1
        cfg.verbose && @printf("[bp] nó=%d depth=%d\n", node.id, node.depth)

        lp_st, lp_obj, _, rmp, iters = _cg_relaxation_at_node(inst, pool, node.state, cfg.cg_cfg)
        if rmp === nothing || lp_st != MOI.OPTIMAL || isnan(lp_obj)
            nodes_pruned += 1
            cfg.verbose && println("[bp] nó podado: LP inviável/não ótimo")
            continue
        end
        cfg.verbose && @printf("[bp] LP nó=%d: obj=%.4f  cols=%d  itersCG=%d\n",
                               node.id, lp_obj, length(rmp.lambdas), iters)
        if lp_obj >= global_ub - 1e-6
            nodes_pruned += 1
            cfg.verbose && @printf("[bp] nó podado por bound: LP=%.4f >= UB=%.4f\n", lp_obj, global_ub)
            continue
        end

        # Ramificação usa x_ij agregados do **LP relaxado** (λ contínuas).
        # Se chamarmos `solve_rmp_mip!` antes, as λ ficam binárias e não há
        # arcos em (0,1) — o que falsamente “mata” o branch.
        flows = aggregate_loc_arc_flows(rmp)
        cfg.verbose && _print_top_fractional_arcs(inst, flows; k=4)
        br = pick_branch_arc_cb(inst, flows)

        mip_st, mip_obj, mip_routes = solve_rmp_mip!(rmp; time_limit=cfg.node_mip_time_limit)
        if mip_st in (MOI.OPTIMAL, MOI.TIME_LIMIT) && !isnan(mip_obj) && mip_obj < global_ub - 1e-6
            global_ub = mip_obj
            global_status = mip_st
            global_routes = mip_routes
            cfg.verbose && @printf("[bp] novo incumbente: UB=%.4f (nó=%d)\n", global_ub, node.id)
        end

        if br === nothing
            n_frac = 0
            best_dist = Inf
            best_arc = nothing
            for ((li, lj), fv) in flows
                if 1e-6 < fv < 1.0 - 1e-6
                    n_frac += 1
                    d = abs(fv - 0.5)
                    if d < best_dist
                        best_dist = d
                        best_arc = (li, lj, fv)
                    end
                end
            end
            if cfg.verbose
                if best_arc === nothing
                    @printf("[bp] nó=%d sem arco fracionário (iters CG=%d)\n", node.id, iters)
                else
                    li, lj, fv = best_arc
                    @printf("[bp] nó=%d sem arco elegível: frac_total=%d melhor=(%d,%d)=%.4f\n",
                            node.id, n_frac, li, lj, fv)
                end
            end
            continue
        end

        if node.depth >= cfg.max_depth
            cfg.verbose && println("[bp] limite de profundidade atingido")
            continue
        end

        li, lj = br
        child_forbid = _BPNode(node_id += 1, node.depth + 1, copy(node.state))
        bp_child_forbid_arc!(child_forbid.state, li, lj)

        child_force = _BPNode(node_id += 1, node.depth + 1, copy(node.state))
        bp_child_force_arc!(child_force.state, inst, li, lj)

        if cfg.dfs
            push!(stack, child_force)
            push!(stack, child_forbid)
        else
            push!(stack, child_forbid)
            push!(stack, child_force)
        end
        cfg.verbose && @printf("[bp] branch em arco (%d,%d): filhos %d/%d\n", li, lj, child_forbid.id, child_force.id)
    end

    elapsed = time() - t0
    return BPResult(global_ub, global_status, global_routes, nodes_processed, nodes_pruned, elapsed)
end
