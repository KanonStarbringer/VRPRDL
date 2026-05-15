#!/usr/bin/env bash
# =========================================================
# rodar_vrprdl_vrpsolver_extra.sh
#
# Roda o VRPRDL do amigo (VRPRDL_VRPSolver_/) para os
# conjuntos adicionais de instâncias em
#   instancias_turco/additional_instances/variant_1/
#   instancias_turco/additional_instances/variant_2/
#
# Cada variante tem seus próprios logs / soluções / summary
# para não colidir com os do conjunto original.
#
# Saídas (por variante "vN"):
#   logs_extra_vN/<basename>.log    (saída completa)
#   sols_extra_vN/<basename>.sol    (solução, pelo -o do run.jl)
#   logs_extra_vN/_summary.csv      (uma linha por instância)
#
# Variáveis de ambiente (com defaults):
#   TIMEOUT_S   : timeout por instância em segundos (default 3600 = 1h)
#   CFG         : config do VRPSolver (default config/VRPRDL.cfg)
#   UB          : primal bound (default 1e12 = "sem UB")
#   MINR, MAXR  : limites de rotas (default: do próprio run.jl)
#   JULIA_BIN   : binário do julia (default: julia no PATH)
#   SKIP        : "yes" => pula instâncias que já têm log com solução
#   ONLY        : lista de basenames separada por vírgula p/ rodar só esses
#                 (ex.: ONLY=instance_0,instance_3)
#   ENSURE_CPLEX: "yes" (default) => Pkg.add(CPLEX) se ausente
#
# Uso:
#   bash rodar_vrprdl_vrpsolver_extra.sh variant_1
#   bash rodar_vrprdl_vrpsolver_extra.sh variant_2
#   bash rodar_vrprdl_vrpsolver_extra.sh both
#   TIMEOUT_S=1800 bash rodar_vrprdl_vrpsolver_extra.sh both
#   ONLY=instance_0,instance_1 bash rodar_vrprdl_vrpsolver_extra.sh variant_1
# =========================================================
set -u

BASE_DIR="/mnt/c/Users/porin/OneDrive/Documentos/Python-Mestrado/Modelagem Matemática/Programação Inteira - Uchoa/Problema VRPRDL/VRPRDL_VRPSolver_"
EXTRA_ROOT="/mnt/c/Users/porin/OneDrive/Documentos/Python-Mestrado/Modelagem Matemática/Programação Inteira - Uchoa/Problema VRPRDL/instancias_turco/additional_instances"

CFG_DEFAULT="config/VRPRDL.cfg"
TIMEOUT_S="${TIMEOUT_S:-3600}"
CFG="${CFG:-$CFG_DEFAULT}"
UB="${UB:-1e12}"
MINR="${MINR:-}"
MAXR="${MAXR:-}"
JULIA_BIN="${JULIA_BIN:-julia}"
SKIP="${SKIP:-no}"
ONLY="${ONLY:-}"
ENSURE_CPLEX="${ENSURE_CPLEX:-yes}"

# shellcheck disable=SC1090
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"

if [ -z "${BAPCOD_RCSP_LIB:-}" ]; then
    echo "Erro: BAPCOD_RCSP_LIB não está definido."
    echo "Exporte algo como:"
    echo "  export BAPCOD_RCSP_LIB=\$HOME/VRPSolver/bapcodframework/build/Bapcod/libbapcod-shared.so"
    exit 1
fi

# ---------------------------------------------------------
# 0. Argumentos
# ---------------------------------------------------------
target="${1:-}"
case "$target" in
    variant_1|variant_2|both) ;;
    *)
        echo "Uso: $0 {variant_1|variant_2|both}"
        exit 2
        ;;
esac

variants_to_run=()
if [ "$target" = "both" ]; then
    variants_to_run=(variant_1 variant_2)
else
    variants_to_run=("$target")
fi

# ---------------------------------------------------------
# 1. Sanity checks de pastas
# ---------------------------------------------------------
[ -d "$BASE_DIR"   ] || { echo "Erro: pasta não encontrada: $BASE_DIR"; exit 1; }
[ -d "$EXTRA_ROOT" ] || { echo "Erro: pasta não encontrada: $EXTRA_ROOT"; exit 1; }

cd "$BASE_DIR" || exit 1

# ---------------------------------------------------------
# 2. Instancia o ambiente Julia (uma vez) e garante CPLEX
# ---------------------------------------------------------
echo "========================================"
echo "Instanciando ambiente Julia em: $BASE_DIR"
echo "========================================"

if [ "$ENSURE_CPLEX" = "yes" ]; then
    "$JULIA_BIN" --project=. -e '
        using Pkg
        Pkg.instantiate()
        try
            @eval using CPLEX
        catch
            println("CPLEX não encontrado no ambiente; adicionando...")
            Pkg.add("CPLEX")
        end
        Pkg.precompile()
    ' || { echo "Erro na instância do ambiente Julia."; exit 1; }
else
    "$JULIA_BIN" --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' \
        || { echo "Erro na instância do ambiente Julia."; exit 1; }
fi

# ---------------------------------------------------------
# 3. Loop principal
# ---------------------------------------------------------
total_start=$(date +%s)

