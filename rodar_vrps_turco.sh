#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR/VRPRDL-triangle"
INST_DIR="$BASE_DIR/vrp_convertidos"
LOG_DIR="$BASE_DIR/logs_vrp_convertidos"

VRP_DEMOS_DIR="$HOME/VRPSolver/VRPSolverDemos"
JULIA_BIN="$HOME/.juliaup/bin/julia"

mkdir -p "$LOG_DIR"

if [ ! -d "$INST_DIR" ]; then
    echo "Erro: pasta de instâncias não encontrada:"
    echo "$INST_DIR"
    exit 1
fi

if [ ! -d "$VRP_DEMOS_DIR" ]; then
    echo "Erro: pasta VRPSolverDemos não encontrada:"
    echo "$VRP_DEMOS_DIR"
    exit 1
fi

if [ ! -x "$JULIA_BIN" ]; then
    echo "Erro: executável do Julia não encontrado:"
    echo "$JULIA_BIN"
    exit 1
fi

cd "$VRP_DEMOS_DIR" || exit 1

shopt -s nullglob
files=("$INST_DIR"/*.vrp)

if [ ${#files[@]} -eq 0 ]; then
    echo "Nenhum arquivo .vrp encontrado em:"
    echo "$INST_DIR"
    exit 1
fi

echo "========================================"
echo "Pasta de instâncias: $INST_DIR"
echo "Pasta de logs:       $LOG_DIR"
echo "VRPSolverDemos:      $VRP_DEMOS_DIR"
echo "Total de instâncias: ${#files[@]}"
echo "========================================"

for f in "${files[@]}"; do
    base=$(basename "$f" .vrp)
    log_file="$LOG_DIR/${base}.log"

    echo
    echo "========================================"
    echo "Rodando: $base"
    echo "Arquivo: $f"
    echo "Log:     $log_file"
    echo "========================================"

    {
        echo "instance_file=$f"
        echo "instance_name=$base"
        echo "start_time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo
        "$JULIA_BIN" src/run.jl "$f"
        status=$?
        echo
        echo "end_time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "exit_code=$status"
    } 2>&1 | tee "$log_file"

done

echo
echo "Todas as instâncias foram processadas."
