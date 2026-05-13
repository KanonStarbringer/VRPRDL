# =========================================================
# converter_jsons_para_vrptw.jl
#
# Converte JSONs do VRPRDL para o formato Solomon (VRPTW)
# aceito pelo demo VRPSolverDemos/other/VRPTW.
#
# Estratégia de projeção (caminho B do roadmap):
#
#  MODO :enclose (padrão, recomendado)
#    - Coordenada do cliente c = localização mais PRÓXIMA do depot
#      (menor distância euclidiana). Isto maximiza a viabilidade
#      espaço-tempo.
#    - Janela de c = UNIÃO das janelas de suas localizações:
#        [min_c(time_opening), max_c(time_closing)]
#      Permissiva mas informativa (preserva o deadline global do
#      cliente).
#    - Se ainda assim Euclid(depot, loc) > max_close, relaxa para
#      [0, time_horizon] (garantia de viabilidade).
#
#  MODO :widest  (legado, NÃO usar)
#    - Escolhe a localização de janela mais larga. Pode produzir
#      instâncias VRPTW infeasible quando a localização escolhida
#      fica longe do depot mas tem janela apertada.
#
#  MODO :first   (legado)
#    - Primeira localização (home) + janela dela. Muito restritivo.
#
# - Tempos de viagem: o demo VRPTW calcula EUC_2D internamente a
#   partir das coordenadas; é uma APROXIMAÇÃO da matriz travel_time
#   real do VRPRDL (aceitável pois o VRPSolver aqui é só gerador
#   de rotas candidatas, não pricer exato).
# - Capacidade: do JSON.
# - Nº de veículos: n_customers (limite prático; VRPSolver usa o
#   que precisar dentro desse teto).
# - Service time: 0 (padrão Özbayğın).
#
# Saídas em VRPRDL-triangle/vrptw_convertidos/ no formato Solomon.
# =========================================================

using JSON3
using Printf

function get_base_dir()
    return joinpath(@__DIR__, "VRPRDL-triangle")
end

# ---------------------------------------------------------
# Utilidades
# ---------------------------------------------------------

"Cliente real = não é depot inicial (cid=0) nem depot final (demand=0 com cid alto)."
function is_customer_real(c::Dict{String,Any})
    return c["customer_id"] != 0 && c["demand"] > 0
end

"Escolhe a localização com a janela mais larga (time_closing - time_opening)."
function pick_widest_window(customer::Dict{String,Any}, ::Any, ::Any)
    locs = customer["locations"]
    isempty(locs) && error("Cliente sem localizações.")
    best = locs[1]
    best_w = best["time_closing"] - best["time_opening"]
    for l in locs
        w = l["time_closing"] - l["time_opening"]
        if w > best_w
            best = l
            best_w = w
        end
    end
    return best, best["time_opening"], best["time_closing"]
end

"Pega a primeira localização (home) + a janela dela."
function pick_first(customer::Dict{String,Any}, ::Any, ::Any)
    loc = customer["locations"][1]
    return loc, loc["time_opening"], loc["time_closing"]
end

"""
Modo :enclose — para cada cliente, escolhe UMA localização+janela
do VRPRDL original que seja SINGLETON-FEASIBLE, isto é, para a
qual a rota `0 → c → 0` respeite (a) a janela do cliente e
(b) o horizonte do depot (o veículo precisa voltar antes de
`time_horizon`).

Condições de viabilidade (Euclidiana `d`, serviço `s`, janela
`[open_l, close_l]`, horizonte `T`):

    d ≤ close_l                              # chega dentro da janela
    max(open_l, d) + s + d ≤ T               # volta antes de fechar o dia

Entre as localizações viáveis, prefere a janela de maior largura
(`close_l − open_l`). Se nenhuma localização for singleton-feasible,
faz fallback para a localização mais próxima do depot e ajusta a
janela para `[0, T − d − s]` (para garantir round-trip). Se ainda
assim `T − d − s ≤ 0`, o cliente é fundamentalmente inalcançável;
retorna `(loc_mais_próxima, 0, T, d, false)` e a instância VRPTW
ficará infeasible mesmo.

Retorna `(loc, open, close, d_depot, reachable)`.
"""
function pick_enclose(customer::Dict{String,Any},
                      coords::Dict{String,Any},
                      depot_xy::Dict;
                      service_time::Int = 0,
                      time_horizon::Int = 0)
    locs = customer["locations"]
    isempty(locs) && error("Cliente sem localizações.")

    closest_loc = locs[1]
    closest_d = Inf
    best_reach_loc = nothing
    best_reach_width = -1
    best_reach_d = Inf
    best_reach_open = 0
    best_reach_close = 0

    for l in locs
        xy = coords[string(l["location_id"])]
        d = sqrt((xy["x"] - depot_xy["x"])^2 + (xy["y"] - depot_xy["y"])^2)

        if d < closest_d
            closest_d = d
            closest_loc = l
        end

        open_l  = l["time_opening"]
        close_l = l["time_closing"]
        earliest_start = max(open_l, d)
        latest_return  = earliest_start + service_time + d
        reachable = (d <= close_l) && (latest_return <= time_horizon)

        if reachable
            width = close_l - open_l
            if width > best_reach_width
                best_reach_width = width
                best_reach_loc   = l
                best_reach_d     = d
                best_reach_open  = open_l
                best_reach_close = close_l
            end
        end
    end

    if best_reach_loc !== nothing
        return (best_reach_loc,
                best_reach_open,
                best_reach_close,
                best_reach_d,
                true)
    else
        # fallback: loc mais próxima + janela ajustada para round-trip
        close_eff = time_horizon - Int(ceil(closest_d)) - service_time
        if close_eff > 0
            return (closest_loc, 0, close_eff, closest_d, false)
        else
            # cliente fundamentalmente inalcançável
            return (closest_loc, 0, time_horizon, closest_d, false)
        end
    end
