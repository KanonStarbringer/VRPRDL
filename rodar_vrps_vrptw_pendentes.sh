#!/usr/bin/env bash
# =========================================================
# rodar_vrps_vrptw_pendentes.sh
#
# Re-roda apenas as instâncias VRPTW cujo status em
# VRPRDL-triangle/logs_vrptw_padrao/_summary.csv
# seja DIFERENTE de "optimal" (timeout, error, infeasible,
# feasible_or_unknown, ou linha ausente).
#
# O log antigo dessas instâncias é sobrescrito e as linhas
# correspondentes do _summary.csv são substituídas com os
# novos resultados.
#
# Variáveis de ambiente (com defaults pensados para n=120):
#   TIMEOUT_S : timeout por instância em segundos (default 10800 = 3h)
#   CFG       : config do VRPTW (default config/VRPTW_set_2.cfg, mais
#               agressivo p/ instâncias maiores)
#   UB_MODE   : "trivial" (default, usa ub_trivial do CSV) | "fixed" | "demo"
#   UB_FIXED  : usado quando UB_MODE=fixed (default 1000000)
#
# Uso rápido:
#   bash rodar_vrps_vrptw_pendentes.sh                # usa defaults
#   TIMEOUT_S=21600 CFG=config/VRPTW_set_2.cfg \
#        bash rodar_vrps_vrptw_pendentes.sh           # 6h + set_2
#   UB_MODE=fixed UB_FIXED=5000 \
#        bash rodar_vrps_vrptw_pendentes.sh           # UB apertado
# =========================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
INST_DIR="$BASE_DIR/VRPRDL-triangle/vrptw_padrao_convertidos"
LOG_DIR="$BASE_DIR/VRPRDL-triangle/logs_vrptw_padrao"
PARAMS_CSV="$INST_DIR/_params.csv"
SUMMARY_CSV="$LOG_DIR/_summary.csv"

VRPTW_DEMO_DIR="$HOME/VRPSolver/VRPSolverDemos/other/VRPTW"
JULIA_BIN="$HOME/.juliaup/bin/julia"

TIMEOUT_S="${TIMEOUT_S:-10800}"
CFG="${CFG:-config/VRPTW_set_2.cfg}"
UB_MODE="${UB_MODE:-trivial}"
UB_FIXED="${UB_FIXED:-1000000}"

# shellcheck disable=SC1090
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"

if [ -z "${BAPCOD_RCSP_LIB:-}" ]; then
    echo "Erro: BAPCOD_RCSP_LIB não está definido. Abortando."
    exit 1
fi
for p in "$INST_DIR" "$LOG_DIR" "$VRPTW_DEMO_DIR"; do
    [ -d "$p" ] || { echo "Erro: não encontrado: $p"; exit 1; }
done
for p in "$PARAMS_CSV" "$SUMMARY_CSV" "$JULIA_BIN"; do
    [ -e "$p" ] || { echo "Erro: não encontrado: $p"; exit 1; }
done

# -----------------------------------------------------------
# 1. Determina lista de pendentes a partir do _summary.csv
#    Pendente = qualquer linha cujo campo status (7º) != "optimal".
# -----------------------------------------------------------
pending=()
while IFS=',' read -r inst ncust cap kub thor ubused status rest; do
    [ "$inst" = "instance" ] && continue
    [ -z "${inst}" ] && continue
    if [ "$status" != "optimal" ]; then
        pending+=("$inst|$status")
    fi
done < "$SUMMARY_CSV"

if [ "${#pending[@]}" -eq 0 ]; then
    echo "Nada a fazer: todas as instâncias já estão com status=optimal."
    exit 0
fi

echo "========================================"
echo "Instâncias pendentes (status != optimal):"
for row in "${pending[@]}"; do
    inst="${row%%|*}"
    st="${row##*|}"
    printf "  - %-30s (status atual: %s)\n" "$inst" "$st"
done
echo "----------------------------------------"
echo "  TIMEOUT_S : ${TIMEOUT_S}s"
echo "  CFG       : $CFG"
echo "  UB_MODE   : $UB_MODE (UB_FIXED=$UB_FIXED)"
echo "========================================"

