function build_model(data::DataVRPRDL, app::Dict{String,Any})
    A = arcs(data)
    C = real_customers(data)
    Q = veh_capacity(data)
    T = planning_horizon(data)
    V = all_locations(data)

    vrprdl = VrpModel()
    @variable(vrprdl.formulation, x[a in A], Int)
    @objective(vrprdl.formulation, Min, sum(c(data, a) * x[a] for a in A))

    # Cada cliente real deve ser atendido exatamente uma vez em uma de suas localizações.
    @constraint(
        vrprdl.formulation,
        cover[cust in C],
        sum(x[a] for a in A if a[2] in locs_of_customer(data, cust)) == 1.0,
    )

    function build_graph()
        v_source = data.source_loc
        v_sink = data.sink_loc
        L = max(app["minr"], lowerBoundNbVehicles(data))
        U = min(app["maxr"], upperBoundNbVehicles(data))
        _assert(L <= U, "Os limites de rotas são inconsistentes: minr=$L, maxr=$U")

        G = VrpGraph(vrprdl, V, v_source, v_sink, (L, U))

        cap_res_id = add_resource!(G, main = true)
        time_res_id = add_resource!(G, main = true)

        for v in V
            if v != v_source
                set_resource_bounds!(G, v, cap_res_id, 0.0, Q)
                set_resource_bounds!(G, v, time_res_id, l(data, v), u(data, v))
            end
        end

        for a in A
            i, j = a
            arc_id = add_arc!(G, i, j, x[a])
            set_arc_consumption!(G, arc_id, cap_res_id, d(data, j))
            set_arc_consumption!(G, arc_id, time_res_id, t(data, a))
        end
        return G, cap_res_id, time_res_id
    end

    G, cap_res_id, time_res_id = build_graph()
    add_graph!(vrprdl, G)

    packing_sets = [[(G, loc) for loc in locs_of_customer(data, cust)] for cust in C]
    set_vertex_packing_sets!(vrprdl, packing_sets)

    # Distância entre elementarity/packing sets = melhor deslocamento entre localizações dos dois clientes.
    define_elementarity_sets_distance_matrix!(vrprdl, G, cluster_distance_matrix(data))

    # RCC e SKP sobre clientes reais.
    add_capacity_cut_separator!(vrprdl, [(packing_sets[k], data.demand_of_customer[C[k]]) for k in eachindex(C)], Q)
    if app["strong_kpath_cuts"]
        add_strongkpath_cut_separator!(vrprdl, [(packing_sets[k], data.demand_of_customer[C[k]]) for k in eachindex(C)], Q)
    end

    # Branching principal nos arcos agregados do modelo.
    set_branching_priority!(vrprdl, "x", 2)

    # Branching adicional sobre consumo acumulado dos recursos pode ajudar sem alterar a correção.
    if app["resource_branching"]
        enable_resource_consumption_branching!(vrprdl, 1)
    end

    return vrprdl, x
end
