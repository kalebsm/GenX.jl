@doc raw"""
	write_power(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)

Function for writing the different values of power generated by the different technologies in operation.
"""
function write_power(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    gen = inputs["RESOURCES"]
    zones = zone_id.(gen)

    G = inputs["G"]     # Number of resources (generators, storage, DR, and DERs)
    T = inputs["T"]     # Number of time steps (hours)

    # Power injected by each resource in each time step
    dfPower = DataFrame(Resource = inputs["RESOURCE_NAMES"],
        Zone = zones,
        AnnualSum = Array{Union{Missing, Float64}}(undef, G))
    power = value.(EP[:vP])
    if setup["ParameterScale"] == 1
        power *= ModelScalingFactor
    end
    dfPower.AnnualSum .= power * inputs["omega"]

    filepath = joinpath(path, "power.csv")
    if setup["WriteOutputs"] == "annual"
        write_annual(filepath, dfPower)
    else # setup["WriteOutputs"] == "full"
        df_Power = write_fulltimeseries(filepath, power, dfPower)
        if setup["OutputFullTimeSeries"] == 1 && setup["TimeDomainReduction"] == 1
            write_full_time_series_reconstruction(path, setup, df_Power, "power")
            @info("Writing Full Time Series for Power")
        end
    end

    return dfPower #Shouldn't this be return nothing
end
