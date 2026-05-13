# =========================================================
# pricing_bucket.jl
# Pricing online via bridge C++ (bucket-graph-spprc).
#
# Fluxo:
# 1) monta grafo VRPRDL (source -> (cliente,local) -> ... -> sink)
# 2) injeta custos reduzidos pelos duais
# 3) chama bgp_solve via ccall
# 4) converte caminhos em Route e filtra inviaveis/duplicadas
# =========================================================

using Printf
using Libdl

const BGP_LIB_DEFAULT = joinpath(@__DIR__, "..", "bg_bridge", "build", "libbg_pricing_bridge.so")
const _BG_HANDLES = Dict{String,Ptr{Cvoid}}()

function _bg_handle(lib_path::String)
    if haskey(_BG_HANDLES, lib_path)
        return _BG_HANDLES[lib_path]
    end
    h = Libdl.dlopen(lib_path)
    _BG_HANDLES[lib_path] = h
    return h
end

function _bg_sym(lib_path::String, sym::Symbol)
    return Libdl.dlsym(_bg_handle(lib_path), sym)
end

struct BGPInputC
    n_vertices::Cint
    source::Cint
    sink::Cint
    n_arcs::Cint
    arc_from::Ptr{Cint}
    arc_to::Ptr{Cint}
    arc_base_cost::Ptr{Cdouble}
    arc_time::Ptr{Cdouble}
    arc_load::Ptr{Cdouble}
    vertex_time_lb::Ptr{Cdouble}
    vertex_time_ub::Ptr{Cdouble}
    vehicle_capacity::Cdouble
    vertex_customer::Ptr{Cint}
    vertex_location::Ptr{Cint}
    theta::Cdouble
    max_paths::Cint
    bidirectional::Cint
    parallel_bidir::Cint
end

mutable struct BGPResultC
    status::Cint
    n_paths::Cint
    total_vertices::Cint
    path_offsets::Ptr{Cint}
    path_vertex_ids::Ptr{Cint}
    path_reduced_costs::Ptr{Cdouble}
    path_original_costs::Ptr{Cdouble}
end

Base.@kwdef mutable struct BucketPricingConfig
    lib_path::String = BGP_LIB_DEFAULT
    theta::Float64 = -1e-6
    max_paths::Int = 200
    bidirectional::Bool = true
    parallel_bidir::Bool = true
    verbose::Bool = false
    # >0: invoca `bgp_solve_once` (mesmo diretório da .so) sob `timeout` do GNU coreutils,
    #     para o kernel poder matar o processo se o SPPR-C travar. Requer `timeout` no PATH
    #     (Linux/WSL). 0 = chamada in-process via ccall (sem limite duro).
    max_solve_seconds::Float64 = 0.0
    # vazio = joinpath(dirname(lib_path), "bgp_solve_once" ou ".exe")
    worker_exe::String = ""
end

struct BGGraphData
    n_vertices::Int
    source::Int
    sink::Int
    arc_from::Vector{Int32}
    arc_to::Vector{Int32}
    arc_time::Vector{Float64}
    arc_load::Vector{Float64}
    arc_travel::Vector{Float64}
    vertex_time_lb::Vector{Float64}
    vertex_time_ub::Vector{Float64}
    vertex_customer::Vector{Int32}
    vertex_location::Vector{Int32}
end

function _check_bg_lib(lib_path::String)
    isfile(lib_path) || error("Bridge C++ não encontrada em: $lib_path")
end

function _vertex_tables(inst::VRPRDLInstance)
    # vertices 1-based no Julia: 1=source, last=sink
    cust_of_v = Int32[0]
    loc_of_v = Int32[inst.depot_start_loc]
    open_of_v = Float64[0.0]
    close_of_v = Float64[0.0]

    for c in 1:inst.n_customers
        for w in inst.customers[c].locations
            push!(cust_of_v, Int32(c))
            push!(loc_of_v, Int32(w.location_id))
            push!(open_of_v, Float64(w.time_opening))
            push!(close_of_v, Float64(w.time_closing))
        end
    end

    push!(cust_of_v, Int32(0))
    push!(loc_of_v, Int32(inst.depot_end_loc))
    push!(open_of_v, 0.0)
    push!(close_of_v, Float64(inst.depot_end_closing))

    return cust_of_v, loc_of_v, open_of_v, close_of_v