cd "$VRPTW_DEMO_DIR" || exit 1

# -----------------------------------------------------------
# 2. Loop
# -----------------------------------------------------------
total_start=$(date +%s)
for row in "${pending[@]}"; do
    base="${row%%|*}"
    f="$INST_DIR/${base}.txt"
    log_file="$LOG_DIR/${base}.log"

    if [ ! -f "$f" ]; then
        echo "Aviso: arquivo não encontrado: $f (pulando)"
        continue
    fi

    line=$(grep "^${base}," "$PARAMS_CSV" || true)
    if [ -z "$line" ]; then
        echo "Aviso: $base não encontrado em $PARAMS_CSV (pulando)"
        continue
    fi
    IFS=',' read -r _i n_customers capacity k_ub time_horizon ub_trivial _rel <<< "$line"

    case "$UB_MODE" in
        trivial) ub_used="$ub_trivial" ;;
        fixed)   ub_used="$UB_FIXED"   ;;
        demo)    ub_used=""            ;;
        *)       echo "UB_MODE inválido: $UB_MODE"; exit 1 ;;
    esac

    echo
    echo "========================================"
    echo "Rodando: $base  (n=$n_customers, Q=$capacity, T=$time_horizon, UB=${ub_used:-demo-default})"
    echo "Log:     $log_file"
    echo "========================================"

    inst_start=$(date +%s)

    cmd=( "$JULIA_BIN" "src/run.jl" "$f" "--cfg" "$CFG" )
    [ -n "$ub_used" ] && cmd+=( "-u" "$ub_used" )

    {
        echo "instance_file=$f"
        echo "instance_name=$base"
        echo "n_customers=$n_customers"
        echo "capacity=$capacity"
        echo "k_ub=$k_ub"
        echo "time_horizon=$time_horizon"
        echo "ub_mode=$UB_MODE"
        echo "ub_used=${ub_used:-(demo default)}"
        echo "cfg=$CFG"
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
    elapsed=$((inst_end - inst_start))

    stat_line=$(grep -m1 "^statistics:" "$log_file" || true)
    exit_code=$(grep -m1 '^exit_code=' "$log_file" | awk -F'=' '{print $2}')

    if [ -n "$stat_line" ]; then
        optimal=$(echo "$stat_line" | awk -F' & ' '{print $2}')
        best_db=$(echo "$stat_line" | awk -F' & ' '{print $7}')
        best_inc=$(echo "$stat_line" | awk -F' & ' '{print $8}')
        if [ "$optimal" = "1" ]; then
            status_str="optimal"
        else
            status_str="feasible_or_unknown"
        fi
    elif [ "$exit_code" = "124" ]; then
        status_str="timeout"; best_db=""; best_inc=""
    elif grep -q -i "infeasible" "$log_file"; then
        status_str="infeasible"; best_db=""; best_inc=""
    else
        status_str="error"; best_db=""; best_inc=""
    fi

    new_row="${base},${n_customers},${capacity},${k_ub},${time_horizon},${ub_used},${status_str},${best_inc},${best_db},${elapsed}"
    # Substitui a linha antiga dessa instância no _summary.csv
    tmp_csv="$(mktemp)"
    awk -v base="$base" -v new="$new_row" -F',' '
        NR==1 { print; next }
        $1==base { print new; next }
        { print }
    ' "$SUMMARY_CSV" > "$tmp_csv" && mv "$tmp_csv" "$SUMMARY_CSV"

    echo ">>> $base -> status=$status_str, best_cost=${best_inc:-NA}, time=${elapsed}s"
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo
echo "========================================"
echo "Rerun concluído em ${total_elapsed}s."
echo "Resumo atualizado: $SUMMARY_CSV"
echo "========================================"
echo
echo "Status atual das (antigas) pendentes:"
for row in "${pending[@]}"; do
    base="${row%%|*}"
    grep "^${base}," "$SUMMARY_CSV" || true
done
