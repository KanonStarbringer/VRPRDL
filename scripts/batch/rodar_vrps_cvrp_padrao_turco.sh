#!/usr/bin/env bash
# =========================================================
# rodar_vrps_cvrp_padrao_turco.sh
#
# Roda o demo CVRP do VRPSolverDemos em todas as instâncias do
# VRPRDL turco projetadas para o formato TSPLIB/CVRP padrão.
#
# Pipeline:
#   1. (Opcional) regenera os .vrp via converter_jsons_para_cvrp_padrao.jl
#      Passe --skip-convert para pular essa etapa.
#   2. Para cada .vrp em VRPRDL-triangle/cvrp_padrao_convertidos/,
#      chama `julia src/run.jl <arquivo.vrp> -m K_LB -M N -u UB`
#      usando K_LB lido de `_params.csv` (ceil(demanda_total/capacidade)).
#   3. Escreve log individual em VRPRDL-triangle/logs_cvrp_padrao/<inst>.log.
#   4. Ao final, consolida um _summary.csv com custo, tempo, status.
#
# Opções (env vars):
#   UB        : upper bound primal (default 1000000)
#   TIMEOUT_S : timeout por instância em segundos (default 3600)
#   SKIP      : "yes" para pular instâncias que já têm log OK
# =========================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE_DIR="$REPO_ROOT"
INST_DIR="$BASE_DIR/VRPRDL-triangle/cvrp_padrao_convertidos"
LOG_DIR="$BASE_DIR/VRPRDL-triangle/logs_cvrp_padrao"
PARAMS_CSV="$INST_DIR/_params.csv"
SUMMARY_CSV="$LOG_DIR/_summary.csv"

VRP_DEMOS_DIR="$HOME/VRPSolver/VRPSolverDemos"
JULIA_BIN="$HOME/.juliaup/bin/julia"
CONVERTER="$REPO_ROOT/converters/converter_jsons_para_cvrp_padrao.jl"

UB="${UB:-1000000}"
TIMEOUT_S="${TIMEOUT_S:-3600}"
SKIP="${SKIP:-no}"

# -----------------------------------------------------------
# 0. Carrega variáveis do ambiente (BAPCOD_RCSP_LIB etc.)
# -----------------------------------------------------------
# shellcheck disable=SC1090
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"

if [ -z "${BAPCOD_RCSP_LIB:-}" ]; then
    echo "Aviso: BAPCOD_RCSP_LIB não está definido. O run.jl irá abortar."
    echo "Defina antes de rodar, por exemplo em ~/.bashrc:"
    echo "  export BAPCOD_RCSP_LIB=/home/<user>/VRPSolver/bapcod-0.84/bapcodframework/build/Bapcod/libbapcod-shared.so"
    exit 1
fi

# -----------------------------------------------------------
# 1. Conversão opcional
# -----------------------------------------------------------
if [ "${1:-}" != "--skip-convert" ]; then
    echo "========================================"
    echo "[1/3] Regenerando .vrp a partir dos JSONs"
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
if [ ! -d "$VRP_DEMOS_DIR" ]; then
    echo "Erro: pasta VRPSolverDemos não encontrada: $VRP_DEMOS_DIR"
    exit 1
fi
if [ ! -x "$JULIA_BIN" ]; then
    echo "Erro: executável do Julia não encontrado: $JULIA_BIN"
    exit 1
fi

mkdir -p "$LOG_DIR"
cd "$VRP_DEMOS_DIR" || exit 1

# -----------------------------------------------------------
# 3. Ordena as instâncias de forma "humana" (0,1,2,...,39)
# -----------------------------------------------------------
shopt -s nullglob
files=("$INST_DIR"/*.vrp)

if [ "${#files[@]}" -eq 0 ]; then
    echo "Nenhum arquivo .vrp encontrado em: $INST_DIR"
    exit 1
fi

# Ordenação numérica pelo índice da instância
mapfile -t files < <(printf '%s\n' "${files[@]}" | \
    awk -F'instance_|-triangle' '{print $2"\t"$0}' | sort -n | cut -f2)

echo "========================================"
echo "[2/3] Processando instâncias"
echo "  Instâncias .vrp : $INST_DIR"
echo "  Logs           : $LOG_DIR"
echo "  Total          : ${#files[@]}"
echo "  UB             : $UB"
echo "  Timeout/inst.  : ${TIMEOUT_S}s"
echo "========================================"

# Cabeçalho do CSV resumo
echo "instance,n_customers,k_lb,k_ub,ub,status,best_cost,best_db,time_s" > "$SUMMARY_CSV"

# -----------------------------------------------------------
# 4. Loop principal
# -----------------------------------------------------------
total_start=$(date +%s)
for f in "${files[@]}"; do
    base=$(basename "$f" .vrp)
    log_file="$LOG_DIR/${base}.log"

    # Lê K_LB / N / cap do CSV
    line=$(grep "^${base}," "$PARAMS_CSV" || true)
    if [ -z "$line" ]; then
        echo "Aviso: $base não encontrado em $PARAMS_CSV - usando K_LB=1, N=999"
        n_customers=999
        k_lb=1
        k_ub=999
    else
        IFS=',' read -r _inst n_customers k_lb k_ub _cap _dem <<< "$line"
    fi

    if [ "$SKIP" = "yes" ] && [ -s "$log_file" ] && grep -q "statistics_cols" "$log_file"; then
        echo "[skip] $base já tem log completo"
        continue
    fi

    echo
    echo "========================================"
    echo "Rodando: $base  (n=$n_customers, K∈[$k_lb,$k_ub], UB=$UB)"
    echo "Log:     $log_file"
    echo "========================================"

    inst_start=$(date +%s)

    {
        echo "instance_file=$f"
        echo "instance_name=$base"
        echo "n_customers=$n_customers"
        echo "k_lb=$k_lb"
        echo "k_ub=$k_ub"
        echo "ub=$UB"
        echo "timeout_s=$TIMEOUT_S"
        echo "start_time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo

        timeout "${TIMEOUT_S}s" "$JULIA_BIN" src/run.jl "$f" \
            -m "$k_lb" -M "$k_ub" -u "$UB"
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
        # Formato esperado:
        #   statistics: <inst> & <optimal> & <cutoff> & <dbRoot> & <tRoot> & <nodes> & <bestDb> & <bestInc> & <tMain> \\
        # Com separador " & ", $1 é "statistics: <inst>" (prefixo + nome).
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
    elif grep -q "infeasible" "$log_file"; then
        status_str="infeasible"
        best_db=""
        best_inc=""
    else
        status_str="error"
        best_db=""
        best_inc=""
    fi

    echo "${base},${n_customers},${k_lb},${k_ub},${UB},${status_str},${best_inc},${best_db},${elapsed}" >> "$SUMMARY_CSV"
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo
echo "========================================"
echo "[3/3] Concluído. Tempo total: ${total_elapsed}s"
echo "  Resumo: $SUMMARY_CSV"
echo "========================================"