end

function _bp_locpair_for_arc(loc_of_v, v_i::Int, v_j::Int)
    return (Int(loc_of_v[v_i]), Int(loc_of_v[v_j]))
end

function build_bg_graph(inst::VRPRDLInstance;
                        forbidden_loc_arcs::Union{Nothing,AbstractSet{Tuple{Int,Int}}}=nothing)
    cust_of_v, loc_of_v, open_of_v, close_of_v = _vertex_tables(inst)
    nV = length(cust_of_v)
    source = 1
    sink = nV

    function arc_blocked(v_i::Int, v_j::Int)
        forbidden_loc_arcs === nothing && return false
        return _bp_locpair_for_arc(loc_of_v, v_i, v_j) in forbidden_loc_arcs
    end

    arc_from = Int32[]
    arc_to = Int32[]
    arc_time = Float64[]
    arc_load = Float64[]
    arc_travel = Float64[]

    # source -> cliente/local
    for v in 2:(sink - 1)
        c = Int(cust_of_v[v])
        l = Int(loc_of_v[v])
        arc_blocked(source, v) && continue
        tt = travel_time(inst, inst.depot_start_loc, l)
        tt >= typemax(Int) ÷ 4 && continue
        arr = tt
        arr > close_of_v[v] && continue
        push!(arc_from, Int32(source - 1))
        push!(arc_to, Int32(v - 1))
        push!(arc_time, Float64(tt))
        push!(arc_load, Float64(inst.customers[c].demand))
        push!(arc_travel, Float64(tt))
    end

    # (cliente/local)i -> (cliente/local)j, com cliente distinto e viável em TW
    for i in 2:(sink - 1)
        ci = Int(cust_of_v[i])
        li = Int(loc_of_v[i])
        for j in 2:(sink - 1)
            i == j && continue
            cj = Int(cust_of_v[j])
            ci == cj && continue
            lj = Int(loc_of_v[j])
            tt = travel_time(inst, li, lj)
            tt >= typemax(Int) ÷ 4 && continue
            # condição necessária de viabilidade:
            # sair de i no earliest(open_i) e chegar em j <= close_j
            earliest_dep_i = open_of_v[i]
            if earliest_dep_i + tt > close_of_v[j]
                continue
            end
            arc_blocked(i, j) && continue
            push!(arc_from, Int32(i - 1))
            push!(arc_to, Int32(j - 1))
            push!(arc_time, Float64(tt))
            push!(arc_load, Float64(inst.customers[cj].demand))
            push!(arc_travel, Float64(tt))
        end
    end

    # cliente/local -> sink
    for i in 2:(sink - 1)
        li = Int(loc_of_v[i])
        tt = travel_time(inst, li, inst.depot_end_loc)
        tt >= typemax(Int) ÷ 4 && continue
        earliest_dep_i = open_of_v[i]
        if earliest_dep_i + tt > inst.depot_end_closing
            continue
        end
        arc_blocked(i, sink) && continue
        push!(arc_from, Int32(i - 1))
        push!(arc_to, Int32(sink - 1))
        push!(arc_time, Float64(tt))
        push!(arc_load, 0.0)
        push!(arc_travel, Float64(tt))
    end

    return BGGraphData(
        nV,
        source,
        sink,
        arc_from,
        arc_to,
        arc_time,
        arc_load,
        arc_travel,
        open_of_v,
        close_of_v,
        cust_of_v,
        loc_of_v,
    )
end

