# SDXorg/test-models samples/teacup (names as in the Vensim model, to compare).
teacup = @equations begin
    @parameters begin
        room_temperature = 70, [unit = u"°F", description = "Room temperature"]
        characteristic_time = 10, [unit = u"minute", description = "Characteristic time"]
    end
    @variables begin
        teacup_temperature(t), [unit = u"°F", description = "Teacup temperature"]
        heat_loss_to_room(t), [unit = u"°F/minute", description = "Heat loss to room"]
    end

    ∂t(teacup_temperature) ~ -heat_loss_to_room          # Newton's law of cooling
    teacup_temperature(t₀) ~ 180
    heat_loss_to_room ~ (teacup_temperature - room_temperature) / characteristic_time
end

Model(teacup; time = 0:0.125:30, time_unit = u"minute")
