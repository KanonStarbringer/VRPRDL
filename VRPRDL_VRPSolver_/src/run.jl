if !haskey(ENV, "BAPCOD_RCSP_LIB")
    println("Defina BAPCOD_RCSP_LIB antes de executar.")
    println("Exemplo:")
    println("export BAPCOD_RCSP_LIB=/home/enderson/Downloads/bapcodframework_git/build/Bapcod/libbapcod-shared")
    exit(1)
end

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

include("VRPRDLSolverDemo.jl")
using .VRPRDLSolverDemo

if isempty(ARGS)
    main(["--help"])
else
    main(ARGS)
end