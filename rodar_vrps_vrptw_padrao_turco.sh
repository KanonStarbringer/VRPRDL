#!/usr/bin/env bash
# =========================================================
# rodar_vrps_vrptw_padrao_turco.sh
#
# Roda o demo VRPTW do VRPSolverDemos em todas as instâncias do
# VRPRDL turco projetadas para o formato Solomon.
#
# Pipeline:
#   1. (Opcional) regenera os .txt Solomon via
#      converter_jsons_para_vrptw_padrao.jl
#      Passe --skip-convert para pular essa etapa.
#   2. Para cada .txt em VRPRDL-triangle/vrptw_padrao_convertidos/,
#      chama `julia src/run.jl <arquivo.txt> -u UB --cfg <CFG>`
#      usando UB calculado no CSV de parâmetros (ou o default do demo).
#   3. Escreve log individual em
#      VRPRDL-triangle/logs_vrptw_padrao/<inst>.log.
#   4. Ao final, consolida um _summary.csv com custo, tempo e status.
#
# Variáveis de ambiente opcionais:
#   UB_MODE   : "trivial" (default) usa UB_trivial do CSV;
#               "fixed"  usa o valor de $UB_FIXED;
#               "demo"   usa o default do demo (-u 1e7 é o default).
#   UB_FIXED  : valor numérico (quando UB_MODE=fixed). Default 1000000.
#   CFG       : config do VRPSolver. Default "config/VRPTW_set_1.cfg"
#               (use "config/VRPTW_set_2.cfg" para instâncias Solomon-200+).
#   TIMEOUT_S : timeout por instância em segundos (default 3600).
#   SKIP      : "yes" para pular instâncias que já têm log completo.
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
CONVERTER="$BASE_DIR/converter_jsons_para_vrptw_padrao.jl"

UB_MODE="${UB_MODE:-trivial}"
UB_FIXED="${UB_FIXED:-1000000}"
CFG="${CFG:-config/VRPTW_set_1.cfg}"
TIMEOUT_S="${TIMEOUT_S:-3600}"
SKIP="${SKIP:-no}"

# -----------------------------------------------------------
# 0. Carrega BAPCOD_RCSP_LIB do ambiente do usuário
# -----------------------------------------------------------
# shellcheck disable=SC1090
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"

if [ -z "${BAPCOD_RCSP_LIB:-}" ]; then
    echo "Erro: BAPCOD_RCSP_LIB não está definido. O run.jl irá abortar."
    echo "Defina antes (idealmente em ~/.bashrc), por exemplo:"
    echo "  export BAPCOD_RCSP_LIB=/home/<user>/VRPSolver/bapcod-0.84/bapcodframework/build/Bapcod/libbapcod-shared.so"
    exit 1
fi

# -----------------------------------------------------------
# 1. Conversão opcional
# -----------------------------------------------------------
if [ "${1:-}" != "--skip-convert" ]; then
    echo "========================================"
    echo "[1/3] Regenerando Solomon a partir dos JSONs"
    echo "Converter: $CONVERTER"
    echo "========================================"
    "$JULIA_BIN" "$CONVERTER" || {
        echo "Erro: conversão falhou. Abortando."
        exit 1
    }
fi

# -----------------------------------------------------------
# 2. Sanity checks
# -----------------------------------------------------------
if [ ! -d "$INST_DIR" ]; then
    echo "Erro: pasta de instâncias não encontrada: $INST_DIR"
    exit 1
fi
if [ ! -f "$PARAMS_CSV" ]; then
    echo "Erro: arquivo de parâmetros não encontrado: $PARAMS_CSV"
    echo "Rode primeiro o converter (sem --skip-convert)."
    exit 1
fi
if [ ! -d "$VRPTW_DEMO_DIR" ]; then
    echo "Erro: pasta do demo VRPTW não encontrada: $VRPTW_DEMO_DIR"
    exit 1
fi
if [ ! -x "$JULIA_BIN" ]; then
    echo "Erro: executável do Julia não encontrado: $JULIA_BIN"
    exit 1
fi

mkdir -p "$LOG_DIR"
cd "$VRPTW_DEMO_DIR" || exit 1

