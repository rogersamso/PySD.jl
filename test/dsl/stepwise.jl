# Equations written for Euler steps of Δt: the year a condition is met, kept
# in one step; a tank emptied in one step; a stock kept non-negative.  And a
# finite difference of a lookup of the time, which isn't one of these.
stepwise = @equations begin
    @parameters begin
        path = piecewise_linear(0 => 0.0, 4 => 8.0), [unit = NoUnits]
    end
    @variables begin
        year_met(t), [unit = NoUnits]
        tank(t), [unit = NoUnits]
        drained(t), [unit = NoUnits]
        level(t), [unit = NoUnits, nonnegative = true]
        slope(t), [unit = NoUnits]
    end

    ∂t(year_met) ~ ifelse(t == 2, t / Δt, 0.0)
    year_met(t₀) ~ 0
    drained ~ ifelse(t ≥ 1, tank / Δt, 0.0)
    ∂t(tank) ~ -drained
    tank(t₀) ~ 1
    ∂t(level) ~ -1.0
    level(t₀) ~ 1
    slope ~ (path(t + Δt) - path(t)) / Δt
end

Model(stepwise; time = 0:0.5:4, time_unit = NoUnits)
