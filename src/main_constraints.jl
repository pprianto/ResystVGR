function make_constraints(modelinfo)
    configs = modelinfo.configs
    if configs.use_EV == :yes
        ev_params = inputdata_EV(modelinfo)
        @time "Constraints - EV module"  vars = ev_agg_model(modelinfo, ev_params)
        parameters = (; modelinfo.parameters..., ev_params...)
        modelinfo = (; modelinfo..., parameters, vars)
    else
        ev_params = (; )
    end

    @time "Constraints - Generation limits"  generation_constraints(modelinfo)
    @time "Constraints - Storage constraints"  storage_constraints(modelinfo)
    @time "Constraints - Balances"  bal_constraints = balance_constraints(modelinfo, ev_params)
    @time "Constraints - Power flow"  pflow_constraints = powerflow_constraints(modelinfo)
    @time "Constraints - Objective"  obj_constraints = cost_constraints(modelinfo)

    constraints = (; bal_constraints..., pflow_constraints..., obj_constraints...)
    modelinfo = (; modelinfo..., constraints)
    return modelinfo
end


function generation_constraints(modelinfo)
    (; m, sets, inputs, vars, configs) = modelinfo
    (; grid_infra, profiles, potentials) = inputs
    (; NODES, GBG, GEN_TECHS, EL_GEN, PERIODS, FC, WIND, PV, VRES, EC) = sets
    (; GenerationInvestment, ActiveGeneration, ReactiveGeneration) = vars

    # extract the OSM existing capacities and potentials based on Niclas' GIS data
    existing_capacities, gis_potentials =
        parse_potentials(grid_infra.subs, grid_infra.pp, potentials.solar, potentials.wind)

    # define existing generation as expression using input data
    @expression(m, existing_generation[node in NODES, gentech in GEN_TECHS],
        get(existing_capacities, (node, gentech), 0.0)  # 0.0 is just a default if the key doesn't exist
    )

    # techs that most probably not further invested in future, for now only for hydro and waste CHP
    TECHS_NOT_INVESTED = [:WCHP, :HYD]  # [:WCHP, :HYD, :COCHP, :WBO]
    for node in NODES, gentech in TECHS_NOT_INVESTED
        fix(GenerationInvestment[node, gentech], 0.0, force=true)
    end
    
    # VRE GENERATION INVESTMENT AND GENERATION
    # according to ACCEL and RISE Report
    # Behovsanalys av elanvändning, produktion och distribution i Västra Götaland på kort och lång sikt

    # Electrolysers assumed to be only allowed in areas that have hydrogen demand
    # similar applies to fuel cell (reversible process)
    # in this case, Gothenburg, Lysekil, Stenungsund nodes
    STE_LYS = [:STE1, :LYS1, :LYS2]
    EC_LOC = [GBG; STE_LYS]
    EC_NOT_ELIGIBLE = setdiff(NODES, EC_LOC)
    EC_FC_TECHS = [FC; EC]

    # Fix generation investment for ineligible nodes
    for node in EC_NOT_ELIGIBLE, gentech in EC_FC_TECHS
        fix(GenerationInvestment[node, gentech], 0.0, force=true)
    end

    # Fix generation variables for ineligible nodes
    for node in EC_NOT_ELIGIBLE, time in PERIODS
        # Fix active generation for all EC/FC technologies
        for gentech in EC_FC_TECHS
            fix(ActiveGeneration[node, gentech, time], 0.0, force=true)
        end

        # Fix reactive generation for FC technologies only
        for gentech in FC
            fix(ReactiveGeneration[node, gentech, time], 0.0, force=true)
        end
    end

    # Investments of renewable technologies
    if configs.potential == :gis
        # Based on Niclas GIS data. The limits definition is done in utilities.jl.
        NWOFF_NODES, FWOFF_NODES = vres_constraints_GlobalEnergyGIS(modelinfo, gis_potentials)
    else
        # Based on external reports. The limits definition is done in utilities.jl.
        NWOFF_NODES, FWOFF_NODES = vres_constraints_other_sources(modelinfo)
    end
    VRES_NODES = Dict(:WON=>NODES, :NWOFF=>NWOFF_NODES, :FWOFF=>FWOFF_NODES, :PVROOF=>NODES, :PVTRACK=>NODES)

    # specific generation limits for RE based on Renewables Ninja profile
    # except for ground PV which takes 75% and 80%
    # this values result in reasonable FLH for a full run

    # relaxed generation limits
    @constraints m begin
        upper_limit_VRES[tech in VRES, node in VRES_NODES[tech], time in PERIODS],
            ActiveGeneration[node, tech, time] <= profiles[tech][time, node] * ( existing_generation[node, tech] + GenerationInvestment[node, tech] )
    end

    # Maximum generation of hydropower - optimized summation
    @constraint(m, upper_limit_HYD,
        sum( 
            sum( ActiveGeneration[node, :HYD, time] for node in NODES ) / 1e3
            for time in PERIODS) <= 2e3                
    )

    #=------------------------------------------------------------------------------
    GENERATION LIMITS
    ------------------------------------------------------------------------------=#
    # general active and reactive generation limited by respective capacities
    # reactive generation is limited by the power factor relationship between active - reactive
    # reactive generation is assumed only applies for electricity generation technologies
    # Wind, PV are excluded because they are defined differently
    
    NOT_GENERAL_GEN_TECHS = setdiff(GEN_TECHS, [WIND; PV])

    @constraint(m, active_generation_limit_up[node in NODES, gentech in NOT_GENERAL_GEN_TECHS, time in PERIODS],
        ActiveGeneration[node, gentech, time] <= existing_generation[node, gentech] + GenerationInvestment[node, gentech]
    )

    # Bounds of reactive generation
    # according to SvK requirement for generators
    # https://www.svk.se/om-kraftsystemet/legalt-ramverk/eu-lagstiftning-/natanslutning-av-generatorer-rfg/

    # subsets of Power Park Modules (PPM) and Synchronous
    PPM_GEN = [WIND; PV; FC]
    SYNC_GEN = setdiff(EL_GEN, PPM_GEN)

    @constraints m begin
        # Power Park Modules - reactive power limits
        reactive_generation_limit_ppm_low[node in NODES, gentech in PPM_GEN, time in PERIODS],
            - 1/3 * ActiveGeneration[node, gentech, time] <= ReactiveGeneration[node, gentech, time]

        reactive_generation_limit_ppm_up[node in NODES, gentech in PPM_GEN, time in PERIODS],
            ReactiveGeneration[node, gentech, time] <= 1/3 * ActiveGeneration[node, gentech, time]

        # Conventional/Synchronous PP - reactive power limits
        # possible to only generate reactive power as in sync condenser
        reactive_generation_limit_syn_low[node in NODES, gentech in SYNC_GEN, time in PERIODS],
            - 1/6 * (existing_generation[node, gentech] + GenerationInvestment[node, gentech]) <= ReactiveGeneration[node, gentech, time]        

        reactive_generation_limit_syn_up[node in NODES, gentech in SYNC_GEN, time in PERIODS],
            ReactiveGeneration[node, gentech, time] <= 1/3 * (existing_generation[node, gentech] + GenerationInvestment[node, gentech])
    end

    return (; existing_generation)
