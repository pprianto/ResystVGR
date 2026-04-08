function convert_costs(modelinfo)
    (; m, vars, constraints, configs) = modelinfo
    (; TotalCost) = vars
    (; CostCAPEX, CostFixOM, CostFuel, CostVarOM, CostExportImport,
        CostTaxes, CostCO2, SystemEmissions) = constraints

    costs = DataFrame(
        :system => value(TotalCost),
        :capex => value(CostCAPEX),
        :fixom => value(CostFixOM),
        :fuel => value(CostFuel),
        :varom => value(CostVarOM),
        :export_import => value(CostExportImport),
        :taxes => value(CostTaxes),
        :co2 => value(CostCO2),
        :system_emissions => value(SystemEmissions),
    )

    return costs
end


function convert_invs(modelinfo)
    (; m, sets, vars) = modelinfo
    (; NODES, GEN_TECHS, STO_TECHS, PERIODS) = sets
    (; GenerationInvestment, CompensationInvestment, StorageInvestment, EVStorage) = vars
    existing_generation = m[:existing_generation]

    # Investment solutions
    # Long dataframe format
    generation_capacity = DataFrame(
                                    node_id=Symbol[], 
                                    tech=Symbol[], 
                                    total_capacity=Float64[],   # total capacity variable results
                                    investment=Float64[],       # investment variable results
                                    exs_capacity=Float64[],     # existing capacity variable results
    )

    storage_capacity = DataFrame(
                                node_id=Symbol[], 
                                tech=Symbol[], 
                                total_capacity=Float64[]    # total capacity variable results
    )

    for node in NODES, gentech in GEN_TECHS
        push!(generation_capacity, (
                                    node, 
                                    gentech, 
                                    value((existing_generation[node, gentech] + GenerationInvestment[node, gentech])),
                                    value(GenerationInvestment[node, gentech]),
                                    value(existing_generation[node, gentech]),
        ))
    end

    for node in NODES
        push!(generation_capacity, (
                                    node, 
                                    :QCOMP,
                                    value(CompensationInvestment[node]),  # Compensation in total_capacity
                                    0.0,  # No investment
                                    0.0   # No existing capacity
        ))
    end

    for node in NODES, stotech in STO_TECHS
        push!(storage_capacity, (
                                node, 
                                stotech, 
                                value(StorageInvestment[node, stotech])
        ))
    end

    for node in NODES
        ev_V2G = maximum([value(EVStorage[node, time]) for time in PERIODS])
    
        push!(storage_capacity, (
            node, 
            :V2G, 
            ev_V2G
        ))
    end

    # aggregate the nodes investment into total (VGR)
    VGR_gen_cap = combine(groupby(generation_capacity, [:tech]), 
                          :total_capacity => sum => :total_capacity, 
                          :investment => sum => :investment, 
                          :exs_capacity => sum => :exs_capacity
    )
    VGR_gen_cap[!, :node_id] .= :VGR
    VGR_gen_cap = select(VGR_gen_cap, :node_id, :tech, :total_capacity, :investment, :exs_capacity)
    generation_capacity = vcat(generation_capacity, VGR_gen_cap)

    VGR_sto_cap = combine(groupby(storage_capacity, [:tech]), :total_capacity => sum => :total_capacity)
    VGR_sto_cap[!, :node_id] .= :VGR
    VGR_sto_cap = select(VGR_sto_cap, :node_id, :tech, :total_capacity)
    storage_capacity = vcat(storage_capacity, VGR_sto_cap)

    return generation_capacity, storage_capacity
end


