# =========================================================
# run_bp.jl
# Entry point: Branch-and-Price (esqueleto funcional) para VRPRDL.
# Uso:
#   julia --project=. run_bp.jl <instancia.json> [<log.log>] [alpha_wait]
# =========================================================

include(joinpath(@__DIR__, "src", "instance.jl"))
include(joinpath(@__DIR__, "src", "route.jl"))
include(joinpath(@__DIR__, "src", "expander.jl"))
include(joinpath(@__DIR__, "src", "vrpsolver_bridge.jl"))
include(joinpath(@__DIR__, "src", "master.jl"))
include(joinpath(@__DIR__, "src", "pricing.jl"))
include(joinpath(@__DIR__, "src", "bp_branching.jl"))
include(joinpath(@__DIR__, "src", "pricing_bucket.jl"))
include(joinpath(@__DIR__, "src", "cg_loop.jl"))
include(joinpath(@__DIR__, "src", "branch_and_price.jl"))

function _guess_log_path(json_path::AbstractString)
    base = basename(json_path)
    name = replace(base, r"\.json$" => "")
    guess = joinpath(@__DIR__, "..", "VRPRDL-triangle", "logs_vrp_convertidos", name * ".log")
    return abspath(guess)
end

function main()
    if length(ARGS) < 1
        println("Uso: julia --project=. run_bp.jl <instancia.json> [<log.log>] [alpha_wait]")
        exit(1)
    end
    json_path = ARGS[1]
    log_path = length(ARGS) >= 2 ? ARGS[2] : _guess_log_path(json_path)
    αw = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) : 0.0

    cg_cfg = CGConfig(
        max_iters=20,
        eps_rc=1e-6,
        max_add_per_iter=20,
        mip_time_limit=60.0,
        pricing_mode=:bucket_graph,
        bg_cfg=BucketPricingConfig(max_solve_seconds=120.0, verbose=true),
        verbose=true,
    )
    bp_cfg = BPConfig(
        cg_cfg=cg_cfg,
        max_nodes=30,
        max_depth=10,
        node_mip_time_limit=20.0,
        dfs=true,
        verbose=true,
    )

    res = run_branch_and_price(json_path, log_path; cfg=bp_cfg, alpha_wait=αw)

    println("========================================")
    println("B&P finalizado")
    println("status UB      : ", res.best_status)
    println("melhor UB      : ", isfinite(res.best_obj) ? round(res.best_obj; digits=4) : "Inf")
    println("nós processados: ", res.nodes_processed)
    println("nós podados    : ", res.nodes_pruned)
    println("tempo total    : ", round(res.elapsed_s; digits=2), " s")
    println("rotas UB       : ", length(res.best_routes))
    println("========================================")
end

main()
