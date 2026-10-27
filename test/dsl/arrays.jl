# Every kind of array expression the plain-array code handles, on small arrays.
const a_names = [:x, :y, :z]
const a = Dim{:a}(a_names)
const a1 = Dim{:a1}(a_names)
const b = Dim{:b}([:p, :q])
const years = Dim{:years}(2000:2002)
const sub = [:y, :z]

arrays = @equations begin
    @parameters begin
        m[a, a1] = [0.1 0.2 0.0; 0.0 0.1 0.3; 0.2 0.0 0.1], [unit = NoUnits]
        w[b] = [1.0, 2.0], [unit = NoUnits]
        v[a] = [1.0, 2.0, 3.0], [unit = NoUnits]
        by_year[years, a] = [1 2 3; 4 5 6; 7 8 9], [unit = NoUnits]
    end
    @variables begin
        s(t)[a, b], [unit = NoUnits, description = "a stock with two dimensions"]
        flow(t)[b, a], [unit = u"s^-1", description = "declared in the other order"]
        leontief[a1, a], [unit = NoUnits, description = "inv(I - m), computed once"]
        ia(t)[a, a1], [unit = NoUnits, description = "I - m, at every step"]
        inverse(t)[a1, a], [unit = NoUnits]
        product(t)[a1], [unit = NoUnits, description = "a matrix times a vector"]
        shifted(t)[a], [unit = NoUnits]
        year(t), [unit = NoUnits]
        pick(t), [unit = NoUnits, description = "a selection that changes with time"]
        part(t)[a], [unit = NoUnits]
        notx(t)[a], [unit = NoUnits]
        total(t), [unit = NoUnits]
        swapped(t)[a1, a], [unit = NoUnits]
    end

    ∂t(s) ~ flow                                   # laid out from (b, a) to (a, b)
    s(t₀) ~ 1
    flow ~ w .* v ./ 10
    leontief ~ inv(I - m)
    ia ~ I - m
    inverse ~ inv(ia)
    product ~ leontief * v
    shifted ~ previous(v, a)
    year ~ clamp(floor(Int, t) + 2000, 2000, 2002)
    pick ~ by_year[years = At(year), a = At(:z)]
    part[a = At(:x)] ~ 1
    part[a = At(sub)] ~ v[a = At(sub)] .* 2
    notx[a = Not(At(:x))] ~ 0
    notx[a = At(:x)] ~ sum_over(v, a)
    total ~ sum_over(sum_over(s, b), a)
    swapped ~ set(m, :a => :a1, :a1 => :a)
end

Model(arrays; time = 0:0.5:2, time_unit = u"s")