function convert_dispatch(modelinfo)
    (; sets, vars) = modelinfo
    (; NODES, GEN_TECHS, EL_GEN, PERIODS, STO_EN) = sets
    (; ActiveGeneration, ReactiveGeneration, StorageCharge, StorageDischarge, StorageLevel) = vars

    # Dispatch solutions
    generation_dispatch = DataFrame(
                                node_id=Symbol[], 
                                tech=Symbol[], 
                                period=Int[], 
                                active_dispatch=Float64[],
                                reactive_dispatch=Float64[],
    )
    
    storage_dispatch = DataFrame(
                            node_id=Symbol[], 
                            tech=Symbol[], 
                            period=Int[], 
                            charge=Float64[],
                            discharge=Float64[],
                            level=Float64[]
    )

    for node in NODES, gentech in GEN_TECHS, time in PERIODS
        active_disp = value(ActiveGeneration[node, gentech, time])
        reactive_disp = gentech in EL_GEN ? value(ReactiveGeneration[node, gentech, time]) : 0.0
        push!(generation_dispatch, (node, gentech, time, active_disp, reactive_disp))
    end

    # aggregate the nodes dispatch into total (VGR)
    VGR_gen_dispatch = combine(groupby(generation_dispatch, [:tech, :period]), 
                               :active_dispatch => sum => :active_dispatch,
                               :reactive_dispatch => sum => :reactive_dispatch
                               )
    VGR_gen_dispatch[!, :node_id] .= :VGR
    VGR_gen_dispatch = select(VGR_gen_dispatch, :node_id, :tech, :period, :active_dispatch, :reactive_dispatch)
    generation_dispatch = vcat(generation_dispatch, VGR_gen_dispatch)

    for node in NODES, stotech in STO_EN, time in PERIODS
        push!(storage_dispatch, (
                                node, 
                                stotech, 
                                time, 
                                value(StorageCharge[node, stotech, time]),
                                value(StorageDischarge[node, stotech, time]),
                                value(StorageLevel[node, stotech, time])
        ))
    end

    # aggregate the nodes charge, discharge, level into total (VGR)
    VGR_sto_disp = combine(
                            groupby(storage_dispatch, [:tech, :period]), 
                            :charge => sum => :charge,
                            :discharge => sum => :discharge,
                            :level => sum => :level
    )
    VGR_sto_disp[!, :node_id] .= :VGR
    VGR_sto_disp = select(VGR_sto_disp, :node_id, :tech, :period, :charge, :discharge, :level)
    storage_dispatch = vcat(storage_dispatch, VGR_sto_disp)

    return generation_dispatch, storage_dispatch
end


function convert_ptx(modelinfo)
    (; m, sets) = modelinfo
    (; NODES, PERIODS, FC, HP, EC) = sets

    # P-to-X techs as demand
    Conv_tech_demand = DataFrame(
                                node_id=Symbol[], 
                                tech=Symbol[], 
                                period=Int[], 
                                demand=Float64[],
    )

    for node in NODES, time in PERIODS
        for gentech in HP
            demand = value(m[:HP_as_demand][node, gentech, time])
            push!(Conv_tech_demand, (node, gentech, time, demand))
        end
        demand = value(m[:EB_as_demand][node, :EB, time])
        push!(Conv_tech_demand, (node, :EB, time, demand))
        for gentech in EC
            demand = value(m[:EC_as_demand][node, gentech, time])
            push!(Conv_tech_demand, (node, gentech, time, demand))
        end
        for gentech in FC
            demand = value(m[:FC_as_demand][node, gentech, time])
            push!(Conv_tech_demand, (node, gentech, time, demand))
        end
    end

    sort!(Conv_tech_demand, [:node_id, :tech, :period])

    # aggregate the nodes dispatch into total (VGR)
    VGR_conv_dispatch = combine(
                                groupby(Conv_tech_demand, [:tech, :period]), 
                                :demand => sum => :demand,
    )
    VGR_conv_dispatch[!, :node_id] .= :VGR
    VGR_conv_dispatch = select(VGR_conv_dispatch, :node_id, :tech, :period, :demand)
    Conv_tech_demand = vcat(Conv_tech_demand, VGR_conv_dispatch)

    return Conv_tech_demand
end


function convert_expimp(modelinfo)
    (; sets, vars) = modelinfo
    (; TRANSMISSION_NODES, PERIODS) = sets
    (; ImportFrom) = vars

    # Import Export solutions
    export_import = DataFrame(
                            node_id=Symbol[], 
                            period=Int[],
                            ImportFrom=Float64[],
                            net_import=Float64[],
                            net_export=Float64[],
    )

    for node in TRANSMISSION_NODES, time in PERIODS
        push!(export_import, (
                            node, 
                            time, 
                            value(ImportFrom[node, time]),
                            max(value(ImportFrom[node, time]), 0),
                            abs(min(value(ImportFrom[node, time]), 0)),                              
        ))
    end

    # aggregate the nodes import, export, exp_import into total (VGR)
    VGR_ei_sol = combine(groupby(export_import, [:period]), 
                         :ImportFrom => sum => :ImportFrom,
                         :net_import => sum => :net_import,
                         :net_export => sum => :net_export
    )
    VGR_ei_sol[!, :node_id] .= :VGR
    VGR_ei_sol = select(VGR_ei_sol, :node_id, :period, :ImportFrom, :net_import, :net_export)
    export_import = vcat(export_import, VGR_ei_sol)

    return export_import
