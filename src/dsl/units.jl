# Units models often need that Unitful.jl doesn't have.  Declaring them with
# prefixes gives the prefixed ones too (TWh, Mt, Mpeople, Tdollar).
module PySDUnits
using Unitful
using Unitful: @dimension, @refunit, @unit, J, kg, yr

@unit Wh "Wh" WattHour 3600J true                  # → kWh, MWh, TWh
@unit t "t" Tonne 1000kg true                      # → kt, Mt, Gt
@unit month "month" Month yr / 12 false

@dimension 𝐏𝐞𝐨𝐩𝐥𝐞 "People" People               # not physical: dimensions of their own
@refunit people "people" Person 𝐏𝐞𝐨𝐩𝐥𝐞 true      # → Mpeople
@dimension 𝐌𝐨𝐧𝐞𝐲 "Money" Money
@refunit dollar "dollar" Dollar 𝐌𝐨𝐧𝐞𝐲 true       # → Mdollar, Tdollar

const localfactors = copy(Unitful.basefactors)
function __init__()
    merge!(Unitful.basefactors, localfactors)
    Unitful.register(PySDUnits)
end
end
