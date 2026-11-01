# Switches on the time at the model's ticks (Δt = 0.5): a step, a pulse one
# Δt wide.  Their stocks are exact with any solver.
switches = @equations begin
    @variables begin
        stepped(t), [unit = NoUnits]
        pulsed(t), [unit = NoUnits]
    end

    ∂t(stepped) ~ ifelse(t ≥ 2, 1.0, 0.0)
    stepped(t₀) ~ 0
    ∂t(pulsed) ~ 2 * (1 ≤ t < 1.5)
    pulsed(t₀) ~ 0
end

Model(switches; time = 0:0.5:4, time_unit = NoUnits)