end


function convert_voltage(modelinfo)
    (; sets, vars) = modelinfo
    (; NODES, PERIODS) = sets
    (; NodalVoltage, NodalAngle) = vars

    # Voltage
    Voltage = DataFrame(
                    node_id=Symbol[], 
                    period=Int[], 
                    NodalVoltage=Float64[],
                    nodal_angle_rad=Float64[],
                    nodal_angle_deg=Float64[],
    )

    for node in NODES, time in PERIODS
        push!(Voltage, (
                        node, 
                        time, 
                        value(NodalVoltage[node, time]),
                        value(NodalAngle[node, time]),
                        rad2deg(value(NodalAngle[node, time])),
        ))
    end

    return Voltage
end


function convert_nodal_el(modelinfo)
    (; m, sets, parameters, vars, constraints, configs) = modelinfo
    (; NODES, TRANSMISSION_NODES, EL_GEN, H2_STO, PERIODS, HP, EC, BAT_EN) = sets
    (; ActiveGeneration, StorageCharge, StorageDischarge, EVChargingSlow, 
       EVDischargeNet, ImportFrom, Curtailment) = vars
    (; P_enter, P_exit) = constraints
    (; hourly_direct_ev_demand, fast_charging_demand, eldemand_data) = parameters

    # Electricity active nodal balance and power enter/exit
    # cap Compensation when Compensation > 0
    # otherwise considered as reac Compensation
    nodal_power = DataFrame(
                        node_id=Symbol[], 
                        period=Int[],
                        nodal_generation=Float64[],
                        nodal_demand=Float64[],
                        curtailment=Float64[],
                        nodal_balance=Float64[],
                        p_enter=Float64[],
                        p_exit=Float64[],
    )

    # El demand for charging H2 storage
    eff_el_H2 = Dict(
        :LRC => 0.02,
        :HST => 0.02
    )

    for node in NODES, time in PERIODS

        if configs.use_EV == :no

            nodal_generation = sum(value(ActiveGeneration[node, gentech, time]) for gentech in EL_GEN) +
                               sum(value(StorageDischarge[node, stotech, time]) for stotech in BAT_EN) +
                               (node in TRANSMISSION_NODES ? value(ImportFrom[node, time]) : 0)

            nodal_demand = eldemand_data[time, node] +
                           sum(value(m[:HP_as_demand][node, gentech, time]) for gentech in HP) +
                           value(m[:EB_as_demand][node, :EB, time]) +
                           sum(value(m[:EC_as_demand][node, gentech, time]) for gentech in EC) +
                           sum(value(StorageCharge[node, stotech, time]) for stotech in BAT_EN) +
                           sum(value(StorageCharge[node, stotech, time]) * eff_el_H2[stotech] for stotech in H2_STO) #+

        else
            if configs.ev_ERS == :no

                nodal_generation = sum(value(ActiveGeneration[node, gentech, time]) for gentech in EL_GEN) +
                                   sum(value(StorageDischarge[node, stotech, time]) for stotech in BAT_EN) +
                                   value(EVDischargeNet[node, time]) +
                                   (node in TRANSMISSION_NODES ? value(ImportFrom[node, time]) : 0)                

                nodal_demand = eldemand_data[time, node] +
                               sum(value(m[:HP_as_demand][node, gentech, time]) for gentech in HP) +
                               value(m[:EB_as_demand][node, :EB, time]) +
                               sum(value(m[:EC_as_demand][node, gentech, time]) for gentech in EC) +
                               sum(value(StorageCharge[node, stotech, time]) for stotech in BAT_EN) +
                               sum(value(StorageCharge[node, stotech, time]) * eff_el_H2[stotech] for stotech in H2_STO) +
                               value(EVChargingSlow[node, time]) +
                               value(hourly_direct_ev_demand[node, time]) #+

            else

                nodal_generation = sum(value(ActiveGeneration[node, gentech, time]) for gentech in EL_GEN) +
                                   sum(value(StorageDischarge[node, stotech, time]) for stotech in BAT_EN) +
                                   value(EVDischargeNet[node, time]) +
                                   (node in TRANSMISSION_NODES ? value(ImportFrom[node, time]) : 0)                

                nodal_demand = eldemand_data[time, node] +
                               sum(value(m[:HP_as_demand][node, gentech, time]) for gentech in HP) +
                               value(m[:EB_as_demand][node, :EB, time]) +
                               sum(value(m[:EC_as_demand][node, gentech, time]) for gentech in EC) +
                               sum(value(StorageCharge[node, stotech, time]) for stotech in BAT_EN) +
                               sum(value(StorageCharge[node, stotech, time]) * eff_el_H2[stotech] for stotech in H2_STO) +
                               value(EVChargingSlow[node, time]) +
                               value(hourly_direct_ev_demand[node, time]) +
                               value(fast_charging_demand[node]) #+
            end
        end

        balance = nodal_generation + 
                  value(P_enter[node, time]) -
                  nodal_demand -
                  value(Curtailment[node, time]) -
                  value(P_exit[node, time])

        push!(nodal_power, (
                            node, 
                            time,
                            nodal_generation,
                            nodal_demand,
                            value(Curtailment[node, time]),
                            balance,
                            value(P_enter[node, time]),
                            value(P_exit[node, time]),
        ))
    end

    # aggregate the balance into total (VGR)
    VGR_nb_sol = combine(
                        groupby(nodal_power, [:period]), 
                        :nodal_generation => sum => :nodal_generation,
                        :nodal_demand => sum => :nodal_demand,
                        :curtailment => sum => :curtailment,
                        :nodal_balance => sum => :nodal_balance,
                        :p_enter => sum => :p_enter,
                        :p_exit => sum => :p_exit,
    )
    VGR_nb_sol[!, :node_id] .= :VGR
    VGR_nb_sol = select(
                        VGR_nb_sol, 
                        :node_id, 
                        :period, 
                        :nodal_generation, 
                        :nodal_demand, 
                        :curtailment, 
                        :nodal_balance, 
                        :p_enter, 
                        :p_exit, 
    )
    nodal_power = vcat(nodal_power, VGR_nb_sol)

    return nodal_power
