# SDXorg/test-models tests/get_lookups_subscripted_args: lookups with and
# without dimensions, called with numbers and with arrays (dimensions line up
# by name), read from rows of an .xls sheet.
const dim = Dim{:dim}([:a, :b])
const rows = Dim{:rows}([:row1, :row2])

subscripted_lookups = @equations begin
    @parameters begin
        lookup_1d = lookup(sheet, "4", "C5"), [unit = NoUnits]
        lookup_2d[rows] = lookup(sheet, "4", "C5"), [unit = NoUnits]
        lookup_3d[dim, rows] = [lookup(sheet, "4", "C5"), lookup(sheet, "4", "C7")], [unit = NoUnits]
    end
    @variables begin
        arg_d(t)[dim], [unit = NoUnits]
        arg_r(t)[rows], [unit = NoUnits]
        arg_rd(t)[dim, rows], [unit = NoUnits]
        r01d(t), [unit = NoUnits]
        r1d(t)[rows], [unit = NoUnits]
        r2d(t)[rows], [unit = NoUnits]
        r3d(t)[dim, rows], [unit = NoUnits]
        d1d(t)[dim], [unit = NoUnits]
        d2d(t)[rows, dim], [unit = NoUnits]
        d3d(t)[dim, rows], [unit = NoUnits]
        rd1d(t)[dim, rows], [unit = NoUnits]
        rd2d(t)[dim, rows], [unit = NoUnits]
        rd3d(t)[dim, rows], [unit = NoUnits]
        lookup_1d_time(t), [unit = NoUnits]
        lookup_2d_time(t)[rows], [unit = NoUnits]
        lookup_3d_time(t)[dim, rows], [unit = NoUnits]
    end

    arg_d[dim = At(:a)] ~ 2 * t
    arg_d[dim = At(:b)] ~ 2 + 2 * cos(t)
    arg_r[rows = At(:row1)] ~ t
    arg_r[rows = At(:row2)] ~ 1 + sin(t)
    arg_rd[dim = At(:a), rows = At(:row1)] ~ 30 - t
    arg_rd[dim = At(:a), rows = At(:row2)] ~ t - t * sin(t)
    arg_rd[dim = At(:b), rows = At(:row1)] ~ 3 * t / 2
    arg_rd[dim = At(:b), rows = At(:row2)] ~ 5 + 2 * sin(t) + 2 * cos(t) + t

    r01d ~ lookup_1d(arg_r[rows = At(:row1)])
    r1d ~ lookup_1d.(arg_r)
    r2d ~ lookup_2d(arg_r)
    r3d ~ lookup_3d(arg_r)
    d1d ~ lookup_1d.(arg_d)
    d2d ~ lookup_2d(arg_d)
    d3d ~ lookup_3d(arg_d)
    rd1d ~ lookup_1d.(arg_rd)
    rd2d ~ lookup_2d(arg_rd)
    rd3d ~ lookup_3d(arg_rd)
    lookup_1d_time ~ lookup_1d(t)
    lookup_2d_time ~ lookup_2d(t)
    lookup_3d_time ~ lookup_3d(t)
end

Model(subscripted_lookups; time = 0:0.5:30, time_unit = u"minute",
      inputs = (; sheet = excel(joinpath(INPUTS, "input.xls"), "Sheet1")))
