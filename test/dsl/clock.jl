# A fixed delay and a sample with stocks around them, on a coarse Δt: what
# other solvers do between the model's ticks.
clock_example = @equations begin
    @variables begin
        orders(t), [unit = NoUnits]
        arrivals(t), [unit = NoUnits]
        stock(t), [unit = NoUnits]
        capital(t), [unit = NoUnits]
        spending(t), [unit = NoUnits]
    end

    orders ~ ifelse(t >= 1, 1.0, 0.0)
    arrivals ~ orders(t - 2; init = 0)
    ∂t(stock) ~ arrivals - stock / 2
    stock(t₀) ~ 0
    spending ~ sample_if_true(rem(t, 2) == 0, 0.2 * capital; init = 0)
    ∂t(capital) ~ 0.25 * capital - spending
    capital(t₀) ~ 1
end

Model(clock_example; time = 0:0.5:10, time_unit = NoUnits)
