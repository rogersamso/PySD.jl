# The synthetic 200 × 50 model of the design document's measurements:
# inflow[A, B] = growth * stock[A, B] * weight[B] / SUM(weight[B!]).
const A = Dim{:A}([Symbol("a", i) for i in 1:200])
const B = Dim{:B}([Symbol("b", i) for i in 1:50])

scaled = @equations begin
    @parameters begin
        growth = 0.001, [unit = u"s^-1"]
        weight[B] = 1:50, [unit = NoUnits]
    end
    @variables begin
        stock(t)[A, B], [unit = NoUnits]
        inflow(t)[A, B], [unit = u"s^-1"]
        total(t), [unit = NoUnits]
    end

    ∂t(stock) ~ inflow
    stock(t₀) ~ 1
    inflow ~ growth .* stock .* weight ./ sum_over(weight, B)
    total ~ sum_over(sum_over(stock, B), A)
end

Model(scaled; time = 0:0.25:100, saveat = 1, time_unit = u"s")