# -----------------------------------------------------------
# 3. Ordena as instâncias numericamente (0, 1, 2, ..., 39)
# -----------------------------------------------------------
shopt -s nullglob
files=("$INST_DIR"/*.txt)

if [ "${#files[@]}" -eq 0 ]; then
    echo "Nenhum arquivo .txt encontrado em: $INST_DIR"
    exit 1
fi

mapfile -t files < <(printf '%s\n' "${files[@]}" | \
    awk -F'instance_|-triangle' '{print $2"\t"$0}' | sort -n | cut -f2)

echo "========================================"
echo "[2/3] Processando instâncias"
echo "  Instâncias  : $INST_DIR"
echo "  Logs        : $LOG_DIR"
echo "  Total       : ${#files[@]}"
echo "  UB_MODE     : $UB_MODE (UB_FIXED=$UB_FIXED)"
echo "  CFG         : $CFG"
echo "  Timeout/inst: ${TIMEOUT_S}s"
echo "========================================"

echo "instance,n_customers,capacity,k_ub,time_horizon,ub_used,status,best_cost,best_db,time_s" > "$SUMMARY_CSV"

# -----------------------------------------------------------
# 4. Loop principal
# -----------------------------------------------------------
total_start=$(date +%s)
for f in "${files[@]}"; do
    base=$(basename "$f" .txt)
    log_file="$LOG_DIR/${base}.log"

    line=$(grep "^${base}," "$PARAMS_CSV" || true)
    if [ -z "$line" ]; then
        echo "Aviso: $base não encontrado em $PARAMS_CSV - usando defaults"
        n_customers=0
        capacity=0
        k_ub=0
        time_horizon=0
        ub_trivial=1000000
    else
        IFS=',' read -r _inst n_customers capacity k_ub time_horizon ub_trivial _rel <<< "$line"
    fi

    case "$UB_MODE" in
        trivial) ub_used="$ub_trivial" ;;
        fixed)   ub_used="$UB_FIXED"   ;;
        demo)    ub_used=""            ;;  # deixa o demo usar o default dele
        *)       echo "UB_MODE inválido: $UB_MODE"; exit 1 ;;
    esac

    if [ "$SKIP" = "yes" ] && [ -s "$log_file" ] && grep -q "statistics_cols" "$log_file"; then
        echo "[skip] $base já tem log completo"
        continue
    fi

    echo
    echo "========================================"
    echo "Rodando: $base  (n=$n_customers, Q=$capacity, T=$time_horizon, UB=${ub_used:-demo-default})"
    echo "Log:     $log_file"
    echo "========================================"

    inst_start=$(date +%s)

    cmd=( "$JULIA_BIN" "src/run.jl" "$f" "--cfg" "$CFG" )
    if [ -n "$ub_used" ]; then
        cmd+=( "-u" "$ub_used" )
    fi

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

    # Extrai estatísticas do log para o summary
    stat_line=$(grep -m1 "^statistics:" "$log_file" || true)
    exit_code=$(grep -m1 '^exit_code=' "$log_file" | awk -F'=' '{print $2}')

    if [ -n "$stat_line" ]; then
        # statistics: <inst> & <optimal> & <cutoff> & <dbRoot> & <tRoot> & <nodes> & <bestDb> & <bestInc> & <tMain> \\
        optimal=$(echo "$stat_line" | awk -F' & ' '{print $2}')
        best_db=$(echo "$stat_line" | awk -F' & ' '{print $7}')
        best_inc=$(echo "$stat_line" | awk -F' & ' '{print $8}')
        if [ "$optimal" = "1" ]; then
            status_str="optimal"
        else
            status_str="feasible_or_unknown"
        fi
    elif [ "$exit_code" = "124" ]; then
        status_str="timeout"
        best_db=""
        best_inc=""
    elif grep -q -i "infeasible" "$log_file"; then
        status_str="infeasible"
        best_db=""
        best_inc=""
    else
        status_str="error"
        best_db=""
        best_inc=""
    fi

    echo "${base},${n_customers},${capacity},${k_ub},${time_horizon},${ub_used},${status_str},${best_inc},${best_db},${elapsed}" >> "$SUMMARY_CSV"
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo
echo "========================================"
echo "[3/3] Concluído. Tempo total: ${total_elapsed}s"
echo "  Resumo: $SUMMARY_CSV"
echo "========================================"
