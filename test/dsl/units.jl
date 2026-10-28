# Equations whose units add up, and equations whose units don't (each kind once).
my_function(x) = 2x                          # a Julia function: its units can't be checked

units_example = @equations begin
    @parameters begin
        demand_ej = 100, [unit = u"EJ/yr"]
        demand_twh = 1000, [unit = u"TWh/yr"]
        ej_per_twh = 0.0036, [unit = u"EJ/TWh"]
        τ = 2, [unit = u"yr"]
        k = 3, [unit = u"yr^-1"]
    end
    @variables begin
        total(t), [unit = u"EJ/yr", description = "adds up"]
        wrong_total(t), [unit = u"EJ/yr", description = "EJ + TWh: needs a conversion factor"]
        energy(t), [unit = u"EJ", description = "a stock"]
        wrong_energy(t), [unit = u"EJ", description = "its rate isn't EJ per year"]
        growth(t), [unit = NoUnits]
        wrong_growth(t), [unit = NoUnits, description = "exp of a value in years"]
        smoothed(t), [unit = u"EJ/yr"]
        wrong_smoothed(t), [unit = u"EJ/yr", description = "a delay time in EJ/yr"]
        choice(t), [unit = u"EJ/yr"]
        wrong_choice(t), [unit = u"EJ/yr", description = "branches of different units"]
        stepped(t), [unit = u"EJ/yr", description = "a condition takes the unit that fits"]
        unknown(t), [unit = u"EJ/yr", description = "a Julia function: not checked"]
    end

    total ~ demand_ej + demand_twh * ej_per_twh
    wrong_total ~ demand_ej + demand_twh
    ∂t(energy) ~ total
    energy(t₀) ~ 0
    ∂t(wrong_energy) ~ total * τ
    wrong_energy(t₀) ~ 0
    growth ~ exp(k * t)
    wrong_growth ~ exp(t)
    smoothed ~ smooth(total, τ)
    wrong_smoothed ~ smooth(total, demand_ej)
    choice ~ ifelse(t > 2000, total, demand_ej)
    wrong_choice ~ ifelse(t > 2000, total, energy)
    stepped ~ 5 * (t ≥ 2000) * demand_ej / 100
    unknown ~ my_function(total)
end


Model(units_example; time = 1995:1:2000, time_unit = u"yr")