function _arc_reduced_costs(g::BGGraphData, π::Vector{Float64})
    nA = length(g.arc_from)
    rc = Vector{Float64}(undef, nA)
    @inbounds for a in 1:nA
        # No SP de caminho, cada cliente visitado aparece exatamente uma vez
        # como vértice de ORIGEM em algum arco da rota (inclusive o último,
        # no arco cliente->sink). Portanto, para reproduzir
        # rc(r) = cost(r) - sum_{c in r} π_c, descontamos o dual no nó de origem.
        i = Int(g.arc_from[a]) + 1 # volta para 1-based
        c = Int(g.vertex_customer[i])
        dual = c == 0 ? 0.0 : π[c]
        rc[a] = g.arc_travel[a] - dual
    end
    return rc
end

function _bucket_worker_exe(cfg::BucketPricingConfig)
    isempty(cfg.worker_exe) || return cfg.worker_exe
    d = dirname(cfg.lib_path)
    fn = Sys.iswindows() ? "bgp_solve_once.exe" : "bgp_solve_once"
    return joinpath(d, fn)
end

function _bgp_worker_write(path::AbstractString, inst::VRPRDLInstance, g::BGGraphData,
                           rc::Vector{Float64}, cfg::BucketPricingConfig)
    # Não usar join([ints, floats...], ' '): o Julia promove tudo a Float64 e imprime
    # "17.0 0.0 ...", e o C++ falha ao ler inteiros (parametros invalidos).
    open(path, "w") do io
        println(io, "BGP_TEXT_V1")
        nA = length(g.arc_from)
        println(io,
                "$(g.n_vertices) $(g.source - 1) $(g.sink - 1) $(nA) $(inst.capacity) $(cfg.theta) ",
                "$(cfg.max_paths) $(Int(cfg.bidirectional)) $(Int(cfg.parallel_bidir))")
        @inbounds for a in 1:nA
            println(io,
                    "$(Int(g.arc_from[a])) $(Int(g.arc_to[a])) $(rc[a]) $(g.arc_time[a]) $(g.arc_load[a])")
        end
        @inbounds for v in 1:g.n_vertices
            println(io,
                    "$(g.vertex_time_lb[v]) $(g.vertex_time_ub[v]) ",
                    "$(Int(g.vertex_customer[v])) $(Int(g.vertex_location[v]))")
        end
    end
end

function _bgp_read_worker_serialized(path::AbstractString)
    isfile(path) || return nothing
    lines = readlines(path)
    isempty(lines) && return nothing
    hdr = split(strip(lines[1]))
    length(hdr) < 4 && return nothing
    hdr[1] == "OK" || return nothing
    n_paths_hdr = parse(Int, hdr[3])
    path_vecs = Vector{Int32}[]
    sizehint!(path_vecs, max(n_paths_hdr, 1))
    for ln in lines
        s = strip(ln)
        startswith(s, "PATH ") || continue
        parts = split(s)
        length(parts) < 4 && return nothing
        len = parse(Int, parts[3])
        length(parts) - 3 != len && return nothing
        push!(path_vecs, Int32[parse(Int, parts[i]) for i in 4:length(parts)])
    end
    if n_paths_hdr != length(path_vecs)
        return nothing
    end
    offs = Vector{Int32}(undef, length(path_vecs) + 1)
    offs[1] = 0
    @inbounds for i in 1:length(path_vecs)
        offs[i + 1] = offs[i] + Int32(length(path_vecs[i]))
    end
    vtx = Int32[]
    for pv in path_vecs
        append!(vtx, pv)
    end
    return (length(path_vecs), offs, vtx)
end

function _gnu_timeout_path()
    bin = Sys.which("timeout")
    bin === nothing && return nothing
    try
        ver = read(Cmd([bin, "--version"]), String)
        (occursin("GNU", ver) || occursin("coreutils", ver)) && return bin
    catch
    end
    return nothing
end