end     # end generation_constraints


function storage_constraints(modelinfo)
    (; m, sets, parameters, vars) = modelinfo
    (; NODES, GBG, H2_STO, PERIODS, STO_EN) = sets
    (; StorageCharge, StorageDischarge, StorageInvestment, StorageLevel) = vars
    (; stotech_data) = parameters

    # Storage level empty for start and end period
    first_period = first(PERIODS)
    last_period = last(PERIODS)    
    
    # fix storage levels for start and end periods
    start_vars = [StorageLevel[node, stotech, first_period] 
                    for node in NODES, stotech in STO_EN]
    end_vars = [StorageLevel[node, stotech, last_period] 
                for node in NODES, stotech in STO_EN]
    
    fix.(start_vars, 0.0; force=true)
    fix.(end_vars, 0.0; force=true)

    # efficiency constants
    charge_eff = Dict(stotech => stotech_data[stotech].Ch_eff for stotech in STO_EN)
    discharge_eff = Dict(stotech => stotech_data[stotech].Dch_eff for stotech in STO_EN)
    loss_rate = Dict(stotech => stotech_data[stotech].Loss / 100 for stotech in STO_EN)
    injection_rate = Dict(stotech => stotech_data[stotech].InjectionRate for stotech in STO_EN)
    withdrawal_rate = Dict(stotech => stotech_data[stotech].WithdrawalRate for stotech in STO_EN)

    @constraints m begin
        # Storage level limited by the capacity
        storage_level_limit[node in NODES, stotech in STO_EN, time in PERIODS],    
            StorageLevel[node, stotech, time] <= StorageInvestment[node, stotech]
    
        # Hourly storage level
        # assumed that each period has 0.1% or 0.2% loss (last term)
        # supposed to be lower, but might come to very small number?
        storage_balance[node in NODES, stotech in STO_EN, time in PERIODS[1:end-1]],
            StorageLevel[node, stotech, time+1] <=
            StorageLevel[node, stotech, time] +
            StorageCharge[node, stotech, time] * charge_eff[stotech] - 
            StorageDischarge[node, stotech, time] / discharge_eff[stotech] -
            StorageLevel[node, stotech, time] * loss_rate[stotech]

        # Storage charge limited by the capacity and discharging rate
        charge_limit_storage[node in NODES, stotech in STO_EN, time in PERIODS],    
            StorageCharge[node, stotech, time] <= StorageInvestment[node, stotech] / injection_rate[stotech]
    
        # Storage discharge limited by the capacity and charging rate
        discharge_limit_storage[node in NODES, stotech in STO_EN, time in PERIODS],    
            StorageDischarge[node, stotech, time] <= StorageInvestment[node, stotech] / withdrawal_rate[stotech]

        # Battery charge and discharge limited by the capacity component limit
        charge_limit_LiIon[node in NODES, time in PERIODS],    
            StorageCharge[node, :LI_EN, time] <= StorageInvestment[node, :LI_CAP]   

        discharge_limit_LiIon[node in NODES, time in PERIODS],    
            StorageDischarge[node, :LI_EN, time] <= StorageInvestment[node, :LI_CAP]       
    end
    
    # Line Rock cavern cycle limits
    LRC_CYCLES_PER_YEAR = 20
    SCALE_FACTOR = 1e3 # scaled to improve model coefficients
    
    # LRC efficiency constants
    eff_LRC_charge = stotech_data[:LRC].Ch_eff
    eff_LRC_discharge = stotech_data[:LRC].Dch_eff
    
    @constraints m begin
        # Line Rock cavern cycle limits (charging and discharging), assumed 20 times per year
        line_caverns_charge_limit[node in NODES],
            sum(StorageCharge[node, :LRC, time] * eff_LRC_charge for time in PERIODS) / SCALE_FACTOR <= 
            (StorageInvestment[node, :LRC] * LRC_CYCLES_PER_YEAR) / SCALE_FACTOR

        line_caverns_discharge_limit[node in NODES],
            sum(StorageDischarge[node, :LRC, time] / eff_LRC_discharge for time in PERIODS) / SCALE_FACTOR <= 
            (StorageInvestment[node, :LRC] * LRC_CYCLES_PER_YEAR) / SCALE_FACTOR
    end

    # Define storage technologies that are not feasible in Gothenburg
    GBG_INFEASIBLE_STO = [:PTES, :LRC]

    # fix storage investments and operations for infeasible nodes
    # Fix storage investments for Gothenburg
    gbg_investment_vars = [StorageInvestment[node, stotech] 
                            for node in GBG, stotech in GBG_INFEASIBLE_STO]
    fix.(gbg_investment_vars, 0.0; force=true)
    
    # Fix storage operation variables for Gothenburg
    gbg_charge_vars = [StorageCharge[node, stotech, time] 
                        for node in GBG, stotech in GBG_INFEASIBLE_STO, time in PERIODS]
    gbg_discharge_vars = [StorageDischarge[node, stotech, time] 
                            for node in GBG, stotech in GBG_INFEASIBLE_STO, time in PERIODS]
    gbg_level_vars = [StorageLevel[node, stotech, time] 
                        for node in GBG, stotech in GBG_INFEASIBLE_STO, time in PERIODS]
    
    fix.(gbg_charge_vars, 0.0; force=true)
    fix.(gbg_discharge_vars, 0.0; force=true)
    fix.(gbg_level_vars, 0.0; force=true)

    # LRC assumed to be only allowed in areas that have hydrogen demand
    # except Gothenburg, which will use H2 tanks
    # in this case, Gothenburg, Lysekil, Stenungsund nodes
    LRC_LOC = [GBG; :STE1; :LYS1; :LYS2]
    LRC_NOT_ELIGIBLE = setdiff(NODES, LRC_LOC)

    # fix H2 storage variables for non-eligible nodes
    # Fix H2 storage investments for non-eligible nodes
    h2_investment_vars = [StorageInvestment[node, stotech] 
                            for node in LRC_NOT_ELIGIBLE, stotech in H2_STO]
    fix.(h2_investment_vars, 0.0; force=true)
    
    # Fix H2 storage operation variables for non-eligible nodes
    h2_charge_vars = [StorageCharge[node, stotech, time] 
                        for node in LRC_NOT_ELIGIBLE, stotech in H2_STO, time in PERIODS]
    h2_discharge_vars = [StorageDischarge[node, stotech, time] 
                        for node in LRC_NOT_ELIGIBLE, stotech in H2_STO, time in PERIODS]
    h2_level_vars = [StorageLevel[node, stotech, time] 
                    for node in LRC_NOT_ELIGIBLE, stotech in H2_STO, time in PERIODS]
    
    fix.(h2_charge_vars, 0.0; force=true)
    fix.(h2_discharge_vars, 0.0; force=true)
    fix.(h2_level_vars, 0.0; force=true)

