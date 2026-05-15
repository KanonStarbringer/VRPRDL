using JuMP
mutable struct Solution
    cost::Float64
    routes::Vector{Vector{Int}}   # sequência de localizações visitadas, sem o depósito inicial/final
    stats_cols::Union{Nothing,String}
    stats_line::Union{Nothing,String}
    raw_solver_log::Union{Nothing,String}
end

function getsolution(
    data::DataVRPRDL,
    optimizer::VrpOptimizer,
    x,
    objval,
    app::Dict{String,Any};
    stats_cols = nothing,
    stats_line = nothing,
    raw_solver_log = nothing,
)
    A = arcs(data)
    succ = Dict{Int,Int}()
    starts = Int[]

    for a in A
        val = JuMP.value(x[a])
        if val > 0.5
            i, j = a
            if i == data.source_loc
                push!(starts, j)
            elseif j != data.sink_loc
                succ[i] = j
            end
        end
    end

    routes = Vector{Vector{Int}}()
    for st in starts
        r = Int[]
        cur = st
        while true
            push!(r, cur)
            if !haskey(succ, cur)
                break
            end
            cur = succ[cur]
        end
        push!(routes, r)
    end

    sol = Solution(Float64(objval), routes, stats_cols, stats_line, raw_solver_log)
    checksolution(data, sol)
    return sol
end

function print_routes(data::DataVRPRDL, solution::Solution)
    for (k, r) in enumerate(solution.routes)
        tokens = ["$(loc)[c=$(customer_of_loc(data, loc))]" for loc in r]
        println("Route #$k: ", join(tokens, " -> "))
    end
end

function print_routes(solution::Solution)
    for (k, r) in enumerate(solution.routes)
        println("Route #$k: ", join(string.(r), " "))
    end
end

function checksolution(data::DataVRPRDL, solution::Solution)
    visit_count = Dict(c => 0 for c in real_customers(data))
    total_cost = 0.0
    atol = 1e-6

    for (k, route) in enumerate(solution.routes)
        load = 0.0
        current_time = 0.0
        prev = data.source_loc
        for loc in route
            cust = customer_of_loc(data, loc)
            cust == data.source_customer && error("Rota #$k visita o depósito inicial como cliente interno")
            cust == data.sink_customer && error("Rota #$k visita o depósito final como cliente interno")

            if !is_feasible_arc(data, prev, loc)
                error("Rota #$k usa arco inviável ($(prev),$(loc))")
            end
            current_time = max(l(data, loc), current_time + t(data, (prev, loc)))
            if current_time > u(data, loc) + atol
                error("Rota #$k viola janela de tempo na localização $loc: chegada=$current_time, janela=[$(l(data, loc)),$(u(data, loc))]")
            end
            visit_count[cust] += 1
            visit_count[cust] > 1 && error("O cliente $cust foi visitado mais de uma vez")
            load += d(data, loc)
            total_cost += c(data, (prev, loc))
            prev = loc
        end

        is_feasible_arc(data, prev, data.sink_loc) || error("Rota #$k não consegue retornar ao depósito final")
        current_time = max(l(data, data.sink_loc), current_time + t(data, (prev, data.sink_loc)))
        if current_time > u(data, data.sink_loc) + atol
            error("Rota #$k retorna ao depósito final após o horizonte: chegada=$current_time")
        end
        load <= veh_capacity(data) + atol || error(
            "Rota #$k viola a capacidade: carga=$load, capacidade=$(veh_capacity(data))"
        )
        total_cost += c(data, (prev, data.sink_loc))
    end

    missing = [c for c in real_customers(data) if visit_count[c] == 0]
    isempty(missing) || error("Clientes não atendidos: $(join(missing, ", "))")

    abs(solution.cost - total_cost) <= 1e-4 || error(
        "Custo informado $(solution.cost) difere do custo calculado $total_cost"
    )
    return true
end

function readsolution(app::Dict{String,Any})
    str = read(app["sol"], String)
    breaks_in = [' '; ':'; '\n'; '\t'; '\r']
    aux = split(str, breaks_in; limit = 0, keepempty = false)
    sol = Solution(0.0, Vector{Vector{Int}}(), nothing, nothing, nothing)
    j = 3
    while j <= length(aux)
        r = Int[]
        while j <= length(aux)
            push!(r, parse(Int, aux[j]))
            j += 1
            if j > length(aux) || contains(lowercase(aux[j]), "cost") || contains(lowercase(aux[j]), "route")
                break
            end
        end
        push!(sol.routes, r)
        if j <= length(aux) && contains(lowercase(aux[j]), "cost")
            sol.cost = parse(Float64, aux[j + 1])
            return sol
        end
        j += 2
    end
    error("O arquivo de solução não pôde ser lido. O formato esperado é o padrão simples 'Route #i:' + 'Cost'.")
end

function writesolution(solpath::AbstractString, solution::Solution)
    open(solpath, "w") do f
        if solution.stats_cols !== nothing
            write(f, solution.stats_cols * "\n")
        end
        if solution.stats_line !== nothing
            write(f, solution.stats_line * "\n")
        end
        for (i, r) in enumerate(solution.routes)
            write(f, "Route #$i: ")
            for loc in r
                write(f, "$(loc) ")
            end
            write(f, "\n")
        end
        write(f, "Cost $(solution.cost)\n")
    end
end

function drawsolution(tikzpath::AbstractString, data::DataVRPRDL, solution::Solution)
    open(tikzpath, "w") do f
        write(f, "\\documentclass[crop,tikz]{standalone}\n\\begin{document}\n")
        xs = [xcoord(data, loc) for loc in all_locations(data)]
        ys = [ycoord(data, loc) for loc in all_locations(data)]
        scale_fac = 1 / max(1.0, max(maximum(abs.(xs)), maximum(abs.(ys))) / 10)
        write(f, "\\begin{tikzpicture}[thick, scale=1, every node/.style={scale=0.35}]\n")
        for loc in all_locations(data)
            x = scale_fac * xcoord(data, loc)
            y = scale_fac * ycoord(data, loc)
            if loc == data.source_loc
                write(f, "\\node[draw, rectangle, fill=yellow] (v$(loc)) at ($(x),$(y)) {S};\n")
            elseif loc == data.sink_loc
                write(f, "\\node[draw, rectangle, fill=orange] (v$(loc)) at ($(x),$(y)) {T};\n")
            else
                cust = customer_of_loc(data, loc)
                write(f, "\\node[draw, circle, fill=white] (v$(loc)) at ($(x),$(y)) {$(loc)/$(cust)};\n")
            end
        end
        for r in solution.routes
            prev = data.source_loc
            for loc in r
                write(f, "\\draw[-,line width=0.6pt] (v$(prev)) -- (v$(loc));\n")
                prev = loc
            end
            write(f, "\\draw[-,line width=0.6pt] (v$(prev)) -- (v$(data.sink_loc));\n")
        end
        write(f, "\\end{tikzpicture}\n\\end{document}\n")
    end
end

function extract_statistics_lines(logtext::AbstractString)
    stats_cols = nothing
    stats_line = nothing
    for line in split(logtext, "\n")
        s = strip(line)
        startswith(s, "statistics_cols:") && (stats_cols = s)
        startswith(s, "statistics:") && (stats_line = s)
    end
    return stats_cols, stats_line
end