for v in "${variants_to_run[@]}"; do
    inst_dir="$EXTRA_ROOT/$v"
    short_v="${v//variant_/v}"            # variant_1 -> v1
    log_dir="$BASE_DIR/logs_extra_${short_v}"
    sol_dir="$BASE_DIR/sols_extra_${short_v}"
    summary="$log_dir/_summary.csv"

    [ -d "$inst_dir" ] || { echo "Erro: pasta de instâncias não encontrada: $inst_dir"; exit 1; }
    mkdir -p "$log_dir" "$sol_dir"

    # Cabeçalho do summary, se ainda não existir
    if [ ! -f "$summary" ]; then
        echo "instance,optimal,cutoff,root_db,root_time_s,nb_nodes,best_db,best_inc,total_time_s,status,wall_time_s" > "$summary"
    fi

    # Coleta basenames (sem .txt)
    basenames=()
    if [ -n "$ONLY" ]; then
        IFS=',' read -ra basenames <<< "$ONLY"
    else
        for f in "$inst_dir"/*.txt; do
            [ -f "$f" ] || continue
            b=$(basename "$f" .txt)
            basenames+=("$b")
        done
        # ordena (numérico onde possível)
        IFS=$'\n' basenames=($(printf '%s\n' "${basenames[@]}" | sort -V))
        unset IFS
    fi

    if [ "${#basenames[@]}" -eq 0 ]; then
        echo "Nenhuma instância encontrada em $inst_dir"
        continue
    fi

    echo
    echo "========================================"
    echo "Variante:        $v"
    echo "Pasta:           $inst_dir"
    echo "Instâncias:      ${#basenames[@]}   (${basenames[*]})"
    echo "Config:          $CFG"
    echo "UB:              $UB"
    echo "MINR/MAXR:       ${MINR:-(default)} / ${MAXR:-(default)}"
    echo "Timeout:         ${TIMEOUT_S}s"
    echo "Skip existentes: $SKIP"
    echo "Logs:            $log_dir"
    echo "Sols:            $sol_dir"
    echo "Summary:         $summary"
    echo "========================================"

    for base in "${basenames[@]}"; do
        f="$inst_dir/${base}.txt"
        log_file="$log_dir/${base}.log"
        sol_file="$sol_dir/${base}.sol"

        if [ ! -f "$f" ]; then
            echo "Aviso: arquivo não encontrado: $f (pulando)"
            continue
        fi
        if [ "$SKIP" = "yes" ] && [ -f "$log_file" ] && grep -q "^Cost " "$log_file"; then
            echo ">>> $base já tem log com solução; pulando."
            continue
        fi

        cmd=( "$JULIA_BIN" "--project=." "src/run.jl" "$f" "-c" "$CFG" "-u" "$UB" "-o" "$sol_file" )
        [ -n "$MINR" ] && cmd+=( "-m" "$MINR" )
        [ -n "$MAXR" ] && cmd+=( "-M" "$MAXR" )

        echo
        echo "----------------------------------------"
        echo "Rodando: [$v] $base"
        echo "Log:     $log_file"
        echo "Sol:     $sol_file"
        echo "Cmd:     ${cmd[*]}"
        echo "----------------------------------------"

        inst_start=$(date +%s)
        {
            echo "instance_file=$f"
            echo "instance_name=$base"
            echo "variant=$v"
            echo "cfg=$CFG"
            echo "ub=$UB"
            echo "timeout_s=$TIMEOUT_S"
            echo "start_time=$(date '+%Y-%m-%d %H:%M:%S')"
            echo "cmd=${cmd[*]}"
            echo
            timeout "${TIMEOUT_S}s" "${cmd[@]}"
            status=$?
            echo
            echo "end_time=$(date '+%Y-%m-%d %H:%M:%S')"
            echo "exit_code=$status"
        } 2>&1 | tee "$log_file"
        inst_end=$(date +%s)
        wall=$((inst_end - inst_start))

        stat_line=$(grep -m1 "^statistics:" "$log_file" || true)
        exit_code=$(grep -m1 '^exit_code=' "$log_file" | awk -F'=' '{print $2}')

        optimal=""; cutoff=""; root_db=""; root_time=""
        nb_nodes=""; best_db=""; best_inc=""; total_time=""; status_str=""

        if [ -n "$stat_line" ]; then
            line_stripped="${stat_line#statistics:}"
            line_stripped="${line_stripped%\\\\}"
            IFS='&' read -r _n optimal cutoff root_db root_time nb_nodes best_db best_inc total_time <<< "$line_stripped"
            optimal=$(echo "$optimal" | xargs)
            cutoff=$(echo "$cutoff" | xargs)
            root_db=$(echo "$root_db" | xargs)
            root_time=$(echo "$root_time" | xargs)
            nb_nodes=$(echo "$nb_nodes" | xargs)
            best_db=$(echo "$best_db" | xargs)
            best_inc=$(echo "$best_inc" | xargs)
            total_time=$(echo "$total_time" | xargs)
            if [ "$optimal" = "1" ]; then
                status_str="optimal"
            else
                status_str="feasible_or_unknown"
            fi
        elif [ "$exit_code" = "124" ]; then
            status_str="timeout"
        elif grep -q -i "inviável\|infeasible" "$log_file"; then
            status_str="infeasible"
        else
            status_str="error"
        fi

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$base" "$optimal" "$cutoff" "$root_db" "$root_time" \
            "$nb_nodes" "$best_db" "$best_inc" "$total_time" "$status_str" "$wall" \
            >> "$summary"

        echo ">>> [$v] $base -> status=$status_str, cost=${best_inc:-NA}, wall=${wall}s"
    done
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo
echo "========================================"
echo "Concluído em ${total_elapsed}s."
echo "Variantes rodadas: ${variants_to_run[*]}"
echo "========================================"
