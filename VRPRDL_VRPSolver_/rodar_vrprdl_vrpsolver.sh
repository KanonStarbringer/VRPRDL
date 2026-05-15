#!/usr/bin/env bash
# =========================================================
# rodar_vrprdl_vrpsolver.sh
#
# Roda o VRPRDL do amigo (VRPRDL_VRPSolver_/) para as 40
# instâncias em data_vrprdl/, gerando:
#   - logs/instance_<k>-triangle.log   (saída completa)
#   - sol_instance_<k>.txt             (solução, pelo -o do run.jl)
#   - logs/_summary.csv                (uma linha por instância)
#
# Variáveis de ambiente (com defaults):
#   TIMEOUT_S   : timeout por instância em segundos (default 10800 = 3h)
#   CFG         : config do VRPSolver (default config/VRPRDL.cfg)
#   UB          : primal bound (default 1e12 = "sem UB")
#   MINR, MAXR  : limites de rotas (default: do próprio run.jl)
#   JULIA_BIN   : binário do julia (default: julia no PATH)
#   SKIP        : "yes" => pula instâncias que já têm log
#   ONLY        : lista de ids separada por vírgula p/ rodar só esses
#                 (ex.: ONLY=31,32)
#   ENSURE_CPLEX: "yes" (default) => roda Pkg.add(CPLEX) se ainda não
#                 estiver no ambiente
#
# Uso:
#   bash rodar_vrprdl_vrpsolver.sh
#   ONLY=31,32 TIMEOUT_S=14400 bash rodar_vrprdl_vrpsolver.sh
#   SKIP=yes bash rodar_vrprdl_vrpsolver.sh
# =========================================================
set -u

BASE_DIR="/mnt/c/Users/porin/OneDrive/Documentos/Python-Mestrado/Modelagem Matemática/Programação Inteira - Uchoa/Problema VRPRDL/VRPRDL_VRPSolver_"
INST_DIR="$BASE_DIR/data_vrprdl"
CFG_DEFAULT="config/VRPRDL.cfg"
LOG_DIR="$BASE_DIR/logs"
SOL_DIR="$BASE_DIR"

TIMEOUT_S="${TIMEOUT_S:-10800}"
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

for p in "$BASE_DIR" "$INST_DIR"; do
    [ -d "$p" ] || { echo "Erro: pasta não encontrada: $p"; exit 1; }
done
mkdir -p "$LOG_DIR"

cd "$BASE_DIR" || exit 1

# -----------------------------------------------------------
# 1. Instancia o ambiente Julia (uma vez) e garante CPLEX
# -----------------------------------------------------------
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

# -----------------------------------------------------------
# 2. Determina a lista de instâncias a rodar
# -----------------------------------------------------------
ids=()
if [ -n "$ONLY" ]; then
    IFS=',' read -ra ids <<< "$ONLY"
else
    for f in "$INST_DIR"/instance_*-triangle.txt; do
        b=$(basename "$f" -triangle.txt)
        k="${b#instance_}"
        ids+=("$k")
    done
    # ordena numericamente
    IFS=$'\n' ids=($(printf '%s\n' "${ids[@]}" | sort -n))
    unset IFS
fi

if [ "${#ids[@]}" -eq 0 ]; then
    echo "Nenhuma instância para rodar."
    exit 0
fi

# -----------------------------------------------------------
# 3. Cabeçalho do summary (se não existir)
# -----------------------------------------------------------
SUMMARY="$LOG_DIR/_summary.csv"
if [ ! -f "$SUMMARY" ]; then
    echo "instance,optimal,cutoff,root_db,root_time_s,nb_nodes,best_db,best_inc,total_time_s,status,wall_time_s" > "$SUMMARY"
fi

echo
echo "========================================"
echo "Instâncias:    ${#ids[@]}   (${ids[*]})"
echo "Config:        $CFG"
echo "UB:            $UB"
echo "MINR/MAXR:     ${MINR:-(default)} / ${MAXR:-(default)}"
echo "Timeout:       ${TIMEOUT_S}s"
echo "Skip existentes: $SKIP"
echo "Log dir:       $LOG_DIR"
echo "========================================"

# -----------------------------------------------------------
# 4. Loop
# -----------------------------------------------------------
total_start=$(date +%s)
for k in "${ids[@]}"; do
    base="instance_${k}-triangle"
    f="$INST_DIR/${base}.txt"
    log_file="$LOG_DIR/${base}.log"
    sol_file="$SOL_DIR/sol_instance_${k}.txt"

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
    echo "========================================"
    echo "Rodando: $base"
    echo "Log:     $log_file"
    echo "Sol:     $sol_file"
    echo "Cmd:     ${cmd[*]}"
    echo "========================================"

    inst_start=$(date +%s)
    {
        echo "instance_file=$f"
        echo "instance_name=$base"
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

    # Extrai a linha "statistics: ..." produzida pelo run.jl
    stat_line=$(grep -m1 "^statistics:" "$log_file" || true)
    exit_code=$(grep -m1 '^exit_code=' "$log_file" | awk -F'=' '{print $2}')

    optimal=""; cutoff=""; root_db=""; root_time=""
    nb_nodes=""; best_db=""; best_inc=""; total_time=""; status_str=""

    if [ -n "$stat_line" ]; then
        # Formato: statistics: <name> & <optimal> & <cutoff> & <root_db> & <root_time> & <nb_nodes> & <best_db> & <best_inc> & <total_time> \\
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
        >> "$SUMMARY"

    echo ">>> $base -> status=$status_str, cost=${best_inc:-NA}, wall=${wall}s"
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo
echo "========================================"
echo "Concluído em ${total_elapsed}s."
echo "Resumo: $SUMMARY"
echo "========================================"
