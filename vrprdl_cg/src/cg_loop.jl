# =========================================================
# cg_loop.jl
# Orquestração da Column Generation para o VRPRDL.
#
# Fluxo:
#   1. Carrega instância (JSON).
#   2. Lê backbones do log do VRPSolver (offline).
#   3. Expande cada backbone -> rotas VRPRDL viáveis.
#   4. Cria o RMP vazio, insere as rotas como colunas.
#   5. Loop CG:
#        - solve RMP (LP)
#        - extrai duais π
#        - pricing sobre o pool: pega rotas com rc < -ε
#        - se nenhuma -> encerra CG
#        - adiciona colunas e repete
#   6. Solve RMP como MIP com o pool final.
# =========================================================

using Printf
using Dates

"""
Configurações da CG. Todos os campos têm default razoável.
"""
Base.@kwdef mutable struct CGConfig
    max_iters::Int = 200
    eps_rc::Float64 = 1e-6
    max_add_per_iter::Int = 50
    mip_time_limit::Float64 = 600.0
    pricing_mode::Symbol = :pool   # :pool | :bucket_graph
    bg_cfg::BucketPricingConfig = BucketPricingConfig()
    # ramificação B&P (Özbayğın et al. 2017, Sec. 3.3): `nothing` = nó raiz; caso contrário
    # filtra pool/colunas e restringe arcos do `build_bg_graph` / pricing em bucket.
    bp_node::Union{Nothing,BPNodeState} = nothing
    verbose::Bool = true
end

"""
Resultado agregado de uma execução da CG.
"""
struct CGResult
    lp_bound::Float64
    mip_obj::Float64
    mip_status::Any
    selected_routes::Vector{Route}
    iterations::Int
    n_columns_final::Int
    time_total_s::Float64
end

"""
Resolve um VRPRDL completo via CG usando o pool VRPSolver + expander.

- `json_path`: caminho do JSON da instância (já convertido).
- `log_path` : caminho do log do VRPSolver no CVRP projetado.
- `alpha_wait`: penalidade para tempo de espera (default 0.0).
"""
function run_cg(json_path::AbstractString,
                log_path::AbstractString;
                cfg::CGConfig = CGConfig(),
                alpha_wait::Float64 = 0.0)

    t0 = time()

    inst = load_instance(json_path; alpha_wait=alpha_wait)
    cfg.verbose && _banner_instance(inst, json_path, log_path, alpha_wait)

    # ---- pool inicial ----
    backbones = parse_vrpsolver_log(log_path)
    cfg.verbose && println("[vrpsolver] backbones lidos: ", length(backbones))

    pool = build_initial_pool(inst, backbones; use_variants=true, verbose=cfg.verbose)
    if isempty(pool)
        error("Pool inicial vazio: nenhuma rota VRPRDL viável foi produzida. " *
              "Verifique janelas / matriz de tempos / alpha_wait.")
    end
    if cfg.bp_node !== nothing
        pool = filter_routes_bp(pool, inst, cfg.bp_node)
        isempty(pool) &&
            error("Pool inicial vazio após filtro Branch-and-Price (bp_node): nenhuma rota compatível.")
    end

    # ---- RMP ----
    rmp = build_master(inst; initial_routes=pool, sense=:partition, silent=true)
    already_in = Set{Tuple{Vector{Int},Vector{Int}}}(
        (r.customer_seq, r.location_seq) for r in rmp.routes
    )

    # ---- CG loop ----
    lp_bound = NaN
    iters_done = 0
    bg_graph_cache = if cfg.pricing_mode == :bucket_graph && cfg.bp_node === nothing
        build_bg_graph(inst)
    elseif cfg.pricing_mode == :bucket_graph
        nothing  # com proibições B&P o grafo tem de ser reconstruído a cada pricing
    else
        nothing
    end

    for it in 1:cfg.max_iters
        iters_done = it
        st, obj, π = solve_rmp_lp!(rmp)
        if st != MOI.OPTIMAL
            cfg.verbose && println(@sprintf("[cg] it=%d status não-ótimo no LP: %s", it, st))
            break
        end
        lp_bound = obj

        if cfg.pricing_mode == :pool
            new_cols = price_from_pool(pool, π, already_in;
                                       eps=cfg.eps_rc, max_add=cfg.max_add_per_iter)
        elseif cfg.pricing_mode == :bucket_graph
            forb = cfg.bp_node === nothing ? nothing : cfg.bp_node.forbidden_loc_arcs
            new_cols = price_with_bucket_graph(inst, π, already_in;
                                               cfg=cfg.bg_cfg,
                                               graph_cache=bg_graph_cache,
                                               forbidden_loc_arcs=forb)
            if length(new_cols) > cfg.max_add_per_iter
                new_cols = new_cols[1:cfg.max_add_per_iter]
            end
        else
            error("pricing_mode inválido: $(cfg.pricing_mode)")
        end

        if cfg.verbose
            rc_best = isempty(new_cols) ? 0.0 : reduced_cost(new_cols[1], π)
            @printf("[cg] it=%3d  LP=%.4f  cols=%d  new=%d  rc_min=%.4f  pricing=%s\n",
                    it, obj, length(rmp.lambdas), length(new_cols), rc_best, String(cfg.pricing_mode))
        end

        isempty(new_cols) && break

        add_columns!(rmp, new_cols)
        for r in new_cols
            push!(already_in, (r.customer_seq, r.location_seq))
        end
    end

    # ---- MIP final ----
    cfg.verbose && println("[cg] LP bound = ", round(lp_bound; digits=4),
                           "  |  resolvendo MIP com ", length(rmp.lambdas), " colunas...")
    mip_st, mip_obj, selected = solve_rmp_mip!(rmp; time_limit=cfg.mip_time_limit)

    elapsed = time() - t0

    if cfg.verbose
        _banner_result(mip_st, mip_obj, lp_bound, selected, elapsed)
        _print_routes(inst, selected)
    end

    return CGResult(
        lp_bound,
        mip_obj,
        mip_st,
        selected,
        iters_done,
        length(rmp.lambdas),
        elapsed,
    )
end

# ---------------------------------------------------------
# impressão / logs
# ---------------------------------------------------------

function _banner_instance(inst, json_path, log_path, αw)
    println("========================================")
    println("Instância       : ", inst.name)
    println("JSON            : ", json_path)
    println("VRPSolver log   : ", log_path)
    println("n_customers     : ", inst.n_customers)
    println("n_locations     : ", inst.n_locations)
    println("time_horizon    : ", inst.time_horizon)
    println("capacity        : ", inst.capacity)
    println("alpha_wait      : ", αw)
    println("========================================")
end

function _banner_result(status, mip, lp, sel, elapsed)
    println("========================================")
    println("CG finalizado.")
    println("status MIP      : ", status)
    println("LP bound        : ", round(lp; digits=4))
    println("MIP objetivo    : ", round(mip; digits=4))
    println("veículos usados : ", length(sel))
    println("tempo total     : ", round(elapsed; digits=2), " s")
    println("========================================")
end

function _print_routes(inst, routes)
    println("Rotas selecionadas:")
    for (i, r) in enumerate(routes)
        seq_str = join(r.customer_seq, " ")
        loc_str = join(r.location_seq, " ")
        @printf("  Route #%d  travel=%4d  wait=%3d  cost=%.2f  demand=%d\n",
                i, r.travel_cost, r.wait_total, r.cost, r.demand_total)
        println("      customers: ", seq_str)
        println("      locations: ", loc_str)
    end
end