end     # end storage_constraints


function balance_constraints(modelinfo, ev_params)
    (; m, sets, parameters, vars, configs) = modelinfo
    (; NODES, TRANSMISSION_NODES, EL_GEN, HEAT_STO, H2_STO, PERIODS, LINES, NODE_FROM, NODE_TO,
        CHP, FC, WIND, PV, HP, BOILER, EC, BAT_EN) = sets
    (; ActiveGeneration, ReactiveGeneration, GenerationInvestment, ActiveFlow, ReactiveFlow,
        StorageCharge, StorageDischarge, Curtailment, EVChargingSlow, EVDischargeNet, ImportFrom,
        Compensation, CompensationInvestment) = vars
    (;  gentech_data, eldemand_data,reactive_demand, heatdemand_data, h2demand_data) = parameters
    existing_generation = m[:existing_generation]

    # El demand for charging H2 storage
    eff_el_H2 = Dict(
        :LRC => 0.02,
        :HST => 0.02
    )
    
    # heat from hydrogen, not used for now
    eff_heat_H2 = 0.169;

    # temporary expressions for conversion technologies
    @expressions m begin
        # HP conversion
        HP_as_demand[node in NODES, gentech in HP, time in PERIODS],    
            ActiveGeneration[node, gentech, time] / gentech_data[gentech].COP
        
        # EB conversion
        EB_as_demand[node in NODES, gentech in [:EB], time in PERIODS],    
            ActiveGeneration[node, gentech, time] / gentech_data[gentech].Efficiency

        # EC conversion
        EC_as_demand[node in NODES, gentech in EC, time in PERIODS],    
            ActiveGeneration[node, gentech, time] / gentech_data[gentech].Efficiency

        # FC conversion
        FC_as_demand[node in NODES, gentech in FC, time in PERIODS],    
            ActiveGeneration[node, gentech, time] / gentech_data[gentech].Efficiency
    end

    # limits the electrolyser demand according to electricity input, 
    # therefore constraining the electrolyser capacity too
    @constraints m begin
        capacity_limit_EC[node in NODES, gentech in EC, time in PERIODS],
            EC_as_demand[node, gentech, time] <= existing_generation[node, gentech] + GenerationInvestment[node, gentech]
    end

    # define nodal balance equations
    # so that the shadow prices can be calculated
    el_nodal_balance = AxisArray(ConstraintRef, NODES, PERIODS)
    reactive_nodal_balance = AxisArray(ConstraintRef, NODES, PERIODS)
    heat_nodal_balance = AxisArray(ConstraintRef, NODES, PERIODS)
    h2_nodal_balance = AxisArray(ConstraintRef, NODES, PERIODS)

    # power flow in nodes (entering or exiting)
    # will be defined as expressions
    # inside the nodal balance loops
    P_enter = AxisArray(AffExpr, NODES, PERIODS)
    P_exit = AxisArray(AffExpr, NODES, PERIODS)
    Q_enter = AxisArray(AffExpr, NODES, PERIODS)
    Q_exit = AxisArray(AffExpr, NODES, PERIODS)

    # Curtailment is limited by the active generation of RE in each node each period
    RE = [WIND; PV]

    @constraint(m, curtailment_limit[node in NODES, time in PERIODS],
        Curtailment[node, time] <= 
        sum(ActiveGeneration[node, gentech, time] for gentech in RE)
    )

    # Electricity nodal balance
    # Node connections in el balance constraints
    NODE_TO_dict = Dict{Symbol, Vector{Symbol}}()
    NODE_FROM_dict = Dict{Symbol, Vector{Symbol}}()
    
    for node in NODES
        NODE_TO_dict[node] = [line for (idx, line) in enumerate(LINES) if NODE_TO[idx] == node]
        NODE_FROM_dict[node] = [line for (idx, line) in enumerate(LINES) if NODE_FROM[idx] == node]
    end

    # function to define electricity nodal balance constraint
    function create_el_nodal_balance!(node, time)
        
        # node relations defined outside this function
        NODE_TO_nodes = NODE_TO_dict[node]
        NODE_FROM_nodes = NODE_FROM_dict[node]
        is_transmission_node = node in TRANSMISSION_NODES
        
        P_enter[node, time] = @expression(m,     
            sum(ActiveFlow[line, time] for line in NODE_TO_nodes; init=0)
        )

        P_exit[node, time] = @expression(m,     
            sum(ActiveFlow[line, time] for line in NODE_FROM_nodes; init=0)
        )  

        # demand terms
        demand_terms = [
            eldemand_data[time, node],                                                             # el demand
            sum(HP_as_demand[node, gentech, time] for gentech in HP),                           # demand for HP
            EB_as_demand[node, :EB, time],                                                     # demand for boilers
            sum(EC_as_demand[node, gentech, time] for gentech in EC),                           # for electrolyser / H2 demand
            sum(StorageCharge[node, stotech, time] for stotech in BAT_EN),                     # charge battery
            sum(StorageCharge[node, stotech, time] * eff_el_H2[stotech] for stotech in H2_STO),  # el demand to charge h2 storage compressor
            Curtailment[node, time],                                                           # Curtailment
            P_exit[node, time]                                                                     # el flow to other nodes
        ]

        # supply terms
        supply_terms = [
            sum(ActiveGeneration[node, gentech, time] for gentech in EL_GEN),                  # el generation (active)
            sum(StorageDischarge[node, stotech, time] for stotech in BAT_EN),                  # battery discharge
            P_enter[node, time]                                                                     # el flow to this node
        ]
        
        # Add transmission import
        if is_transmission_node
            push!(supply_terms, ImportFrom[node, time])            # import to transmission
        end
        
        add_EV_demand_and_supply_terms!(demand_terms, supply_terms, node, time, modelinfo, ev_params)

        # active power nodal balance
        el_nodal_balance[node, time] = @constraint(m, 
            sum(demand_terms) == sum(supply_terms)
        )
    end

    # Electricity nodal balance defined here
    for node in NODES, time in PERIODS
        create_el_nodal_balance!(node, time)
    end

    # Reactive Power Nodal Balance
    # import of reactive power not allowed

    # constraints to limit Compensation according to installed capacity
    @constraints m begin
        Upper_compensation[node in NODES, time in PERIODS],
            Compensation[node, time] <= CompensationInvestment[node]

        Lower_compensation[node in NODES, time in PERIODS],
            Compensation[node, time] >= -CompensationInvestment[node]
    end

    for node in NODES
        NODE_TO_nodes = NODE_TO_dict[node]
        NODE_FROM_nodes = NODE_FROM_dict[node]
        for time in PERIODS

            Q_enter[node, time] = @expression(m,     
                sum(ReactiveFlow[line, time] for line in NODE_TO_nodes; init=0)
            )

            Q_exit[node, time] = @expression(m,     
                sum(ReactiveFlow[line, time] for line in NODE_FROM_nodes; init=0)
            )   

            # reactive power nodal balance     
            reactive_nodal_balance[node, time] = @constraint(m, 
                reactive_demand[time, node] +                                               # reactive demand
                Q_exit[node, time] <=                                                        # reactive flow to other nodes
                sum(ReactiveGeneration[node, gentech, time] for gentech in EL_GEN) +    # el generation (reactive)
                Compensation[node, time] +                                              # reactive power Compensation
                Q_enter[node, time]                                                         # reactive flow to this node
            )
        end
    end

    BOILER_NOT_EB = setdiff(BOILER, [:EB])
    # Heat nodal balance
    for node in NODES, time in PERIODS
        # heat pipe flow equations would come here if there is any...
        heat_nodal_balance[node, time] = @constraint(m,
            # efficiencies / el-heat conversion rate for HP and Boilers have been considered in el balance therefore not included
            heatdemand_data[time, node] +
            sum(StorageCharge[node, stotech, time] for stotech in HEAT_STO) ==                                              # charging heat storage
            sum(ActiveGeneration[node, gentech, time] / gentech_data[gentech].Alpha for gentech in CHP) +                   # generation from heat techs, CHP if with alpha
            sum(ActiveGeneration[node, gentech, time] for gentech in HP) +                                                  # for HP
            sum(ActiveGeneration[node, gentech, time] / gentech_data[gentech].Efficiency for gentech in BOILER_NOT_EB) +    # for boilers      
            ActiveGeneration[node, :EB, time] +                                                                            # for boilers      
            sum(StorageDischarge[node, stotech, time] for stotech in HEAT_STO)                                              # discharge from heat storage
            # possibility to buy heat from other region?
        )
    end

    # H2 nodal balance
    for node in NODES, time in PERIODS
        # H2 pipe flow equations would come here if there is any...
        h2_nodal_balance[node, time] = @constraint(m,
            h2demand_data[time, node] +
            sum(StorageCharge[node, stotech, time] for stotech in H2_STO) +     # charging heat storage
            sum(FC_as_demand[node, gentech, time] for gentech in FC) ==          # fuel cell to convert h2 - el
            sum(ActiveGeneration[node, gentech, time] for gentech in EC) +      # electrolyser to convert el - h2
            sum(StorageDischarge[node, stotech, time] for stotech in H2_STO)    # discharge from H2 storage
            # possibility to buy H2 from other region?
        )
    end

    constraints = (; el_nodal_balance, reactive_nodal_balance, heat_nodal_balance, h2_nodal_balance,
                    P_enter, P_exit, Q_enter, Q_exit)
    
    return constraints