function _run_bgp_solve_worker_timed(cfg::BucketPricingConfig, inpath::String, outpath::String,
                                     timeout_bin::AbstractString)
    exe = _bucket_worker_exe(cfg)
    sec = max(1, ceil(Int, cfg.max_solve_seconds))
    cmd = Cmd(String[String(timeout_bin), "-k", "5", string(sec), exe, inpath, outpath])
    # `ignorestatus` em `run` só existe em Julia recente; aqui capturamos falha não-zero.
    try
        return run(cmd; wait=true)
    catch e
        e isa Base.ProcessFailedException || rethrow(e)
        isempty(e.procs) && rethrow(e)
        return e.procs[1]::Base.Process
    end
end

function _bucket_routes_from_offsets(inst::VRPRDLInstance, g::BGGraphData, π::Vector{Float64},
                                     already_in::Set{Tuple{Vector{Int},Vector{Int}}},
                                     n_paths::Int, offs::Vector{Int32}, vtx::Vector{Int32};
                                     cfg::BucketPricingConfig)
    routes = Route[]
    n_repaired_repeat = 0
    n_reject_nothing = 0
    n_reject_repeat = 0
    n_reject_empty = 0
    n_reject_build = 0
    n_reject_already = 0
    n_reject_rc = 0
    @inbounds for k in 1:n_paths
        i0 = Int(offs[k]) + 1
        i1 = Int(offs[k + 1])
        i0 > i1 && continue
        path_vertices = @view vtx[i0:i1]
        r, reason = _path_to_route_with_reason(inst, g, collect(path_vertices))
        if reason === :repaired_repeat
            n_repaired_repeat += 1
        end
        if r === nothing
            n_reject_nothing += 1
            if reason === :repeat_customer
                n_reject_repeat += 1
            elseif reason === :empty_customer_seq
                n_reject_empty += 1
            elseif reason === :build_infeasible
                n_reject_build += 1
            end
            continue
        end
        key = (r.customer_seq, r.location_seq)
        if key in already_in
            n_reject_already += 1
            continue
        end
        rc_true = reduced_cost(r, π)
        if !(rc_true < -1e-6)
            n_reject_rc += 1
            continue
        end
        push!(routes, r)
    end
    sort!(routes; by = r -> reduced_cost(r, π))
    if cfg.verbose
        @printf("[bg-pricing] paths=%d válidos=%d (rep_ok=%d) rejeitos(nothing=%d rep=%d empty=%d build=%d,already=%d,rc=%d)\n",
                n_paths, length(routes), n_repaired_repeat, n_reject_nothing, n_reject_repeat,
                n_reject_empty, n_reject_build, n_reject_already, n_reject_rc)
    end
    return routes
end

function _path_to_route_with_reason(inst::VRPRDLInstance, g::BGGraphData, path_vertices0::Vector{Int32})
    customer_seq = Int[]
    location_seq = Int[]
    seen = Set{Int}()
    had_repeat = false

    for v0 in path_vertices0
        v = Int(v0) + 1
        if v == g.source || v == g.sink
            continue
        end
        c = Int(g.vertex_customer[v])
        l = Int(g.vertex_location[v])
        c == 0 && continue
        if c in seen
            had_repeat = true
            continue
        end
        push!(seen, c)
        push!(customer_seq, c)
        push!(location_seq, l)
    end

    isempty(customer_seq) && return (nothing, :empty_customer_seq)
    ok, r = build_route(inst, customer_seq, location_seq)
    if !ok
        return (nothing, :build_infeasible)
    end
    return had_repeat ? (r, :repaired_repeat) : (r, :ok)
end

function _path_to_route(inst::VRPRDLInstance, g::BGGraphData, path_vertices0::Vector{Int32})
    r, _ = _path_to_route_with_reason(inst, g, path_vertices0)
    return r
end

function _bg_last_error(lib_path::String)
    ptr = ccall(_bg_sym(lib_path, :bgp_last_error), Cstring, ())
    ptr == C_NULL && return "erro desconhecido"
    return unsafe_string(ptr)
end

