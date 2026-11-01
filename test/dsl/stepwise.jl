# Equations written for Euler steps of Δt: the year a condition is met, kept
# in one step; a tank emptied in one step; a stock kept non-negative.
stepwise = @equations begin
    @variables begin
        year_met(t), [unit = NoUnits]
        tank(t), [unit = NoUnits]
        drained(t), [unit = NoUnits]
        level(t), [unit = NoUnits, nonnegative = true]
    end

    ∂t(year_met) ~ ifelse(t == 2, t / Δt, 0.0)
    year_met(t₀) ~ 0
    drained ~ ifelse(t ≥ 1, tank / Δt, 0.0)
    ∂t(tank) ~ -drained
    tank(t₀) ~ 1
    ∂t(level) ~ -1.0
    level(t₀) ~ 1
end

Model(stepwise; time = 0:0.5:4, time_unit = NoUnits)