end


function convert_nodal_reactive(modelinfo)
    (; sets, vars, constraints, parameters) = modelinfo
    (; NODES, EL_GEN, PERIODS) = sets
    (; ReactiveGeneration, Compensation) = vars
    (; Q_enter, Q_exit) = constraints
    (; reactive_demand) = parameters

    # Reactive nodal balance and power enter/exit
    # cap Compensation when Compensation > 0
    # otherwise considered as reac Compensation
    nodal_power = DataFrame(
                        node_id=Symbol[], 
                        period=Int[],
                        nodal_generation=Float64[],
                        nodal_demand=Float64[],
                        nodal_balance=Float64[],
                        q_enter=Float64[],
                        q_exit=Float64[],
                        cap_compensation=Float64[],
                        reac_compensation=Float64[],
    )

    # El demand for charging H2 storage
    for node in NODES, time in PERIODS

        nodal_generation = sum(value(ReactiveGeneration[node, gentech, time]) for gentech in EL_GEN) +
                           value(Compensation[node, time])

        nodal_demand = reactive_demand[time, node] 

        balance = nodal_generation + 
                  value(Q_enter[node, time]) -
                  nodal_demand -
                  value(Q_exit[node, time])

        push!(nodal_power, (
                            node, 
                            time,
                            nodal_generation,
                            nodal_demand,
                            balance,
                            value(Q_enter[node, time]),
                            value(Q_exit[node, time]),
                            max(value(Compensation[node, time]), 0),
                            abs(min(value(Compensation[node, time]), 0)),
        ))
    end

    # aggregate the balance into total (VGR)
    VGR_nb_sol = combine(
                        groupby(nodal_power, [:period]), 
                        :nodal_generation => sum => :nodal_generation,
                        :nodal_demand => sum => :nodal_demand,
                        :nodal_balance => sum => :nodal_balance,
                        :q_enter => sum => :q_enter,
                        :q_exit => sum => :q_exit,
                        :cap_compensation => sum => :cap_compensation,
                        :reac_compensation => sum => :reac_compensation,
    )
    VGR_nb_sol[!, :node_id] .= :VGR
    VGR_nb_sol = select(
                        VGR_nb_sol, 
                        :node_id, 
                        :period, 
                        :nodal_generation, 
                        :nodal_demand, 
                        :nodal_balance, 
                        :q_enter, 
                        :q_exit, 
                        :cap_compensation, 
                        :reac_compensation
    )
    nodal_power = vcat(nodal_power, VGR_nb_sol)

    return nodal_power
end


