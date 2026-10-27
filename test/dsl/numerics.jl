# Python's digits or Julia's: the same equations, built with numerics = :python
# or :julia (exp, log, sin, ^, sums over dimensions, inverses).
const k = Dim{:k}(1:3)
const j = Dim{:j}(1:200)

numerics_example = @equations begin
    @parameters begin
        x[j] = collect(range(0.1, 3.0; length = 200)), [unit = NoUnits]
        m[k, j] = [sin(a * b) for a in 1:3, b in 1:200], [unit = NoUnits]
        a3[k, k] = [2.0 0.3 0.1; 0.2 3.0 0.4; 0.1 0.5 4.0], [unit = NoUnits]
    end
    @variables begin
        e(t)[j], [unit = NoUnits]
        l(t)[j], [unit = NoUnits]
        p(t)[j], [unit = NoUnits]
        s(t)[j], [unit = NoUnits]
        sum_last(t)[k], [unit = NoUnits, description = "over the last dimension: pairwise"]
        sum_first(t)[j], [unit = NoUnits, description = "over the first dimension: one after the other"]
        total(t), [unit = NoUnits]
        inverse_once[k, k], [unit = NoUnits]
    end

    e ~ exp.(x .+ t)
    l ~ log.(x .+ t)
    p ~ (x .+ t) .^ 1.7
    s ~ sin.(x .* 3 .+ t)
    sum_last ~ sum_over(m .* (1 + t), j)
    sum_first ~ sum_over(m .* (1 + t), k)
    total ~ sum_over(x .* (1 + t), j)
    inverse_once ~ inv(a3)
end
