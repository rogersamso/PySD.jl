# SDXorg/test-models tests/get_xls_cellrange: constants, lookups and data from
# named ranges (global and local to a sheet), one of them transposed.
const dim = Dim{:dim}([:a, :b, :c, :d, :e, :f])

cellrange = @equations begin
    @parameters begin
        value1[dim] = constant(global_sheet, "value1"), [unit = NoUnits, description = "Globally defined"]
        value2[dim] = constant(local_sheet, "value2"), [unit = NoUnits, description = "Locally defined"]
        valuev[dim] = constant(global_sheet, "valuev"; transpose = true),
            [unit = NoUnits, description = "Vertically defined"]
        data1 = data(global_sheet, "Time1", "value1"), [unit = NoUnits]
        data2 = data(local_sheet, "Time2", "value2"), [unit = NoUnits]
        datav = data(global_sheet, "Timev", "valuev"), [unit = NoUnits]
        lookup1 = lookup(global_sheet, "Time1", "value1"), [unit = NoUnits]
        lookup2 = lookup(local_sheet, "Time2", "value2"), [unit = NoUnits]
        lookupv = lookup(global_sheet, "Timev", "valuev"), [unit = NoUnits]
    end
    @variables begin
        final1(t)[dim], [unit = NoUnits]
        final2(t)[dim], [unit = NoUnits]
        finalv(t)[dim], [unit = NoUnits]
    end

    final1 ~ value1 .+ 10 * data1(t) .- 100 * lookup1(t)
    final2 ~ value2 .+ 10 * data2(t) .- 100 * lookup2(t)
    finalv ~ valuev .+ 10 * datav(t) .- 100 * lookupv(t)
end

Model(cellrange; time = 0:1:5, time_unit = u"month",
      inputs = (; global_sheet = excel(joinpath(INPUTS, "inputs.xlsx"), "Global"),
                  local_sheet = excel(joinpath(INPUTS, "inputs.xlsx"), "Local")))