end


function cost_constraints(modelinfo)
    (; m, sets, parameters, inputs, vars, configs) = modelinfo
    (; NODES, GEN_TECHS, STO_TECHS, PERIODS, HP, EC, BAT_CAP, BAT_EN, STO_EN) = sets
    (; GenerationInvestment, StorageInvestment, CompensationInvestment, ImportFrom, ActiveGeneration,
        StorageDischarge, TotalCost) = vars
    (; price_SE3, price_NO1, price_DK1, gentech_data, stotech_data) = parameters
    (; grid_infra) = inputs
    (; discount_rate, el_heat_tax, co2_budget, emission_fee, co2_limit) = configs
    existing_generation = m[:existing_generation]

    # define investments of technologies
    # capacity substracted by the lower_bound, which is the acquired existing data
    # annualised CRF, rounded to 3 digits
    crf_gen = Dict{Symbol, Float64}()
    crf_sto = Dict{Symbol, Float64}()

    for gentech in GEN_TECHS
        crf_gen[gentech] = round(discount_rate / (1 - 1/(1+discount_rate)^gentech_data[gentech].Lifetime), digits=3)
    end
    
    for stotech in STO_TECHS
        crf_sto[stotech] = round(discount_rate / (1 - 1/(1+discount_rate)^stotech_data[stotech].Lifetime), digits=3)
    end

    # assumes lifetime for reactive power Compensation to be 15 years
    # assumes the cost for reactive power Compensation to be 10,000 €/MVAr
    # assumes Fix O&M for reactive power Compensation to be 5% of investment
    crf_Q = round(discount_rate / (1 - 1/(1+discount_rate)^15), digits=3)
    invcost_Q = 10000   # according to Kirby B. et al. (1997)
    fixOM_Q = 0.05      # arbitraty value

    # subsets to use in costs constraint
    NOT_EC = setdiff(GEN_TECHS, EC)
    NOT_BAT = setdiff(STO_TECHS, [BAT_CAP; BAT_EN])
    TECHS_W_EL_PRICE = [HP; EC; :EB]
    TECHS_W_FUEL = setdiff(GEN_TECHS, TECHS_W_EL_PRICE)

    # cost coefficients for generation technologies
    gen_capex_coeff = Dict{Symbol, Float64}()
    gen_fixom_coeff = Dict{Symbol, Float64}()
    gen_ec_fixom_coeff = Dict{Symbol, Float64}()
    
    for gentech in GEN_TECHS
        gen_capex_coeff[gentech] = gentech_data[gentech].InvCost * crf_gen[gentech]
        if gentech in NOT_EC
            gen_fixom_coeff[gentech] = gentech_data[gentech].FixOM
        else
            # for EC technologies, the fix O&M is calculated according to the investment cost
            gen_ec_fixom_coeff[gentech] = gentech_data[gentech].InvCost * crf_gen[gentech] * gentech_data[gentech].FixOM
        end
    end

    # cost coefficients for storage technologies
    sto_capex_coeff = Dict{Symbol, Float64}()
    sto_fixom_coeff = Dict{Symbol, Float64}()
    
    for stotech in STO_TECHS
        sto_capex_coeff[stotech] = stotech_data[stotech].InvCost * crf_sto[stotech]
        if stotech in NOT_BAT
            sto_fixom_coeff[stotech] = stotech_data[stotech].FixOM
        end
    end

    # cost coefficients for reactive power Compensation
    capex_coeff_Q = invcost_Q * crf_Q
    fixOM_coeff_Q = invcost_Q * crf_Q * fixOM_Q

    # fuel cost coefficients
    fuel_cost = Dict{Symbol, Float64}()
    for gentech in TECHS_W_FUEL
        fuel_cost[gentech] = gentech_data[gentech].FuelPrice / gentech_data[gentech].Efficiency
    end

    # variable O&M coefficients
    varom_coeff = Dict{Symbol, Float64}()
    for gentech in NOT_EC
        varom_coeff[gentech] = gentech_data[gentech].VarOM
    end
    for gentech in EC
        varom_coeff[gentech] = gentech_data[gentech].VarOM
    end
    for stotech in STO_EN
        varom_coeff[stotech] = stotech_data[stotech].VarOM
    end

    # CAPEX costs (in €/MW)
    @expression(m, CostCAPEX, 
        sum( 
            sum(GenerationInvestment[node, gentech] * gen_capex_coeff[gentech] for gentech in GEN_TECHS) +
            sum(StorageInvestment[node, stotech] * sto_capex_coeff[stotech] for stotech in STO_TECHS) +
            CompensationInvestment[node] * capex_coeff_Q
        for node in NODES)
    )

    # fix O&M costs (in €/MW)
    @expression(m, CostFixOM,
        sum(
            sum((existing_generation[node, gentech] + GenerationInvestment[node, gentech]) * gen_fixom_coeff[gentech] for gentech in NOT_EC) +                                              
            sum((existing_generation[node, gentech] + GenerationInvestment[node, gentech]) * gen_ec_fixom_coeff[gentech] for gentech in EC ) +
            CompensationInvestment[node] * fixOM_coeff_Q +  
            sum(StorageInvestment[node, stotech] * sto_fixom_coeff[stotech] for stotech in NOT_BAT) +                                            
            StorageInvestment[node, :LI_CAP] * stotech_data[:LI_CAP].FixOM
        for node in NODES)
    )

    # fuel costs (in €/MWh)
    @expression(m, CostFuel, 
        sum( 
            sum(
                sum(ActiveGeneration[node, gentech, time] * fuel_cost[gentech] for gentech in TECHS_W_FUEL) +
                sum(m[:HP_as_demand][node, gentech, time] * price_SE3[time] for gentech in HP) +
                m[:EB_as_demand][node, :EB, time] * price_SE3[time] +
                sum(m[:EC_as_demand][node, gentech, time] * price_SE3[time] for gentech in EC)
                for node in NODES)
        for time in PERIODS)
    )

    # variable O/M costs (in €/MWh)
    @expression(m, CostVarOM,
        sum( 
            sum( 
                sum(ActiveGeneration[node, gentech, time] * varom_coeff[gentech] for gentech in NOT_EC) +
                sum(m[:EC_as_demand][node, gentech, time] * varom_coeff[gentech] for gentech in EC) +
                sum(StorageDischarge[node, stotech, time] * varom_coeff[stotech] for stotech in STO_EN)
                for node in NODES)
        for time in PERIODS)
    )

    # ---------------------- REGIONAL TRANSMISSION NODES SUBSETS ------------------------ 
    trans_node = filter(row -> row.import_trans == true, grid_infra.subs)    
    SE3_TRANS_NODES = Symbol.(filter(row -> !(row.node_id in ["MOL1", "DAL1"]), trans_node).node_id)
    NO1_TRANS_NODES = Symbol.(filter(row -> row.node_id == "DAL1", trans_node).node_id)
    DK1_TRANS_NODES = Symbol.(filter(row -> row.node_id == "MOL1", trans_node).node_id)
    
    # import/export costs (in €/MWh)
    @expression(m, CostExportImport,
        # export/import from transmission system
        sum( 
            sum(ImportFrom[node, time] * price_SE3[time] for node in SE3_TRANS_NODES) +
            sum(ImportFrom[node, time] * price_NO1[time] for node in NO1_TRANS_NODES) +
            sum(ImportFrom[node, time] * price_DK1[time] for node in DK1_TRANS_NODES) 
        for time in PERIODS)
    )

    # taxes by using el for heat (in €/MWh)
    @expression(m, CostTaxes,
        sum( 
            sum( 
               el_heat_tax * ActiveGeneration[node, :EB, time] +                                             
                sum(el_heat_tax * ActiveGeneration[node, gentech, time] for gentech in HP) 
            for node in NODES)
        for time in PERIODS)
    )

    # ---------------------- CO2 LIMITS -------------------------------------------------
    # CO2 limits and constraints in tonne
    # 2050 assumes net zero is achieved

    # limiting the technologies based on CO2 limits/budgets
    # can be very restrictive?
    # first constraint indicates the constraint related to CO2 budget (in tCO2)
    # second constraint indicate the cost due to emitting CO2 (in € / tonneCO2)
    @expression(m, SystemEmissions,
        sum(
            sum(
                sum(ActiveGeneration[node, gentech, time] * gentech_data[gentech].Emission / gentech_data[gentech].Efficiency for gentech in GEN_TECHS)
            for node in NODES)
        for time in PERIODS)
    )

    @expression(m, CostCO2,
        sum(
            sum(
                sum(ActiveGeneration[node, gentech, time] * gentech_data[gentech].Emission / gentech_data[gentech].Efficiency * emission_fee for gentech in GEN_TECHS)
            for node in NODES)
        for time in PERIODS)
    )

    # CO2 limit constraint
    if co2_limit == :yes
        @constraint(m, co2_limit,
            SystemEmissions <= co2_budget
        )
    end

    # System Cost
    # represented in € for the total cost
    @constraint(m, system_cost,
        TotalCost >= CostCAPEX + CostFixOM + CostFuel + CostVarOM + 
                        CostExportImport + CostTaxes + CostCO2   # in €
    )

    if solver_name(m) == "HiGHS"
        @objective(m, Min, CostCAPEX + CostFixOM + CostFuel + CostVarOM +
                        CostExportImport + CostTaxes + CostCO2   # in €
        )
    else
        @objective(m, Min, TotalCost)
    end

    constraints = (; CostCAPEX, CostFixOM, CostFuel, CostVarOM, CostExportImport,
                    CostTaxes, CostCO2, SystemEmissions)
    
    return constraints
end     # end cost_constraints
