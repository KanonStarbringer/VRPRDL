#!/usr/bin/env bash
# Batch da CG do VRPRDL (JuMP+CPLEX) usando os logs do demo VRPTW
# do VRPSolverDemos como gerador externo de rotas candidatas.
#
# Diferença para rodar_vrprdl_cg_batch.sh:
#   - LOG_SRC_DIR aponta para logs_vrptw_convertidos/ em vez de
#     logs_vrp_convertidos/ (CVRP).
#   - LOG_DST_DIR usa subpasta separada (logs_cg_vrptw/) para não
#     sobrescrever os resultados do pipeline CVRP.
#
# Fluxo (idêntico ao outro batch):
#   1) bootstrap.jl   -> instala/precompila deps (1x)
#   2) run_batch.jl   -> processa TODAS as instâncias numa única
#                        sessão Julia
#
# Uso (WSL):
#   dos2unix rodar_vrprdl_cg_batch_vrptw.sh
#   chmod +x rodar_vrprdl_cg_batch_vrptw.sh
#   ./rodar_vrprdl_cg_batch_vrptw.sh [alpha_wait] [pricing_mode]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CG_DIR="$BASE_DIR/vrprdl_cg"
JSON_DIR="$BASE_DIR/VRPRDL-triangle/json_convertidos"
LOG_SRC_DIR="$BASE_DIR/VRPRDL-triangle/logs_vrptw_convertidos"
LOG_DST_DIR="$CG_DIR/logs_cg_vrptw"

JULIA_BIN="$HOME/.juliaup/bin/julia"

ALPHA_WAIT="${1:-0.0}"
PRICING_MODE="${2:-pool}"

mkdir -p "$LOG_DST_DIR"

# -----------------------------------------------------------------
# sanity checks
# -----------------------------------------------------------------
if [ ! -d "$JSON_DIR" ]; then
    echo "Erro: pasta de JSONs não encontrada: $JSON_DIR"
    exit 1
fi
if [ ! -d "$LOG_SRC_DIR" ]; then
    echo "Erro: pasta de logs VRPTW não encontrada: $LOG_SRC_DIR"
    echo "Dica: rode antes './scripts/batch/rodar_vrps_vrptw_turco.sh' na raiz do repositório."
    exit 1
fi
if [ ! -x "$JULIA_BIN" ]; then
    echo "Erro: executável do Julia não encontrado: $JULIA_BIN"
    exit 1
fi

cd "$CG_DIR" || exit 1

# -----------------------------------------------------------------
# (1) bootstrap — reuso do mesmo ambiente
# -----------------------------------------------------------------
BOOT_LOG="$LOG_DST_DIR/_bootstrap.log"
echo "========================================"
echo "Bootstrap (instala/precompila deps)"
echo "Log: $BOOT_LOG"
echo "========================================"

"$JULIA_BIN" --project=. bootstrap.jl 2>&1 | tee "$BOOT_LOG"
boot_status=${PIPESTATUS[0]}

if [ "$boot_status" -ne 0 ]; then
    echo
    echo "Bootstrap falhou (exit=$boot_status). Veja $BOOT_LOG."
    exit $boot_status
fi

# -----------------------------------------------------------------
# (2) batch CG apontando para logs VRPTW
# -----------------------------------------------------------------
BATCH_LOG="$LOG_DST_DIR/_batch.log"
echo
echo "========================================"
echo "Rodando CG (fonte = VRPTW)"
echo "CG dir        : $CG_DIR"
echo "JSON dir      : $JSON_DIR"
echo "VRPSolver log : $LOG_SRC_DIR  (VRPTW)"
echo "Logs CG       : $LOG_DST_DIR"
echo "alpha_wait    : $ALPHA_WAIT"
echo "pricing_mode  : $PRICING_MODE"
echo "Batch log     : $BATCH_LOG"
echo "========================================"

"$JULIA_BIN" --project=. run_batch.jl \
    "$JSON_DIR" "$LOG_SRC_DIR" "$LOG_DST_DIR" "$ALPHA_WAIT" "$PRICING_MODE" \
    2>&1 | tee "$BATCH_LOG"

batch_status=${PIPESTATUS[0]}

echo
if [ "$batch_status" -eq 0 ]; then
    echo "Batch VRPTW concluído com sucesso."
    echo "CSV agregado: $LOG_DST_DIR/_summary.csv"
else
    echo "Batch terminou com exit=$batch_status. Logs em $LOG_DST_DIR/."
fi

exit $batch_status
