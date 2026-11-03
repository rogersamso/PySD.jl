# SDXorg/test-models tests/vector_order, as PySD's DSL backend translates it:
# VECTOR SORT ORDER, RANK and REORDER along the last subscript, and data in
# parts, one per element of one subscript or of two (revenue3).
const product_elements = [:x, :y]
const product = Dim{:product}(product_elements)
const region_elements = [:a, :b, :c]
const region = Dim{:region}(region_elements)
const company_elements = [:company1, :company2, :company3, :company4, :company5]
const company = Dim{:company}(company_elements)
const scompany_elements = [:sort1, :sort2, :sort3, :sort4, :sort5]
const scompany = Dim{:scompany}(scompany_elements)


equations_view = @equations begin
    @parameters begin
        revenue2a[region, company] = [data(input_sheet1, "time_index", "revenue_A"; method = :raw), data(input_sheet1, "time_index", "revenue_B"; method = :raw), data(input_sheet1, "time_index", "revenue_C"; method = :raw)],
            [unit = u"dollar/yr"]
        revenue3[region, product, company] = [[data(input_sheet1, "time_index", "revenue_A"; method = :raw), data(input_sheet1, "time_index", "revenue_A"; method = :raw)], [data(input_sheet1, "time_index", "revenue_B"; method = :raw), data(input_sheet1, "time_index", "revenue_B"; method = :raw)], [data(input_sheet1, "time_index", "revenue_C"; method = :raw), data(input_sheet1, "time_index", "revenue_C"; method = :raw)]],
            [unit = u"dollar/yr"]
        revenue2b[region, company] = [data(input_sheet1, "time_index", "revenue_A"; method = :raw), data(input_sheet1, "time_index", "revenue_B"; method = :raw), data(input_sheet1, "time_index", "revenue_C"; method = :raw)],
            [unit = u"dollar/yr"]
        revenue[company] = data(input_sheet1, "time_index", "revenue"; method = :raw),
            [unit = u"dollar/yr"]
    end
    @variables begin
        median_revenue_neg3(t)[region, product], [unit = u"dollar/yr"]
        median_revenue_neg2a(t)[region], [unit = u"dollar/yr"]
        median_revenue_neg2b(t)[region], [unit = u"dollar/yr"]
        median_revenue2a(t)[region], [unit = u"dollar/yr"]
        median_revenue3(t)[region, product], [unit = u"dollar/yr"]
        median_revenue2b(t)[region], [unit = u"dollar/yr"]
        sort_order3(t)[region, product, scompany], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sort_order2b(t)[region, scompany], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        revenue_rank2a(t)[company, region], [unit = NoUnits, description = "Rank of companies by revenue."]
        revenue_rank_neg2a(t)[company, region], [unit = NoUnits, description = "Rank of companies by revenue."]
        revenue_rank_neg3(t)[region, product, scompany], [unit = NoUnits, description = "Rank of companies by revenue."]
        revenue_rank_neg2b(t)[region, scompany], [unit = NoUnits, description = "Rank of companies by revenue."]
        sorted_revenue_reordered_neg2a(t)[scompany, region], [unit = u"dollar/yr", description = "Revenue, sorted"]
        revenue_rank3(t)[region, product, scompany], [unit = NoUnits, description = "Rank of companies by revenue."]
        revenue_rank2b(t)[region, scompany], [unit = NoUnits, description = "Rank of companies by revenue."]
        sorted_revenue_reordered2b(t)[region, scompany], [unit = u"dollar/yr", description = "Revenue, sorted"]
        sort_order2a(t)[scompany, region], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sort_order_neg2a(t)[scompany, region], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sort_order_neg3(t)[region, product, scompany], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sort_order_neg2b(t)[region, scompany], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sorted_revenue_reordered2a(t)[scompany, region], [unit = u"dollar/yr", description = "Revenue, sorted"]
        sorted_revenue_reordered3(t)[region, product, scompany], [unit = u"dollar/yr", description = "Revenue, sorted"]
        sorted_revenue_reordered_neg3(t)[region, product, scompany], [unit = u"dollar/yr", description = "Revenue, sorted"]
        sorted_revenue_reordered_neg2b(t)[region, scompany], [unit = u"dollar/yr", description = "Revenue, sorted"]
        revenue_rank_neg(t)[company], [unit = NoUnits, description = "Rank of companies by revenue."]
        median_revenue_neg(t), [unit = u"dollar/yr"]
        sort_order_neg(t)[scompany], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sorted_revenue_reordered_neg(t)[scompany], [unit = u"dollar/yr", description = "Revenue, sorted"]
        median_revenue(t), [unit = u"dollar/yr"]
        sort_order(t)[scompany], [unit = NoUnits, description = "Order of elements in sorted revenue vector."]
        sorted_revenue_reordered(t)[scompany], [unit = u"dollar/yr", description = "Revenue, sorted"]
        revenue_rank(t)[company], [unit = NoUnits, description = "Rank of companies by revenue."]
    end

    median_revenue_neg3 ~ sorted_revenue_reordered_neg3[scompany = At(:sort3)]
    median_revenue_neg2a ~ sorted_revenue_reordered_neg2a[scompany = At(:sort3)]
    median_revenue_neg2b ~ sorted_revenue_reordered_neg2b[scompany = At(:sort3)]
    median_revenue2a ~ sorted_revenue_reordered2a[scompany = At(:sort3)]
    median_revenue3 ~ sorted_revenue_reordered3[scompany = At(:sort3)]
    median_revenue2b ~ sorted_revenue_reordered2b[scompany = At(:sort3)]
    sort_order3 ~ vector_sort_order(set(revenue3(t), :company => scompany), 1, scompany)
    sort_order2b ~ vector_sort_order(set(revenue2b(t), :company => scompany), 1, scompany)
    revenue_rank2a ~ vector_rank(revenue2a(t), 1, region)
    revenue_rank_neg2a ~ vector_rank(revenue2a(t), 0, region)
    revenue_rank_neg3 ~ vector_rank(set(revenue3(t), :company => scompany), 0, scompany)
    revenue_rank_neg2b ~ vector_rank(set(revenue2b(t), :company => scompany), 0, scompany)
    sorted_revenue_reordered_neg2a ~ vector_reorder(set(revenue2a(t), :company => scompany), sort_order_neg2a, region)
    revenue_rank3 ~ vector_rank(set(revenue3(t), :company => scompany), 1, scompany)
    revenue_rank2b ~ vector_rank(set(revenue2b(t), :company => scompany), 1, scompany)
    sorted_revenue_reordered2b ~ vector_reorder(set(revenue2b(t), :company => scompany), sort_order2b, scompany)
    sort_order2a ~ vector_sort_order(set(revenue2a(t), :company => scompany), 1, region)
    sort_order_neg2a ~ vector_sort_order(set(revenue2a(t), :company => scompany), 0, region)
    sort_order_neg3 ~ vector_sort_order(set(revenue3(t), :company => scompany), 0, scompany)
    sort_order_neg2b ~ vector_sort_order(set(revenue2b(t), :company => scompany), 0, scompany)
    sorted_revenue_reordered2a ~ vector_reorder(set(revenue2a(t), :company => scompany), sort_order2a, region)
    sorted_revenue_reordered3 ~ vector_reorder(set(revenue3(t), :company => scompany), sort_order3, scompany)
    sorted_revenue_reordered_neg3 ~ vector_reorder(set(revenue3(t), :company => scompany), sort_order_neg3, scompany)
    sorted_revenue_reordered_neg2b ~ vector_reorder(set(revenue2b(t), :company => scompany), sort_order_neg2b, scompany)
    revenue_rank_neg ~ vector_rank(revenue(t), 0, company)
    median_revenue_neg ~ sorted_revenue_reordered_neg[scompany = At(:sort3)]
    sort_order_neg ~ vector_sort_order(set(revenue(t), :company => scompany), 0, scompany)
    sorted_revenue_reordered_neg ~ vector_reorder(set(revenue(t), :company => scompany), sort_order_neg, scompany)
    median_revenue ~ sorted_revenue_reordered[scompany = At(:sort3)]
    sort_order ~ vector_sort_order(set(revenue(t), :company => scompany), 1, scompany)
    sorted_revenue_reordered ~ vector_reorder(set(revenue(t), :company => scompany), sort_order, scompany)
    revenue_rank ~ vector_rank(revenue(t), 1, company)
end

Model(equations_view; time = 0:1:14, saveat = 1, time_unit = u"month", numerics = :python,
      inputs = (; input_sheet1 = excel(joinpath(INPUTS, "input.xlsx"), "Sheet1")))
