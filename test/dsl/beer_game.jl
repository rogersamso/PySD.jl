# The beer game: a supply chain built from components, connected by equations,
# with the ordering rule chosen by dispatch.  No reference output.

import Unitful
module BeerUnits                                    # a unit this model declares itself
using Unitful
@unit case "case" Case 1 false
end
Unitful.register(BeerUnits)

abstract type OrderingRule end

"Sterman's anchoring and adjustment"
Base.@kwdef struct Anchoring <: OrderingRule
    α::Float64 = 0.25                              # fraction of the gap ordered per week
end

"Order exactly what is missing"
struct OrderUpTo <: OrderingRule end

order(r::Anchoring, expected, gap) = max(0, expected + r.α * gap)
order(::OrderUpTo, expected, gap) = max(0, expected + gap)

"""
    stage(; name, rule = Anchoring(), target = 12)

One stage of a supply chain: keeps an inventory, ships what it can and orders
from upstream following an ordering `rule`.
"""
function stage(; name, rule = Anchoring(), target = 12)
    @equations name begin
        @parameters begin
            target_inventory = target, [unit = u"case"]
            one_week = 1, [unit = u"wk"]
        end
        @variables begin
            incoming_orders(t) = 4, [unit = u"case/wk", input = true]
            deliveries(t) = 4, [unit = u"case/wk", input = true]
            shipments(t), [unit = u"case/wk", output = true]
            orders_placed(t), [unit = u"case/wk", output = true]
            inventory(t), [unit = u"case", nonnegative = true]
            backlog(t), [unit = u"case"]
            expected_orders(t), [unit = u"case/wk"]
        end

        ∂t(inventory) ~ deliveries - shipments
        inventory(t₀) ~ target_inventory
        ∂t(backlog) ~ incoming_orders - shipments
        backlog(t₀) ~ 0

        shipments ~ min(backlog / one_week + incoming_orders, inventory / one_week)
        expected_orders ~ smooth(incoming_orders, 2)
        orders_placed ~ order(rule, expected_orders, (target_inventory - inventory + backlog) / one_week)
    end
end

function beer_game(; rule = Anchoring())
    retailer = stage(; name = :retailer, rule)
    wholesaler = stage(; name = :wholesaler, rule)
    factory = stage(; name = :factory, rule, target = 20)

    connections = @equations begin
        @variables begin
            customer_orders(t), [unit = u"case/wk"]
        end
        customer_orders ~ 4 + 4 * (t ≥ 4)

        retailer.incoming_orders ~ customer_orders
        retailer.deliveries ~ wholesaler.shipments
        wholesaler.incoming_orders ~ retailer.orders_placed
        wholesaler.deliveries ~ factory.shipments
        factory.incoming_orders ~ wholesaler.orders_placed
        factory.deliveries ~ delay(factory.orders_placed, 2)
    end

    return Model(retailer, wholesaler, factory, connections; time = 0:1:52, time_unit = u"wk")
end