end

# ---------------------------------------------------------
# Escrita Solomon
# ---------------------------------------------------------

"""
Escreve uma instância VRPTW no formato Solomon a partir de um JSON VRPRDL.

- `mode`: `:enclose` (recomendado), `:widest`, `:first`.
- `service_time`: tempo de serviço (0 = padrão Özbayğın).

Retorna `(n_customers, n_relaxed)` onde `n_relaxed` é o número de clientes
cujo deadline máximo foi excedido pela distância Euclidiana ao depot e
cuja janela foi relaxada para `[0, time_horizon]` (modo `:enclose`).
"""
function write_solomon(instance::Dict{String,Any},
                      output_path::AbstractString;
                      mode::Symbol = :enclose,
                      service_time::Int = 0)
    gp = instance["general_parameters"]
    customers = instance["customer_schedules"]
    coords = instance["location_coordinates"]

    depot = first(c for c in customers if c["customer_id"] == 0)
    real_customers = sort!(
        [c for c in customers if is_customer_real(c)];
        by = c -> c["customer_id"],
    )

    name = replace(instance["source_file"], ".txt" => "")
    capacity = gp["vehicle_capacity"]
    time_horizon = gp["time_horizon"]
    n_vehicles = length(real_customers)

    depot_loc = depot["locations"][1]
    depot_xy = coords[string(depot_loc["location_id"])]

    n_relaxed = 0

    open(output_path, "w") do io
        println(io, name)
        println(io)
        println(io, "VEHICLE")
        println(io, "NUMBER     CAPACITY")
        @printf(io, "  %d         %d\n", n_vehicles, capacity)
        println(io)
        println(io, "CUSTOMER")
        println(io, "CUST NO.  XCOORD.    YCOORD.    DEMAND   READY TIME   DUE DATE   SERVICE TIME")
        println(io)

        @printf(io, "    %d      %d         %d          %d          %d       %d          %d\n",
                0,
                round(Int, depot_xy["x"]), round(Int, depot_xy["y"]),
                0,
                0, time_horizon,
                0)

        for (idx, c) in enumerate(real_customers)
            local loc::Dict{String,Any}
            local open_c::Int
            local close_c::Int

            if mode == :enclose
                loc_e, open_u, close_u, _d, reachable =
                    pick_enclose(c, coords, depot_xy;
                                 service_time=service_time,
                                 time_horizon=time_horizon)
                loc = loc_e
                open_c  = Int(open_u)
                close_c = Int(close_u)
                if !reachable
                    n_relaxed += 1
                end
            elseif mode == :widest
                loc, open_c, close_c = pick_widest_window(c, coords, depot_xy)
            elseif mode == :first
                loc, open_c, close_c = pick_first(c, coords, depot_xy)
            else
                error("mode inválido: $mode")
            end

            xy = coords[string(loc["location_id"])]
            @printf(io, "    %d      %d         %d          %d         %d          %d          %d\n",
                    idx,
                    round(Int, xy["x"]), round(Int, xy["y"]),
                    c["demand"],
                    open_c, close_c,
                    service_time)
        end
    end

    return (length(real_customers), n_relaxed)
end

# ---------------------------------------------------------
# Batch
# ---------------------------------------------------------

"""
Converte todos os JSONs em VRPRDL-triangle/json_convertidos/
para VRPRDL-triangle/vrptw_convertidos/.
"""
function convert_all_json_to_vrptw(;
        mode::Symbol = :enclose,       # :enclose | :widest | :first
        service_time::Int = 0)
    base_dir = get_base_dir()
    json_dir = joinpath(base_dir, "json_convertidos")
    out_dir  = joinpath(base_dir, "vrptw_convertidos")

    isdir(json_dir) || error("Pasta de JSONs não encontrada: $json_dir")
    isdir(out_dir)  || mkdir(out_dir)

    files = sort(filter(f -> endswith(lowercase(f), ".json"), readdir(json_dir)))
    converted = 0
    failed = 0
    total_relaxed = 0

    println("========================================")
    println("Pasta de JSONs : $json_dir")
    println("Pasta de VRPTW : $out_dir")
    println("mode           : $mode")
    println("service_time   : $service_time")
    println("========================================")

    for file in files
        input_path = joinpath(json_dir, file)
        output_name = replace(file, r"\.json$" => ".txt")
        output_path = joinpath(out_dir, output_name)

        try
            print("Convertendo: $file ... ")
            instance = JSON3.read(read(input_path, String), Dict{String,Any})
            n, n_relaxed = write_solomon(instance, output_path;
                                          mode=mode, service_time=service_time)
            total_relaxed += n_relaxed
            if n_relaxed > 0
                println("OK ($n clientes, $n_relaxed com janela relaxada)")
            else
                println("OK ($n clientes)")
            end
            converted += 1
        catch err
            failed += 1
            println("[ERRO]")
            println("       ", err)
        end
    end

    println("========================================")
    println("Conversão concluída.")
    println("Convertidos      : $converted")
    println("Falharam         : $failed")
    println("Clientes relaxados: $total_relaxed (janela → [0, time_horizon])")
    println("========================================")
end

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

convert_all_json_to_vrptw()
