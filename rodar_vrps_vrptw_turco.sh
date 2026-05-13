#!/usr/bin/env bash
# Roda o demo VRPTW do VRPSolverDemos (~/VRPSolver/VRPSolverDemos/other/VRPTW/)
# sobre as instâncias VRPTW projetadas em VRPRDL-triangle/vrptw_convertidos/.
# Logs em VRPRDL-triangle/logs_vrptw_convertidos/.
#
# Pré-requisitos:
#   - rodar antes: julia converter_jsons_para_vrptw.jl
#   - VRPSolverDemos com o demo VRPTW instalado em $VRP_VRPTW_DIR
#
# Uso:
#   dos2unix rodar_vrps_vrptw_turco.sh
#   chmod +x rodar_vrps_vrptw_turco.sh
#   ./rodar_vrps_vrptw_turco.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TURCO_DIR="$SCRIPT_DIR"
BASE_DIR="$TURCO_DIR/VRPRDL-triangle"
INST_DIR="$BASE_DIR/vrptw_convertidos"
LOG_DIR="$BASE_DIR/logs_vrptw_convertidos"
CONVERTER="$TURCO_DIR/converter_jsons_para_vrptw.jl"

VRP_VRPTW_DIR="$HOME/VRPSolver/VRPSolverDemos/other/VRPTW"
VRP_CFG="$VRP_VRPTW_DIR/config/VRPTW_set_2.cfg"
JULIA_BIN="$HOME/.juliaup/bin/julia"

mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------
# (Re)gera as instâncias .txt a partir dos JSONs para garantir
# que o modo :enclose (viabilidade round-trip) esteja aplicado.
# -----------------------------------------------------------------
echo "========================================"
echo "Regenerando instâncias VRPTW (modo :enclose)"
echo "========================================"
pushd "$TURCO_DIR" >/dev/null || exit 1
"$JULIA_BIN" "$CONVERTER"
conv_status=$?
popd >/dev/null
if [ $conv_status -ne 0 ]; then
    echo "Erro: converter_jsons_para_vrptw.jl falhou (exit=$conv_status)."
    exit 1
fi

# -----------------------------------------------------------------
# sanity checks
# -----------------------------------------------------------------
if [ ! -d "$INST_DIR" ]; then
    echo "Erro: pasta de instâncias VRPTW não encontrada: $INST_DIR"
    echo "Dica: rode antes 'julia converter_jsons_para_vrptw.jl'"
    exit 1
fi
if [ ! -d "$VRP_VRPTW_DIR" ]; then
    echo "Erro: pasta do demo VRPTW não encontrada: $VRP_VRPTW_DIR"
    exit 1
fi
if [ ! -f "$VRP_CFG" ]; then
    echo "Erro: arquivo de config não encontrado: $VRP_CFG"
    exit 1
fi
if [ ! -x "$JULIA_BIN" ]; then
    echo "Erro: executável do Julia não encontrado: $JULIA_BIN"
    exit 1
fi

cd "$VRP_VRPTW_DIR" || exit 1

shopt -s nullglob
files=("$INST_DIR"/*.txt)

if [ ${#files[@]} -eq 0 ]; then
    echo "Nenhum arquivo .txt encontrado em: $INST_DIR"
    exit 1
fi

echo "========================================"
echo "Pasta de instâncias VRPTW : $INST_DIR"
echo "Pasta de logs             : $LOG_DIR"
echo "VRPSolverDemos/VRPTW      : $VRP_VRPTW_DIR"
echo "Config                    : $VRP_CFG"
echo "Total de instâncias       : ${#files[@]}"
echo "========================================"

for f in "${files[@]}"; do
    base=$(basename "$f" .txt)
    log_file="$LOG_DIR/${base}.log"

    echo
    echo "========================================"
    echo "Rodando: $base"
    echo "Arquivo: $f"
    echo "Log    : $log_file"
    echo "========================================"

    {
        echo "instance_file=$f"
        echo "instance_name=$base"
        echo "start_time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo

        "$JULIA_BIN" src/run.jl "$f" --cfg "$VRP_CFG"
        status=$?

        echo
        echo "end_time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "exit_code=$status"
    } 2>&1 | tee "$log_file"

done

echo
echo "Todas as instâncias VRPTW foram processadas."