function convert_nodal_heat(modelinfo)
    (; sets, vars, parameters) = modelinfo
    (; NODES, HEAT_STO, PERIODS, CHP, HP, BOILER) = sets
    (; ActiveGeneration, StorageCharge, StorageDischarge) = vars

    (; gentech_data, heatdemand_data) = parameters

    # Heat nodal balance
    nodal_power = DataFrame(
                        node_id=Symbol[], 
                        period=Int[],
                        nodal_generation=Float64[],
                        nodal_demand=Float64[],
                        nodal_balance=Float64[],
    )

    BOILER_NOT_EB = setdiff(BOILER, [:EB])

    for node in NODES, time in PERIODS

        nodal_generation = sum(value(ActiveGeneration[node, gentech, time]) / gentech_data[gentech].Alpha for gentech in CHP) +                # generation from heat techs, CHP if with alpha
                           sum(value(ActiveGeneration[node, gentech, time]) for gentech in HP) +                                         # for HP
                           sum(value(ActiveGeneration[node, gentech, time]) / gentech_data[gentech].Efficiency for gentech in BOILER_NOT_EB) + # for boilers      
                           value(ActiveGeneration[node, :EB, time]) +                                                       # for boilers      
                           sum(value(StorageDischarge[node, stotech, time]) for stotech in HEAT_STO)                                     # discharge from heat storage


        nodal_demand = heatdemand_data[time, node] + sum(value(StorageCharge[node, stotech, time]) for stotech in HEAT_STO)

        balance = nodal_generation -
                  nodal_demand 

        push!(nodal_power, (
                            node, 
                            time,
                            nodal_generation,
                            nodal_demand,
                            balance,
        ))
    end

    # aggregate the balance into total (VGR)
    VGR_nb_sol = combine(
                        groupby(nodal_power, [:period]), 
                        :nodal_generation => sum => :nodal_generation,
                        :nodal_demand => sum => :nodal_demand,
                        :nodal_balance => sum => :nodal_balance,
    )
    VGR_nb_sol[!, :node_id] .= :VGR
    VGR_nb_sol = select(
                        VGR_nb_sol, 
                        :node_id, 
                        :period, 
                        :nodal_generation, 
                        :nodal_demand, 
                        :nodal_balance, 
    )
    nodal_power = vcat(nodal_power, VGR_nb_sol)

    return nodal_power
end


function convert_nodal_h2(modelinfo)
    (; m, sets, vars, parameters) = modelinfo
    (; NODES, H2_STO, PERIODS, FC, EC) = sets
    (; ActiveGeneration, StorageCharge, StorageDischarge) = vars
    (; h2demand_data) = parameters

    # Hydrogen nodal balance
    nodal_power = DataFrame(
                        node_id=Symbol[], 
                        period=Int[],
                        nodal_generation=Float64[],
                        nodal_demand=Float64[],
                        nodal_balance=Float64[],
    )

    for node in NODES, time in PERIODS

        nodal_generation = sum(value(ActiveGeneration[node, gentech, time]) for gentech in EC) +  # electrolyser to convert el - h2
                           sum(value(StorageDischarge[node, stotech, time]) for stotech in H2_STO)


        nodal_demand = h2demand_data[time, node] +
                       sum(value(StorageCharge[node, stotech, time]) for stotech in H2_STO) +     # charging heat storage
                       sum(value(m[:FC_as_demand][node, gentech, time]) for gentech in FC)

        balance = nodal_generation -
                  nodal_demand 

        push!(nodal_power, (
                            node, 
                            time,
                            nodal_generation,
                            nodal_demand,
                            balance,
        ))
    end

    # aggregate the balance into total (VGR)
    VGR_nb_sol = combine(
                        groupby(nodal_power, [:period]), 
                        :nodal_generation => sum => :nodal_generation,
                        :nodal_demand => sum => :nodal_demand,
                        :nodal_balance => sum => :nodal_balance,
    )
    VGR_nb_sol[!, :node_id] .= :VGR
    VGR_nb_sol = select(
                        VGR_nb_sol, 
                        :node_id, 
                        :period, 
                        :nodal_generation, 
                        :nodal_demand, 
                        :nodal_balance, 
    )
    nodal_power = vcat(nodal_power, VGR_nb_sol)

    return nodal_power
end


