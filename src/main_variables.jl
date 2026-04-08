function make_variables(modelinfo)
    (; m, sets, configs) = modelinfo
    (; NODES, TRANSMISSION_NODES, GEN_TECHS, EL_GEN, STO_TECHS, PERIODS, LINES, STO_EN) = sets
    (; subscription, import_limit) = configs

    # ---------------------- COST VARIABLES ---------------------------------------------
    @variables m begin
        TotalCost          # in €
    end

    # ---------------------- GENERATION AND STORAGE VARIABLES ---------------------------

    # Generation and Storage Capacities (MW)
    # upper and lower bounds for generation capaicity is defined in set_gen_bounds function
    @variables m begin
        GenerationInvestment[node in NODES, gentech in GEN_TECHS] >= 0
        StorageInvestment[node in NODES, stotech in STO_TECHS] >= 0
        CompensationInvestment[node in NODES] >= 0
    end
    
    # Active and Reactive power dispatch (MWh or MVArh)
    # reactive generation is assumed only applies for electricity generation technologies
    # Compensation means reactive power Compensation
    @variables m begin
        ActiveGeneration[node in NODES, gentech in GEN_TECHS, time in PERIODS]  >= 0
        ReactiveGeneration[node in NODES, gentech in EL_GEN, time in PERIODS]
        Curtailment[node in NODES, time in PERIODS] >= 0
        Compensation[node in NODES, time in PERIODS]
    end

    # Storage-related variables (MWh)
    @variables m begin
        StorageCharge[node in NODES, stotech in STO_EN, time in PERIODS]     >= 0
        StorageDischarge[node in NODES, stotech in STO_EN, time in PERIODS]  >= 0
        StorageLevel[node in NODES, stotech in STO_EN, time in PERIODS]      >= 0
    end

    # ---------------------- EXPORT - IMPORT VARIABLES ----------------------------------
    # export and import to/from transmission system
    # from ACCEL report, the subscription of Vattenfall Eldistribution - SvK is ~3200MW ≈ 400MW per nodes
    # limited further by the import limit (in percentage)
    # for example, if import limit is 70%, then the maximum import is 0.7 * 3200 = 2240 MW

    # import from transmission nodes
    nodal_import = (subscription * import_limit) / length(TRANSMISSION_NODES)

    if configs.allow_export == :yes
        # if export is allowed, then negative import is allowed, meaning export
        @variables m begin
            -nodal_import <= ImportFrom[node in TRANSMISSION_NODES, time in PERIODS] <= nodal_import
        end
    else
        @variables m begin
            0 <= ImportFrom[node in TRANSMISSION_NODES, time in PERIODS] <= nodal_import
        end
    end

    powerflow_vars = make_powerflow_vars(modelinfo)

    vars = (; TotalCost, GenerationInvestment, StorageInvestment, CompensationInvestment,
            ActiveGeneration, ReactiveGeneration, Curtailment, Compensation,
            StorageCharge, StorageDischarge, StorageLevel, ImportFrom,
            powerflow_vars...)

    return vars
end
