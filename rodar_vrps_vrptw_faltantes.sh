#!/usr/bin/env bash
# Roda o demo VRPTW do VRPSolverDemos apenas para um SUBCONJUNTO de
# instâncias (as que faltam após uma interrupção, etc.).
#
# Lista de IDs abaixo (INSTANCE_IDS) é editável. O script monta os nomes
# de arquivo no padrão "instance_<id>-triangle.txt".
#
# Pré-requisitos:
#   - as instâncias .txt já devem existir em VRPRDL-triangle/vrptw_convertidos/
#     (use o script completo rodar_vrps_vrptw_turco.sh ao menos uma vez,
#      ou rode 'julia converter_jsons_para_vrptw.jl' manualmente).
#
# Uso:
#   dos2unix rodar_vrps_vrptw_faltantes.sh
#   chmod +x rodar_vrps_vrptw_faltantes.sh
#   ./rodar_vrps_vrptw_faltantes.sh

set -u

# =========================================================
# Lista de instâncias a rodar (edite aqui se precisar)
# =========================================================
INSTANCE_IDS=(4 5 6 7 8 9 32 33 34 35 36 37 38 39)

# =========================================================
# Paths (iguais ao script completo)
# =========================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TURCO_DIR="$SCRIPT_DIR"
BASE_DIR="$TURCO_DIR/VRPRDL-triangle"
INST_DIR="$BASE_DIR/vrptw_convertidos"
LOG_DIR="$BASE_DIR/logs_vrptw_convertidos"

VRP_VRPTW_DIR="$HOME/VRPSolver/VRPSolverDemos/other/VRPTW"
VRP_CFG="$VRP_VRPTW_DIR/config/VRPTW_set_2.cfg"
JULIA_BIN="$HOME/.juliaup/bin/julia"

mkdir -p "$LOG_DIR"

# =========================================================
# sanity checks
# =========================================================
if [ ! -d "$INST_DIR" ]; then
    echo "Erro: pasta de instâncias VRPTW não encontrada: $INST_DIR"
    echo "Dica: rode 'julia converter_jsons_para_vrptw.jl' ou rodar_vrps_vrptw_turco.sh antes."
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

# =========================================================
# Monta a lista de arquivos existentes
# =========================================================
files=()
missing=()
for id in "${INSTANCE_IDS[@]}"; do
    inst_file="$INST_DIR/instance_${id}-triangle.txt"
    if [ -f "$inst_file" ]; then
        files+=("$inst_file")
    else
        missing+=("instance_${id}-triangle.txt")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Aviso: instâncias não encontradas e serão puladas:"
    for m in "${missing[@]}"; do
        echo "  - $m"
    done
fi

if [ ${#files[@]} -eq 0 ]; then
    echo "Nenhum arquivo válido para processar. Saindo."
    exit 1
fi

echo "========================================"
echo "Pasta de instâncias VRPTW : $INST_DIR"
echo "Pasta de logs             : $LOG_DIR"
echo "VRPSolverDemos/VRPTW      : $VRP_VRPTW_DIR"
echo "Config                    : $VRP_CFG"
echo "IDs solicitados           : ${INSTANCE_IDS[*]}"
echo "Instâncias a rodar        : ${#files[@]}"
echo "========================================"

# =========================================================
# Loop principal
# =========================================================
t_start=$SECONDS
count=0
for f in "${files[@]}"; do
    count=$((count + 1))
    base=$(basename "$f" .txt)
    log_file="$LOG_DIR/${base}.log"

    echo
    echo "========================================"
    echo "[$count/${#files[@]}] Rodando: $base"
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

t_elapsed=$((SECONDS - t_start))
echo
echo "========================================"
echo "Processamento concluído."
echo "Instâncias rodadas : ${#files[@]}"
echo "Puladas (missing)  : ${#missing[@]}"
echo "Tempo total        : ${t_elapsed}s"
echo "Logs em            : $LOG_DIR"
echo "========================================"
