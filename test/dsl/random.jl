# RANDOM functions, drawn once per tick (Δt = 0.5): bounds that are a
# parameter, a draw per element (dims), the truncated normal and exponential,
# and a stock fed by a draw.
const region = Dim{:region}([:north, :south])

randoms = @equations begin
    @parameters begin
        low = 2.0, [unit = NoUnits]
    end
    @variables begin
        u(t), [unit = NoUnits]
        noise(t)[region], [unit = NoUnits]
        z(t), [unit = NoUnits]
        waits(t), [unit = NoUnits]
        fraction(t), [unit = NoUnits]
        stock(t), [unit = NoUnits]
    end

    u ~ random_uniform(low, 3; seed = 7)
    noise ~ random_uniform(0, 1; seed = 7, dims = region)
    z ~ random_normal(-1, 1, 0, 1; seed = 3)
    waits ~ random_exponential(0, 5, 1, 2; seed = 4)
    fraction ~ random_0_1()
    ∂t(stock) ~ u
    stock(t₀) ~ 0
end

Model(randoms; time = 0:0.5:10, time_unit = NoUnits)
