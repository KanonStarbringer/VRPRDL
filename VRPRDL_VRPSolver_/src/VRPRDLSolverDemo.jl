__precompile__(false)
module VRPRDLSolverDemo

using VrpSolver, JuMP, ArgParse, CPLEX

include("data.jl")
include("model.jl")
include("solution.jl")

function parse_commandline(args_array::Vector{String}, appfolder::String)
    s = ArgParseSettings(
        usage = "##### VRPRDL + VRPSolver #####\n\n" *
                "  Em modo interativo, chame main([\"arg1\", ..., \"argn\"])",
        exit_after_help = false,
    )
    @add_arg_table s begin
        "instance"
        help = "Caminho do arquivo de instância VRPRDL"
        "--cfg", "-c"
        help = "Caminho do arquivo de configuração do VRPSolver"
        default = "$appfolder/../config/VRPRDL.cfg"
        "--ub", "-u"
        help = "Upper bound (primal bound)"
        arg_type = Float64
        default = 1.0e12
        "--minr", "-m"
        help = "Número mínimo de rotas"
        arg_type = Int
        default = 1
        "--maxr", "-M"
        help = "Número máximo de rotas"
        arg_type = Int
        default = 999
        "--show_complete_form", "-f"
        help = "Mostra a formulação completa enumerando rotas"
        action = :store_true
        "--update"
        help = "Atualiza o pacote VrpSolver"
        action = :store_true
        "--sol", "-s"
        help = "Caminho de um arquivo de solução para checagem/desenho"
        "--out", "-o"
        help = "Caminho para escrever a solução encontrada"
        "--tikz", "-t"
        help = "Caminho para escrever a figura TikZ da solução"
        "--nosolve", "-n"
        help = "Não chama o VRPSolver; apenas lê/checa/desenha uma solução fornecida"
        action = :store_true
        "--batch", "-b"
        help = "Arquivo batch com uma linha de comando por linha"
        "--strong_kpath_cuts", "-k"
        help = "Usa strong k-path cuts"
        action = :store_true
        "--resource_branching", "-R"
        help = "Habilita branching por consumo acumulado de recurso"
        action = :store_true
    end
    return parse_args(args_array, s)
end

function run_vrprdl(app::Dict{String,Any})
    println("Parâmetros da aplicação:")
    for (arg, val) in app
        println("  $arg => $(repr(val))")
    end
    flush(stdout)

    instance_name = split(basename(app["instance"]), ".")[1]
    data = readVRPRDLData(app)
    println(summarize_instance(data))

    if app["sol"] !== nothing
        sol = readsolution(app)
        checksolution(data, sol)
        app["ub"] = min(app["ub"], sol.cost)
    end

    solution_found = false
    sol = nothing
    status = nothing

    if !app["nosolve"]
        model, x = build_model(data, app)

        if app["show_complete_form"]
            enum_paths, complete_form = get_complete_formulation(model, app["cfg"])
            set_optimizer(complete_form, CPLEX.Optimizer)
            print_enum_paths(enum_paths)
            println(complete_form)
            optimize!(complete_form)
        end

        optimizer = VrpOptimizer(model, app["cfg"], instance_name)
        set_cutoff!(optimizer, app["ub"])
        
        status, solution_found, solver_log = _optimize_with_captured_log(optimizer)
        stats_cols, stats_line = extract_statistics_lines(solver_log)

        if solution_found
            sol = getsolution(
                data,
                optimizer,
                x,
                get_objective_value(optimizer),
                app;
                stats_cols = stats_cols,
                stats_line = stats_line,
                raw_solver_log = solver_log,
            )
        end

    end

    println("########################################################")
    retval = Inf
    if solution_found || app["sol"] !== nothing
        
        checksolution(data, sol)
        print_routes(data, sol)
        println("Cost $(sol.cost)")
        if sol.stats_cols !== nothing
            println(sol.stats_cols)
        end
        if sol.stats_line !== nothing
            println(sol.stats_line)
        end
        if app["out"] !== nothing
            writesolution(app["out"], sol)
        end

        if app["tikz"] !== nothing
            drawsolution(app["tikz"], data, sol)
        end
        retval = sol.cost
    elseif !app["nosolve"]
        if status == :Optimal
            println("Problema inviável")
        else
            println("Solução não encontrada")
        end
    end
    println("########################################################")
    return retval
end

function _optimize_with_captured_log(optimizer)
    logfile, io = mktemp()
    close(io)
    status = nothing
    solution_found = false
    logtext = ""

    open(logfile, "w+") do fio
        redirect_stdout(fio) do
            redirect_stderr(fio) do
                status, solution_found = optimize!(optimizer)
                flush(stdout)
                flush(stderr)
            end
        end
        flush(fio)
        seekstart(fio)
        logtext = read(fio, String)
    end

    rm(logfile; force = true)
    print(logtext)
    flush(stdout)

    return status, solution_found, logtext
end

function main(args)
    appfolder = dirname(@__FILE__)
    app = parse_commandline(args, appfolder)
    isnothing(app) && return
    if app["batch"] !== nothing
        for line in readlines(app["batch"])
            if isempty(strip(line)) || strip(line)[1] == '#'
                continue
            end
            args_array = [String(s) for s in split(line)]
            app_line = parse_commandline(args_array, appfolder)
            run_vrprdl(app_line)
        end
        return 0.0
    else
        return run_vrprdl(app)
    end
end

export main
end
