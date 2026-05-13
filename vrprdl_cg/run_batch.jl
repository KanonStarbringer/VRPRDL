# =========================================================
# run_batch.jl
# Roda a CG em TODAS as instâncias numa ÚNICA sessão Julia.
# Muito mais rápido que chamar run_cg.jl 40x (evita pagar
# o precompile do JuMP/CPLEX a cada instância).
#
# Uso:
#   julia --project=. run_batch.jl <dir_json> <dir_logs_vrpsolver> <dir_out_logs> [alpha_wait] [pricing_mode] [bg_max_solve_sec]
#
# Exemplo:
#   julia --project=. run_batch.jl \
#     ../VRPRDL-triangle/json_convertidos \
#     ../VRPRDL-triangle/logs_vrp_convertidos \
#     logs_cg \
#     0.0
#
# Saídas:
#   - <dir_out_logs>/<inst>.log        : stdout/stderr da CG de cada instância
#   - <dir_out_logs>/_summary.csv      : uma linha por instância (agregador)
# =========================================================

using Printf
using Dates

# carrega o framework apenas uma vez
include(joinpath(@__DIR__, "src", "instance.jl"))
include(joinpath(@__DIR__, "src", "route.jl"))
include(joinpath(@__DIR__, "src", "expander.jl"))
include(joinpath(@__DIR__, "src", "vrpsolver_bridge.jl"))
include(joinpath(@__DIR__, "src", "master.jl"))
include(joinpath(@__DIR__, "src", "pricing.jl"))
include(joinpath(@__DIR__, "src", "bp_branching.jl"))
include(joinpath(@__DIR__, "src", "pricing_bucket.jl"))
include(joinpath(@__DIR__, "src", "cg_loop.jl"))

# ---------------------------------------------------------
# util: redireciona stdout/stderr para um arquivo durante um bloco
# ---------------------------------------------------------
function with_tee(log_path::AbstractString, f::Function)
    open(log_path, "w") do io
        old_stdout = stdout
        old_stderr = stderr
        try
            redirect_stdout(io) do
                redirect_stderr(io) do
                    f()
                end
            end
        catch e
            println(io, "[run_batch][ERROR] ", sprint(showerror, e))
            Base.show_backtrace(io, catch_backtrace())
            rethrow(e)
        end
    end
end

function _resolve_log_path(json_path::AbstractString, log_dir::AbstractString)
    base = replace(basename(json_path), r"\.json$" => "")
    return joinpath(log_dir, base * ".log")
end

# ---------------------------------------------------------
# main
# ---------------------------------------------------------
function main()
    if length(ARGS) < 3
        println("Uso: julia --project=. run_batch.jl <dir_json> <dir_logs_vrps> <dir_out_logs> [alpha_wait] [pricing_mode] [bg_max_solve_sec]")
        exit(1)
    end

    json_dir = ARGS[1]
    vrps_log_dir = ARGS[2]
    out_dir = ARGS[3]
    αw      = length(ARGS) >= 4 ? parse(Float64, ARGS[4]) : 0.0
    pricing_mode = length(ARGS) >= 5 ? Symbol(ARGS[5]) : :pool
    bg_sec  = length(ARGS) >= 6 ? parse(Float64, ARGS[6]) : 0.0

    isdir(json_dir)     || error("dir_json não existe: $json_dir")
    isdir(vrps_log_dir) || error("dir_logs_vrps não existe: $vrps_log_dir")
    isdir(out_dir)      || mkpath(out_dir)

    # glob simples: suporta apenas *.json (o que basta aqui)
    all_files = sort(filter(f -> endswith(lowercase(f), ".json"), readdir(json_dir)))
    if isempty(all_files)
        error("Nenhum JSON em $json_dir")
    end

    # CSV agregador
    csv_path = joinpath(out_dir, "_summary.csv")
    csv_io = open(csv_path, "w")
    println(csv_io, "instance,status,lp_bound,mip_obj,vehicles,columns,iterations,time_s,error")
    flush(csv_io)

    total   = length(all_files)
    n_ok    = 0
    n_skip  = 0
    n_err   = 0
    t_batch = time()

    cfg = CGConfig(
        max_iters         = 200,
        eps_rc            = 1e-6,
        max_add_per_iter  = 50,
        mip_time_limit    = 600.0,
        pricing_mode      = pricing_mode,
        bg_cfg            = BucketPricingConfig(max_solve_seconds = bg_sec),
        verbose           = true,
    )

    println("========================================")
    println("[batch] instâncias  : ", total)
    println("[batch] json_dir    : ", json_dir)
    println("[batch] vrps_logs   : ", vrps_log_dir)
    println("[batch] out_logs    : ", out_dir)
    println("[batch] alpha_wait  : ", αw)
    println("[batch] pricing     : ", String(pricing_mode))
    println("[batch] bg_max_sec  : ", bg_sec)
    println("========================================")

    for (i, jf) in enumerate(all_files)
        json_path = joinpath(json_dir, jf)
        base      = replace(jf, r"\.json$" => "")
        log_src   = joinpath(vrps_log_dir, base * ".log")
        log_dst   = joinpath(out_dir, base * ".log")

        print("[$i/$total] $base ... ")

        if !isfile(log_src)
            println("SKIP (sem log VRPSolver em $log_src)")
            println(csv_io, "$base,SKIP,,,,,,,no_vrpsolver_log")
            flush(csv_io)
            n_skip += 1
            continue
        end

        t_inst = time()
        res = nothing
        err_msg = ""

        try
            with_tee(log_dst, () -> begin
                println("instance_json=", json_path)
                println("instance_log=", log_src)
                println("alpha_wait=", αw)
                println("start_time=", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
                println()
                res = run_cg(json_path, log_src; cfg=cfg, alpha_wait=αw)
                println()
                println("end_time=", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
            end)
        catch e
            err_msg = replace(sprint(showerror, e), ',' => ';', '\n' => ' ')
            short = first(err_msg, 60)
            println("ERRO (", short, ")")
            println(csv_io, "$base,ERROR,,,,,,", round(time()-t_inst; digits=2), ",$err_msg")
            flush(csv_io)
            n_err += 1
            continue
        end

        Δt = time() - t_inst
        if res === nothing
            println("ERRO (sem resultado)")
            println(csv_io, "$base,ERROR,,,,,,", round(Δt; digits=2), ",no_result")
            flush(csv_io)
            n_err += 1
        else
            @printf("OK  LP=%.2f  MIP=%.2f  veh=%d  cols=%d  iters=%d  t=%.2fs\n",
                    res.lp_bound, res.mip_obj, length(res.selected_routes),
                    res.n_columns_final, res.iterations, Δt)
            println(csv_io, "$base,$(res.mip_status),", res.lp_bound, ",", res.mip_obj, ",",
                    length(res.selected_routes), ",", res.n_columns_final, ",",
                    res.iterations, ",", round(Δt; digits=2), ",")
            flush(csv_io)
            n_ok += 1
        end
    end

    close(csv_io)
    Δb = time() - t_batch

    println("========================================")
    @printf("[batch] OK=%d  SKIP=%d  ERR=%d  total_time=%.1fs\n", n_ok, n_skip, n_err, Δb)
    println("[batch] CSV agregado: ", csv_path)
    println("========================================")
end

main()
