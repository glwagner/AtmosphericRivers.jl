# # `update_radiation!` branches on a traced `Bool`, so radiation cannot be traced
#
# Breeze gates radiation on a schedule (`Breeze/src/AtmosphereModels/radiation_interface.jl`):
#
#     function update_radiation!(rtm, model)
#         isnothing(rtm) && return nothing
#         first_iteration = model.clock.iteration == 0
#         if first_iteration || rtm.schedule(model)     # <-- host-side `if`
#             _update_radiation!(rtm, model)
#         end
#         return nothing
#     end
#
# Under Reactant the clock is built from `ConcreteRNumber`s so that a compiled step can advance it,
# and inside a trace `model.clock.iteration` is a `TracedRNumber{Int64}`. Then
# `model.clock.iteration == 0` is a `TracedRNumber{Bool}`, `rtm.schedule(model)` is another, and the
# `if` cannot decide anything at trace time:
#
#     TypeError: non-boolean (TracedRNumber{Bool}) used in boolean context
#
# It is the same class of problem as the `NestedModel`/`StateExchanger` clock branches that shims 3-4
# work around, and as Breeze's acoustic-substep count (shim 5): a host-side decision that a traced
# clock cannot make.
#
# !!! note "FIXED upstream — this file is now a regression test"
#     Breeze's `update_radiation!` now wraps the branch in `@trace track_numbers=false if …`, and
#     rung A passes (the radiation body RUNS inside the trace rather than throwing). Keep this file:
#     it is the cheapest check that the fix is still in place, and it fails loudly if the branch ever
#     reverts to a host-side `if`.
#
#     Note the `||` did NOT have to become `|` — `@trace if` handles the short-circuit form itself,
#     contrary to what an earlier version of this note claimed.
#
# Nothing here needs RRTMGP, a grid, a GPU, or a real `AtmosphereModel` — only Breeze's own
# `update_radiation!`, a clock, and a schedule. Seconds to run.
#
#     julia --project -t auto minrepro_radiation.jl
#
# ## The fix
#
# The branch has to stop being a host-side `if`. Two shapes work — Breeze took the second:
#
#   1. Decide it HOST-SIDE and bake it in, as shim 5 does for the acoustic substep count: a compiled
#      run has a fixed Δt, so "does the schedule fire on step n" is a property of the executable, not
#      of the traced clock. Cheap, but it means one executable per schedule phase.
#   2. Make it a TRACED branch — `@trace track_numbers=false if first_iteration || rtm.schedule(model)`
#      — so both sides are traced and XLA selects. Correct in general, but it compiles the radiation
#      kernels into every step whether they fire or not, which for RRTMGP is the expensive half of
#      the model. THIS is what Breeze now does.

using Reactant
using CUDA                       # Reactant's KA raising path lives in its CUDA extension
using Breeze
using Oceananigans
using Oceananigans.TimeSteppers: Clock
using Oceananigans.Utils: IterationInterval

## This failure is in TRACING, not in codegen, so it needs no GPU — default to the CPU backend so the
## reproducer runs anywhere (the project's LocalPreferences point Reactant at the GPU otherwise).
Reactant.set_default_backend(get(ENV, "AR_BACKEND", "cpu"))

const UPDATE_RADIATION! = Breeze.AtmosphereModels.update_radiation!

## The smallest objects `update_radiation!` actually touches: it reads `model.clock.iteration` and
## calls `rtm.schedule(model)`. Nothing else about a `RadiativeTransferModel` or an `AtmosphereModel`
## participates in the failure.
struct StubRadiation{S}
    schedule :: S
end

struct StubModel{C}
    clock :: C
end

## Records whether the guarded body was reached, so a rung that "passes" without running radiation is
## visible rather than silently counted as success.
const RADIATION_RAN = Ref(false)
Breeze.AtmosphereModels._update_radiation!(::StubRadiation, model) = (RADIATION_RAN[] = true; nothing)

rtm = StubRadiation(IterationInterval(2))

function attempt(name, f)
    RADIATION_RAN[] = false
    try
        f()
        @info "$name: OK (radiation body $(RADIATION_RAN[] ? "ran" : "did NOT run"))"
        return true
    catch err
        msg = sprint(showerror, err)
        @warn "$name: FAILED [$(nameof(typeof(err)))]\n$(first(msg, 400))"
        return false
    end
end

# ### Rung A — a traced clock, which is what a compiled Reactant step has
#
# `ConcreteRNumber` fields are exactly how `reactant_downscale.jl` builds its clock: a compiled step
# has to advance the iteration and time, so they cannot be plain `Int`/`Float64`.
traced_clock = Clock(time      = Reactant.ConcreteRNumber(0.0),
                     iteration = Reactant.ConcreteRNumber(0),
                     last_Δt   = Reactant.ConcreteRNumber(0.0))
traced_model = StubModel(traced_clock)

a = attempt("rung A  @jit update_radiation!(rtm, model)  [traced clock]",
            () -> @jit UPDATE_RADIATION!(rtm, traced_model))

# ### Rung B — the same call with a plain clock: the logic itself is fine
#
# This is the control. It isolates the traced `Bool` as the variable — the schedule, the `||`, and
# the radiation body are all unchanged.
plain_model = StubModel(Clock(time = 0.0, iteration = 0, last_Δt = 0.0))

b = attempt("rung B  update_radiation!(rtm, model)       [plain clock, no trace]",
            () -> UPDATE_RADIATION!(rtm, plain_model))

# ### Rung C — what the traced comparison actually produces, spelled out
#
# Shows the type that reaches the `if`, so the diagnosis does not rest on reading the error text.
c = attempt("rung C  @jit on just `clock.iteration == 0`",
            () -> begin
                T = @jit((m -> m.clock.iteration == 0)(traced_model))
                @info "         `clock.iteration == 0` returns $(typeof(T)) — a value no host-side `if` can branch on"
            end)

@info "summary: rung A (traced clock) $(a ? "ok" : "FAILED — this is the radiation blocker"), " *
      "rung B (plain clock) $(b ? "ok" : "failed"), rung C (type probe) $(c ? "ok" : "failed")"
