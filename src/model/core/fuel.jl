
@doc raw"""
    fuel!(EP::Model, inputs::Dict, setup::Dict)

This function creates expression to account for total fuel consumption (e.g., coal, 
natural gas, hydrogen, etc). It also has the capability to model the piece-wise fuel 
consumption in part load (if data is available)

***** Expressions ******
Users have two options to model the fuel consumption as a function of power generation: 
(1). Use a constant heat rate, regardless of the minimum load or maximum load; and 
(2). use the "PiecewiseFuelUsage" options to model the fuel consumption via piecewise linear 
approximation. 
By using that option, users could represent higher heat rate when generators are running at 
minimum load, and lower heatrate when generators are running at maximum load.

(1). Constant heat rate. 
The fuel consumption for power generation $vFuel_{y,t}$ is determined by power generation 
($vP_{y,t}$) mutiplied by the corresponding heat rate ($Heat\_Rate_y$). 
The fuel costs for power generation and start fuel for a plant $y$ at time $t$, 
denoted by $eCFuelOut_{y,t}$ and $eFuelStart$, is determined by fuel consumption ($vFuel_{y,t}$ 
and $eStartFuel$) multiplied by the fuel costs (\$/MMBTU)
(2). Piecewise linear approximation
In the first formulations, thermal generators are expected to have the same fuel consumption 
per generating 1 MWh electricity,
regardless of minimum load or full load. However, thermal generators tend to have decreased 
efficiency when operating at part load, leading to higher fuel consumption per generating 
the same amount of electricity. 
To have more precise representation of fuel consumption at part load, 
the piecewise-linear fitting of heat input can be introduced. 

```math
\begin{aligned}
vFuel_{y,t} >= vP_{y,t} * h_{y,x} + U_{g,t}* f_{y,x}
\hspace{1cm} \forall y \in G, \forall t \in T, \forall x \in X
\end{aligned}
```
Where $h_{y,x}$ represents slope a thermal generator $y$ in segment $x$ [MMBTU/MWh],
and $f_{y,x}$ represents intercept (MMBTU) of a thermal generator $y$ in segment $x$ [MMBUT],
and $U_{y,t}$ represents the commit status of a thermal generator $y$ at time $t$.
In "Generators_data.csv", users need to specify the number of segments in a column called 
PWFU_NUM_SEGMENTS, then provide corresponding Slopei and Intercepti based on the PWFU_NUM_SEGMENTS 
(i = PWFU_NUM_SEGMENTS).

Since fuel consumption (and fuel costs) is postive,
the optimization will optimize the fuel consumption by enforcing the inequity to equal to 
the highest piecewise segment.Only one segment is active at a time for any value of vP. 
When the power output is zero, the commitment variable $U_{g,t}$ will bring the intercept 
to be zero such that the fuel consumption is zero when thermal units are offline.

In order to run piecewise fuel consumption module,
the unit commitment must be turned on, and users should provide Slope and 
Intercept for at least one segment. 
"""

