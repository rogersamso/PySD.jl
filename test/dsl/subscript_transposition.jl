# SDXorg/test-models tests/subscript_transposition.
const sector_names = [:agriculture, :industry, :transport, :tourism, :comercial]
const sector = Dim{:sector}(sector_names)
const sector1 = Dim{:sector1}(sector_names)        # a second dimension over the same elements

subscript_transposition = @equations begin
    @parameters begin
        input[sector] = [1, 10, 5, 7, 9], [unit = NoUnits]
        io_matrix[sector, sector1] = [ 1  2  3  4  5;
                                      10 20 30 40 50;
                                       1  2  3  4  5;
                                       2  3  4  5  6;
                                      -1  2 -3  4 -5], [unit = NoUnits]
    end
    @variables begin
        output[sector1], [unit = NoUnits, description = "Σ over sector of input × io_matrix"]
        output2[sector1], [unit = NoUnits, description = "The same, the matrix's dimensions swapped"]
    end

    output ~ sum_over(input .* io_matrix, sector)
    output2 ~ sum_over(input .* set(io_matrix, :sector => :sector1, :sector1 => :sector), sector)
end

Model(subscript_transposition; time = 0:1:1, time_unit = u"s")
