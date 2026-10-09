# # `enzymexla.math.fmuladd` cannot be lowered in Reactant's EAGER kernel path
#
# Oceananigans' advection reconstruction stencils are written with `@muladd`, so every centered /
# upwind-biased / WENO interpolation contains `Base.muladd`. CUDACore's
#
#     @device_override Base.muladd(x::Float32, y::Float32, z::Float32) =
#         ccall("llvm.fmuladd.f32", llvmcall, Cfloat, (Cfloat, Cfloat, Cfloat), x, y, z)
#
# turns that into an `llvm.fmuladd.f32` intrinsic, which becomes `enzymexla.math.fmuladd` in MLIR —
# and the eager pipeline has no lowering for it:
#
#     CompilationError: MLIR pass pipeline "all" failed
#     error: Failed to lower enzymexla math operation
#       note: see current operation: %498 = "enzymexla.math.fmuladd"(%479, %25, %497) : (f32, f32, f32) -> f32
#
# NOTE the same arithmetic lowers FINE inside an explicit `@compile` — `first_time_step!` compiles
# with these very stencils (2512 s in run 4683). So this is specific to the eager launch path, which
# is what `balance_adiabatically!` needs: it calls `time_step!(model, ±Δt)` four times per cycle
# outside any trace, and each of those computes momentum-advection tendencies.
#
# This script strips that to its smallest form: one KA kernel containing a single `muladd`, launched
# eagerly on the Reactant backend. No Breeze, no nest, no advection scheme.
#
# Run (needs a GPU — the device override is CUDACore's):
#     julia --project -t auto minrepro_fmuladd.jl            # reproduces
#     AR_FIX=1 julia --project -t auto minrepro_fmuladd.jl   # with the override neutralized
#
# `AR_FIX=1` redefines the device override as the plain `x * y + z`. That gives up the fused rounding
# (one rounding step becomes two), which is a numerics change, not a semantics one — `muladd` is
# documented as computing `x * y + z` with the fusion left to the implementation.

using Reactant
## Required even though the kernel never calls CUDA.jl directly: Reactant's KA raising path lives in
## its CUDA extension ("Attempted to raise a KernelAbstractions kernel with Reactant but CUDA.jl is
## not loaded ... needed regardless of the target backend").
using CUDA
using Oceananigans
using Oceananigans.Architectures: ReactantState, device

const KA = Oceananigans.Utils.KernelAbstractions

apply_fix = get(ENV, "AR_FIX", "0") == "1"

## `CUDACore` and `GPUCompiler` are transitive dependencies (of CUDA.jl), not direct ones, so
## `import CUDACore` fails with "Package CUDACore not found in current path". Reach them through the
## loaded-module table instead — they are certainly loaded by the time `using CUDA` has run.
loaded_module(name) = first(m for (pkg, m) in Base.loaded_modules if pkg.name == name)

if apply_fix
    ## `@device_override` is CUDACore's own macro (src/device/utils.jl), so evaluating INSIDE that
    ## module resolves it without qualification. Same signature as the original ⇒ the overlay-table
    ## entry is replaced rather than added alongside.
    CUDACore = loaded_module("CUDACore")
    @eval CUDACore @device_override Base.muladd(x::Float32, y::Float32, z::Float32) = x * y + z
    @info "AR_FIX=1: CUDACore's Float32 muladd device override replaced with x * y + z"
end

KA.@kernel function fma_kernel!(a, @Const(b))
    i = KA.@index(Global)
    @inbounds a[i] = muladd(b[i], b[i], b[i])
end

N = 64
a = Reactant.ConcreteRArray(zeros(Float32, N))
b = Reactant.ConcreteRArray(fill(2.0f0, N))

dev = device(ReactantState())
@info "launching one eager KA kernel containing a single Float32 muladd on $(typeof(dev))"

try
    fma_kernel!(dev, 16)(a, b; ndrange = N)
    got = Array(a)
    ## muladd(2, 2, 2) = 6 either way; the question is only whether it LOWERS.
    ok = all(x -> x == 6.0f0, got)
    @info "OK — kernel compiled and ran; a[1] = $(got[1]) ($(ok ? "all 6.0 as expected" : "UNEXPECTED VALUES"))"
catch err
    msg = sprint(showerror, err)
    @warn "FAILED\n$(first(msg, 700))"
end