function fuel!(EP::Model, inputs::Dict, setup::Dict)
    println("Fuel Module")
    dfGen = inputs["dfGen"]
    T = inputs["T"]     # Number of time steps (hours)
    Z = inputs["Z"]     # Number of zones
    G = inputs["G"]     
    FUEL = inputs["FUEL"]
    THERM_COMMIT = inputs["THERM_COMMIT"]
    # exclude the "None" from fuels
    fuels = inputs["fuels"]
    NUM_FUEL = length(fuels)

    # create variable for fuel consumption for output
    @variable(EP, vFuel[y in 1:G, t = 1:T] >= 0)
    
    ### Expressions ####
    # Fuel consumed on start-up (MMBTU or kMMBTU (scaled)) 
    # if unit commitment is modelled
    @expression(EP, eStartFuel[y in 1:G, t = 1:T],
        if y in THERM_COMMIT
            (dfGen[y,:Cap_Size] * EP[:vSTART][y, t] * 
                dfGen[y,:Start_Fuel_MMBTU_per_MW])
        else
            0
        end)

    # fuel_cost is in $/MMBTU (M$/billion BTU if scaled)
    # vFuel and eStartFuel is MMBTU (or billion BTU if scaled)
    # eCFuel_start or eCFuel_out is $ or Million$
    # Start up fuel cost
    @expression(EP, eCFuelStart[y = 1:G, t = 1:T], 
        (inputs["fuel_costs"][dfGen[y,:Fuel]][t] * EP[:eStartFuel][y, t]))
    # plant level start-up fuel cost for output
    @expression(EP, ePlantCFuelStart[y = 1:G], 
        sum(inputs["omega"][t] * EP[:eCFuelStart][y, t] for t in 1:T))
    # zonal level total fuel cost for output
    @expression(EP, eZonalCFuelStart[z = 1:Z], 
        sum(EP[:ePlantCFuelStart][y] for y in dfGen[dfGen[!, :Zone].==z, :R_ID]))

    # Fuel cost for power generation
    @expression(EP, eCFuelOut[y = 1:G, t = 1:T], 
        (inputs["fuel_costs"][dfGen[y,:Fuel]][t] * EP[:vFuel][y, t]))
    # plant level start-up fuel cost for output
    @expression(EP, ePlantCFuelOut[y = 1:G], 
        sum(inputs["omega"][t] * EP[:eCFuelOut][y, t] for t in 1:T))
    # zonal level total fuel cost for output
    @expression(EP, eZonalCFuelOut[z = 1:Z], 
        sum(EP[:ePlantCFuelOut][y] for y in dfGen[dfGen[!, :Zone].==z, :R_ID]))


    # system level total fuel cost for output
    @expression(EP, eTotalCFuelOut, sum(eZonalCFuelOut[z] for z in 1:Z))
    @expression(EP, eTotalCFuelStart, sum(eZonalCFuelStart[z] for z in 1:Z))


    add_to_expression!(EP[:eObj], EP[:eTotalCFuelOut] + EP[:eTotalCFuelStart])

    #fuel consumption (MMBTU or Billion BTU)
    @expression(EP, eFuelConsumption[f in 1:NUM_FUEL, t in 1:T],
        sum(EP[:vFuel][y, t] + EP[:eStartFuel][y,t]
            for y in resources_with_fuel(dfGen, fuels[f])))
                
    @expression(EP, eFuelConsumptionYear[f in 1:NUM_FUEL],
        sum(inputs["omega"][t] * EP[:eFuelConsumption][f, t] for t in 1:T))

    
    ### Constraint ###
    ### only apply constraint to generators with fuel type other than None
    @constraint(EP, FuelCalculation[y in setdiff(FUEL, THERM_COMMIT), t = 1:T],
        EP[:vFuel][y, t] - EP[:vP][y, t] * dfGen[y, :Heat_Rate_MMBTU_per_MWh] == 0)

    if !isempty(THERM_COMMIT)
        if setup["PiecewiseFuelUsage"] == 1
            # Only apply piecewise fuel consumption to thermal generators with PWFU_NUM_SEGMENTS > 0
            THERM_COMMIT_PWFU = inputs["THERM_COMMIT_PWFU"]
            for segment in 1:inputs["PWFU_MAX_NUM_SEGMENTS"]
                @constraint(EP, [y in THERM_COMMIT_PWFU, t = 1:T],
                EP[:vFuel][y, t] >= (EP[:vP][y, t] *  dfGen[y, inputs["slope_cols"]][segment] + 
                    EP[:vCOMMIT][y, t] * dfGen[y, inputs["intercept_cols"]][segment]))
            end
            @constraint(EP, [y in setdiff(THERM_COMMIT,THERM_COMMIT_PWFU), t = 1:T],
                EP[:vFuel][y, t] - EP[:vP][y, t] * dfGen[y, :Heat_Rate_MMBTU_per_MWh] == 0)

        else
            @constraint(EP, FuelCalculationCommit[y in THERM_COMMIT, t = 1:T],
                EP[:vFuel][y, t] - EP[:vP][y, t] * dfGen[y, :Heat_Rate_MMBTU_per_MWh] == 0)
        end
    end

    return EP
end


function resources_with_fuel(df::DataFrame, fuel::AbstractString)
    return df[df[!, :Fuel] .== fuel, :R_ID]
end