function price_with_bucket_graph(inst::VRPRDLInstance,
                                 π::Vector{Float64},
                                 already_in::Set{Tuple{Vector{Int},Vector{Int}}};
                                 cfg::BucketPricingConfig = BucketPricingConfig(),
                                 graph_cache::Union{Nothing,BGGraphData}=nothing,
                                 forbidden_loc_arcs::Union{Nothing,AbstractSet{Tuple{Int,Int}}}=nothing)
    _check_bg_lib(cfg.lib_path)

    g = if forbidden_loc_arcs !== nothing
        build_bg_graph(inst; forbidden_loc_arcs=forbidden_loc_arcs)
    elseif graph_cache === nothing
        build_bg_graph(inst)
    else
        graph_cache
    end
    rc = _arc_reduced_costs(g, π)

    wexe = _bucket_worker_exe(cfg)
    want_time = cfg.max_solve_seconds > 0
    have_worker = isfile(wexe)
    timeout_bin = _gnu_timeout_path()
    have_to = timeout_bin !== nothing

    if want_time && have_worker && have_to
        inpath = tempname()
        outpath = tempname() * ".bgp_out"
        try
            _bgp_worker_write(inpath, inst, g, rc, cfg)
            proc = _run_bgp_solve_worker_timed(cfg, inpath, outpath, timeout_bin)
            ec = proc.exitcode
            if ec == 124 || ec == 137
                cfg.verbose &&
                    @warn "[bg-pricing] tempo esgotado no worker (exit=$ec); sem colunas nesta iteração"
                return Route[]
            end
            if ec != 0
                cfg.verbose &&
                    @warn "[bg-pricing] worker exit=$(ec) (ver stderr do bgp_solve_once); tentando ler saída"
            end
            ser = _bgp_read_worker_serialized(outpath)
            if ser === nothing
                cfg.verbose && @warn "[bg-pricing] saída do worker ilegível ou incompleta; sem colunas"
                return Route[]
            end
            np, offs, vtx = ser
            return _bucket_routes_from_offsets(inst, g, π, already_in, np, offs, vtx; cfg=cfg)
        finally
            isfile(inpath) && rm(inpath, force=true)
            isfile(outpath) && rm(outpath, force=true)
        end
    end

    if want_time && cfg.verbose
        !have_worker &&
            @warn "[bg-pricing] executável não encontrado ($(wexe)); ccall in-process sem limite duro"
        have_worker && !have_to &&
            @warn "[bg-pricing] GNU coreutils 'timeout' não detectado no PATH; ccall in-process sem limite duro"
    end

    in_c = BGPInputC(
        Cint(g.n_vertices),
        Cint(g.source - 1),
        Cint(g.sink - 1),
        Cint(length(g.arc_from)),
        pointer(g.arc_from),
        pointer(g.arc_to),
        pointer(rc),
        pointer(g.arc_time),
        pointer(g.arc_load),
        pointer(g.vertex_time_lb),
        pointer(g.vertex_time_ub),
        Cdouble(inst.capacity),
        pointer(g.vertex_customer),
        pointer(g.vertex_location),
        Cdouble(cfg.theta),
        Cint(cfg.max_paths),
        Cint(cfg.bidirectional ? 1 : 0),
        Cint(cfg.parallel_bidir ? 1 : 0),
    )
    out_c = BGPResultC(0, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL)

    status = ccall(_bg_sym(cfg.lib_path, :bgp_solve), Cint, (Ref{BGPInputC}, Ref{BGPResultC}), in_c, out_c)
    if status != 0 || out_c.status != 0
        err = _bg_last_error(cfg.lib_path)
        error("bgp_solve falhou (status=$status / out=$(out_c.status)): $err")
    end

    try
        n_paths = Int(out_c.n_paths)
        offs = unsafe_wrap(Vector{Int32}, out_c.path_offsets, n_paths + 1)
        vtx = unsafe_wrap(Vector{Int32}, out_c.path_vertex_ids, Int(out_c.total_vertices))
        return _bucket_routes_from_offsets(inst, g, π, already_in, n_paths, offs, vtx; cfg=cfg)
    finally
        ccall(_bg_sym(cfg.lib_path, :bgp_free_result), Cvoid, (Ref{BGPResultC},), out_c)
    end
end
