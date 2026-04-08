# direct = charging directly when being connected to the grid after a trip, 
# optimal = optimised the charging while prioritising trips
# V2G = same as optimal but includes also discharging to the grid
# one can select multiple of the options direct/optimal/V2G and let a share of the fleet use one of the strategies

function ev_agg_model(modelinfo, ev_params)
    (; m, sets, vars, configs) = modelinfo
    (; NODES, PERIODS) = sets
    (; share_V2G, ev_direct, ev_optimal, ev_V2G) = configs
    (; charging_limit_coef, grid_power_max, battery_storage_max, ev_efficiency, hourly_ev_demand) = ev_params

    @variables m begin
        EVChargingSlow[node in NODES, time in PERIODS] >= 0   # charging of the vehicle battery [MWh per hour]
        EVDischargeNet[node in NODES, time in PERIODS] >= 0   # Discharging of the vehicle battery back to the electricity grid [MWh per hour]
        EVStorage[node in NODES, time in PERIODS] >= 0         # Storage level of the vehicle battery [MWh per hour]
    end

    # EV Variables Limits
    for node in NODES, time in PERIODS
        if charging_limit_coef > 0.0
            set_upper_bound(EVChargingSlow[node,time], grid_power_max[node,time] * charging_limit_coef)
        end
        set_upper_bound(EVDischargeNet[node,time], grid_power_max[node,time] * share_V2G)    # limits the amount of charging per hour for V2G
        set_upper_bound(EVStorage[node,time], battery_storage_max[node])    # maximum storage capacity of the batteries, if ev_direct == :yes ???????
    end

    if ev_V2G == :no
        set_upper_bound.(EVDischargeNet, 0.0)
    end

    if ev_direct == :yes && ev_optimal == :no && ev_V2G == :no
        # Batch fix all charging and storage variables
        fix.(EVChargingSlow, 0.0; force=true)
        fix.(EVStorage, 0.0; force=true)
    end

    # EV Storage Constraints
    # EV storage level empty for start and end period - batch operation
    first_period = first(PERIODS)
    last_period = last(PERIODS)
    
    # fix start and end periods on all nodes
    fix.(EVStorage[:, first_period], 0.0; force=true)
    fix.(EVStorage[:, last_period], 0.0; force=true)

    # EV storage balance
    @constraint(m, ev_storage_level[time in PERIODS[1:end-1], node in NODES],
        EVStorage[node, time+1] <= EVStorage[node, time] + EVChargingSlow[node, time] * ev_efficiency + # + EVChargingFast[node, time]
                                    - EVDischargeNet[node, time] - hourly_ev_demand[node, time]
    )
    
    vars = (; vars..., EVChargingSlow, EVDischargeNet, EVStorage)
    return vars
end

function add_EV_demand_and_supply_terms!(demand_terms, supply_terms, node, time, modelinfo, ev_params)
    (; vars, configs) = modelinfo
    (; EVChargingSlow, EVDischargeNet) = vars
    (; use_EV, ev_ERS) = configs
    (; hourly_direct_ev_demand, fast_charging_demand) = ev_params

    # Add EV terms based on configuration
    if use_EV == :yes
        push!(demand_terms, EVChargingSlow[node, time])      # EV charging
        push!(demand_terms, hourly_direct_ev_demand[node, time]) # EV demand for Direct strategy
        push!(supply_terms, EVDischargeNet[node, time])       # EV discharge
    end
    
    if ev_ERS == :yes
        push!(demand_terms, fast_charging_demand[node])         # EV demand for ERS
    end
end
