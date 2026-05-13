# =========================================================
# bootstrap.jl
# Instala e precompila as dependências do projeto.
# Roda uma vez antes do batch.
# =========================================================

using Pkg

println("========================================")
println("Bootstrapping VRPRDL_CG environment")
println("project  = ", dirname(@__FILE__))
println("julia    = ", VERSION)
println("========================================")

Pkg.activate(@__DIR__)

try
    Pkg.instantiate()
    println("[bootstrap] Pkg.instantiate() OK")
catch e
    println("[bootstrap][ERROR] Pkg.instantiate() falhou:")
    println(e)
    exit(1)
end

try
    Pkg.precompile()
    println("[bootstrap] Pkg.precompile() OK")
catch e
    println("[bootstrap][WARN] Pkg.precompile() falhou — seguindo assim mesmo.")
    println(e)
end

# sanity-check: tenta carregar os pacotes pesados uma vez
println("[bootstrap] sanity-check (using JSON3, JuMP, CPLEX) ...")
try
    @eval using JSON3
    @eval using JuMP
    @eval using CPLEX
    println("[bootstrap] pacotes carregados OK")
catch e
    println("[bootstrap][ERROR] falha carregando pacotes:")
    println(e)
    println("""
    Sugestão: verifique se o CPLEX está instalado e se a variável
    de ambiente CPLEX_STUDIO_BINARIES (Linux) ou CPLEX_STUDIO_DIR
    aponta corretamente antes de instalar CPLEX.jl.
    """)
    exit(1)
end

println("[bootstrap] tudo pronto. Pode rodar o batch.")
