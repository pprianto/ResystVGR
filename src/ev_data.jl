function inputdata_EV(modelinfo)
    (; m, sets, inputs, configs) = modelinfo
    (; NODES, PERIODS) = sets
    (; ev_data) = inputs
    (; share_ev_all, ev_charging_profile, nr_vehicles, ev_demand_profile) = ev_data
    (; bat_cap, share_optimal, share_V2G, target_year, charging_infra, ev_CP,
        ev_direct, ev_optimal, ev_V2G) = configs

    # ---------------------- EV PARAMETERS FOR CARS -------------------------------------

    ev_infrastructure = Dict(
        15 => (bat_cap = 15, home = 0.71, h6 = 0.74, h3 = 0.81, h1 = 0.87, ers = 1.0),
        30 => (bat_cap = 30, home = 0.83, h6 = 0.91, h3 = 0.92, h1 = 0.95, ers = 1.0),
        60 => (bat_cap = 60, home = 0.92, h6 = 0.96, h3 = 0.96, h1 = 0.97, ers = 1.0),
        85 => (bat_cap = 85, home = 0.94, h6 = 0.97, h3 = 0.99, h1 = 0.99, ers = 1.0)
    )
    
    if bat_cap in keys(ev_infrastructure)
        ev_infra_data = ev_infrastructure[bat_cap]
    else
        error("Unsupported battery capacity: $bat_cap not in [15,30,60,85].")
    end
    
    ev_bat_cap = ev_infra_data.bat_cap / 1e3    # Fleet Battery Capacity [MWh]
    CP_slow = ev_CP / 1e3                       # Charging Power [MW]

    # Charging Infrastructure and
    # "Xh" = connected at all stops longer than X hours, grid connection "home" = only at the home location
    # depending on the model options
    # Share of the kilometer for the vehicle fleet that can be driven on electricity
    # depending mainly on charging infrastructure and battery size
    share_el = getfield(ev_infra_data, charging_infra)

    # EV efficiency
    # charging or discharging efficiency to the grid (i.e. battery efficiency one-way)
    ev_efficiency = 0.95

    FC_el = 0.16                    # electricity kWh/km      
    Distance_yr = 13000             # km/year

    El_fuel = FC_el * Distance_yr / 1e3      # driving demand [MWh/year per vehicle]

    # Share of EV cars in the fleet
    # according to high or low EV number scenario
    if configs.ev_number == :high
        Share_ev_cars = share_ev_all[target_year, :cars_high]
    else
        Share_ev_cars = share_ev_all[target_year, :cars_low]
    end

    # parameter that defines how large share of the fleet that is connected to the grid at every timestep
    fleet_availability = ev_data.fleet_availability[:, charging_infra]
    
    # some parameters used to build constraints, previously implemented as expressions
    # all are vectors [NODES]
    Number_vehicles = vec(nr_vehicles[:CARS, :])
    Number_EV = round.(Number_vehicles * Share_ev_cars, digits=3)     # number of EV cars in each node
    Demand_EV = round.(El_fuel * share_el * Number_EV, digits=3)      # yearly demand of EV cars in each node [MWh]

    # charging limit multiplier
    charging_limit_coef =
        if ev_optimal == :yes && ev_V2G == :yes
            share_optimal + share_V2G   # Both optimal and V2G enabled
        elseif ev_optimal == :yes && ev_V2G == :no
            share_optimal               # Only optimal enabled
        elseif ev_optimal == :no && ev_V2G == :yes
            share_V2G                   # Only V2G enabled
        else
            0.0                         # only ev_direct enabled, no ev_optimal or V2G
        end

    # demand coefficients based on configuration
    hourly_demand_coef = (ev_direct == :no) ? 1.0 : charging_limit_coef

    # direct charging coefficients
    direct_demand_coef = 1 - hourly_demand_coef

    # Charging profiles for Direct EV. The profiles depends on the available charging infrastructure.
    # profiles sum to 1
    demand_profile = ev_demand_profile[:, :profile] |> Vector
    profile_lookup = Symbol("$(configs.charging_infra)_$(Int(bat_cap))kWh")
    direct_charging_profile = ev_charging_profile[:, profile_lookup]

    # parameters for hourly demand in each node, matrix size [hours x NODES]
    hourly_ev_demand = AxisArray(round.(Vector(Demand_EV) .* demand_profile[PERIODS]' * hourly_demand_coef, digits=3), NODES, PERIODS)
    hourly_direct_ev_demand = AxisArray(round.(Vector(Demand_EV) .* Vector(direct_charging_profile[PERIODS])' * direct_demand_coef, digits=3), NODES, PERIODS)

    storage_capacity_coef =
        if ev_direct != :yes
            0.0
        elseif ev_optimal == :no && ev_V2G == :no
            1.0
        elseif ev_optimal == :yes && ev_V2G == :no
            share_optimal
        else  
            share_V2G    # V2G enabled (covers both Optimal+V2G and V2G-only cases)
        end

    battery_storage_max = round.(Number_EV * ev_bat_cap * storage_capacity_coef, digits=3)  # maximum storage capacity in EV batteries [MWh] (PCB = passenger car battery)
    grid_power_max = AxisArray(Vector(Number_EV) .* Vector(fleet_availability[PERIODS])' * CP_slow, NODES, PERIODS)

    # parameters for running scenarios with ERS, 
    # the ERS will for passenger cars covers the distance not covered by the battery, i.e. 1-shareel
    fast_charging_demand = round.(Number_EV .* Demand_EV * El_fuel * (1-share_el), digits=3)  # ERS fast charging demand in each node [MWh]

    ev_params = (; grid_power_max, share_V2G, charging_limit_coef, battery_storage_max, ev_efficiency, hourly_ev_demand,
                hourly_direct_ev_demand, fast_charging_demand)
    return ev_params
end