function convert_ev(modelinfo)
    (; m, sets, vars, parameters, configs) = modelinfo
    (; NODES, PERIODS) = sets
    (; EVChargingSlow, EVDischargeNet, EVStorage) = vars
    (; hourly_direct_ev_demand, fast_charging_demand) = parameters

    # EV solutions
    if configs.use_EV == :yes
        if configs.ev_ERS == :no
            ev_solutions = DataFrame(
                                node_id=Symbol[], 
                                period=Int[],
                                direct_demand=Float64[],
                                charging_slow=Float64[],
                                discharge_net=Float64[],
                                storage=Float64[],
            )
            
            for node in NODES, time in PERIODS
                push!(ev_solutions, (
                                    node, 
                                    time,
                                    value(hourly_direct_ev_demand[node, time]),
                                    value(EVChargingSlow[node, time]),
                                    value(EVDischargeNet[node, time]),
                                    value(EVStorage[node, time]),
                ))
            end

            # aggregate the nodes charge, discharge, level into total (VGR)
            VGR_ev_sol = combine(groupby(ev_solutions, [:period]), 
                                :direct_demand => sum => :direct_demand,
                                :charging_slow => sum => :charging_slow,
                                :discharge_net => sum => :discharge_net,
                                :storage => sum => :storage
            )
            VGR_ev_sol[!, :node_id] .= :VGR
            VGR_ev_sol = select(VGR_ev_sol, :node_id, :period, :direct_demand, :charging_slow, :discharge_net, :storage)
            ev_solutions = vcat(ev_solutions, VGR_ev_sol)

        else
            ev_solutions = DataFrame(
                                node_id=Symbol[], 
                                period=Int[],
                                direct_demand=Float64[],
                                fast_charging=Float64[],
                                charging_slow=Float64[],
                                discharge_net=Float64[],
                                storage=Float64[],
            )
            
            for node in NODES, time in PERIODS
                push!(ev_solutions, (
                                    node, 
                                    time,
                                    value(hourly_direct_ev_demand[node, time]),
                                    value(fast_charging_demand[node, time]),
                                    value(EVChargingSlow[node, time]),
                                    value(EVDischargeNet[node, time]),
                                    value(EVStorage[node, time]),
                ))
            end

            # aggregate the nodes charge, discharge, level into total (VGR)
            VGR_ev_sol = combine(groupby(ev_solutions, [:period]), 
                                :direct_demand => sum => :direct_demand,
                                :fast_charging => sum => :fast_charging,
                                :charging_slow => sum => :charging_slow,
                                :discharge_net => sum => :discharge_net,
                                :storage => sum => :storage
            )
            VGR_ev_sol[!, :node_id] .= :VGR
            VGR_ev_sol = select(VGR_ev_sol, :node_id, :period, :direct_demand, :fast_charging, :charging_slow, :discharge_net, :storage)
            ev_solutions = vcat(ev_solutions, VGR_ev_sol)
        
        end
    end

    return ev_solutions
end


function convert_mc(modelinfo)
    (; sets, constraints) = modelinfo
    (; NODES, PERIODS) = sets
    (; el_nodal_balance, reactive_nodal_balance, heat_nodal_balance, h2_nodal_balance) = constraints

    # Nodal Balance Marginal costs
    nodal_marginal_cost = DataFrame(
                                node_id=Symbol[], 
                                period=Int[], 
                                el_mc=Float64[],
                                q_mc=Float64[],
                                heat_mc=Float64[],
                                h2_mc=Float64[],
    )

    for node in NODES, time in PERIODS
        push!(nodal_marginal_cost, (
                                    node, 
                                    time, 
                                    shadow_price(el_nodal_balance[node, time]),
                                    shadow_price(reactive_nodal_balance[node, time]),
                                    shadow_price(heat_nodal_balance[node, time]),
                                    shadow_price(h2_nodal_balance[node, time])
        ))
    end

    return nodal_marginal_cost
end


function convert_lines(modelinfo)
    (; sets, vars, constraints) = modelinfo
    (; PERIODS, LINES) = sets
    (; ActiveFlow, ReactiveFlow) = vars
    (; p_flow, q_flow) = constraints

    # Power lines p & q flows and marginal costs
    lines_solutions = DataFrame(
                    lines_id=Symbol[], 
                    period=Int[], 
                    p_flow=Float64[],
                    q_flow=Float64[],
                    p_mc=Float64[],
                    q_mc=Float64[],
    )

    for line in LINES, time in PERIODS
        push!(lines_solutions, (
                                line, 
                                time, 
                                value(ActiveFlow[line, time]),
                                value(ReactiveFlow[line, time]),
                                shadow_price(p_flow[line, time]),
                                shadow_price(q_flow[line, time]),
        ))
    end

    return lines_solutions
end