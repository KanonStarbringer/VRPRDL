# =========================================================
# run_cg.jl
# Entry point: resolve uma única instância VRPRDL via CG
# usando o pool de rotas gerado a partir de um log VRPSolver.
#
# Uso:
#   julia --project=. run_cg.jl <caminho.json> [<caminho.log>] [alpha_wait] [pricing_mode] [bg_max_solve_sec]
#
# Se <caminho.log> for omitido, tenta adivinhar:
#   ../VRPRDL-triangle/logs_vrp_convertidos/<nome>.log
#
# Exemplo:
#   julia --project=. run_cg.jl \
#       ../VRPRDL-triangle/json_convertidos/instance_0-triangle.json
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

function _guess_log_path(json_path::AbstractString)
    base = basename(json_path)
    name = replace(base, r"\.json$" => "")
    guess = joinpath(@__DIR__, "..", "VRPRDL-triangle", "logs_vrp_convertidos", name * ".log")
    return abspath(guess)
end

function main()
    if length(ARGS) < 1
        println("Uso: julia --project=. run_cg.jl <instancia.json> [<log.log>] [alpha_wait] [pricing_mode] [bg_max_solve_sec]")
        exit(1)
    end

    json_path = ARGS[1]
    log_path  = length(ARGS) >= 2 ? ARGS[2] : _guess_log_path(json_path)
    αw        = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) : 0.0
    pricing_mode = length(ARGS) >= 4 ? Symbol(ARGS[4]) : :pool
    bg_sec    = length(ARGS) >= 5 ? parse(Float64, ARGS[5]) : 0.0

    cfg = CGConfig(
        max_iters         = 200,
        eps_rc            = 1e-6,
        max_add_per_iter  = 50,
        mip_time_limit    = 600.0,
        pricing_mode      = pricing_mode,
        bg_cfg            = BucketPricingConfig(max_solve_seconds = bg_sec),
        verbose           = true,
    )

    res = run_cg(json_path, log_path; cfg=cfg, alpha_wait=αw)

    # linha resumo amigável de parsear por script externo
    println("SUMMARY  status=", res.mip_status,
            "  LP=",  round(res.lp_bound;  digits=4),
            "  MIP=", round(res.mip_obj;   digits=4),
            "  veh=", length(res.selected_routes),
            "  cols=", res.n_columns_final,
            "  iters=", res.iterations,
            "  time=", round(res.time_total_s; digits=2), "s")
end

main()
