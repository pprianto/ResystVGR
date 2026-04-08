"Define sets and parameters."
function make_sets(inputs, configs)
    (; price, grid_infra, tech_props, demand) = inputs
    (; first_hour, last_hour) = configs
    (; results_dir, file_name) = configs

    # ---------------------- MODEL PARAMETERS / INPUT DATA ------------------------------

    PERIODS = first_hour:last_hour

    # DEMAND
    eldemand_data = demand.el[PERIODS, :]
    heatdemand_data = demand.heat[PERIODS, :]
    h2demand_data = demand.h2[PERIODS, :]

    # electricity prices in €/MWh 
    price_SE3 = price.SE3
    price_NO1 = price.NO1
    price_DK1 = price.DK1         

    # GENERATION AND STORAGE TECHNOLOGY PROPERTIES
    # Dict of tech properties, keys are tech names, values are properties in df format
    # based on Danish Energy Agency catalogues
    # https://ens.dk/en/analyses-and-statistics/technology-catalogues
    gentech_data = Dict(Symbol.(tech_props.gen[!, :Tech]) .=> NamedTuple.(eachrow(tech_props.gen[!, Not(:Tech)])))
    stotech_data = Dict(Symbol.(tech_props.sto[!, :Tech]) .=> NamedTuple.(eachrow(tech_props.sto[!, Not(:Tech)])))

    # Reactive power demand
    reactive_demand = demand.reactive

    # Extract power lines sets and properties
    lines_df = lines_properties(grid_infra.lines, configs)
    lines_sets, lines_props = lines_prep(lines_df)

    # save the lines properties to csv
    if configs.save == :yes
        CSV.write(joinpath(results_dir, "$(file_name)_lines_props.csv"), lines_df; delim=";")
    end

    (;  LINES, NODE_FROM, NODE_TO) = lines_sets

    # ---------------------- MODEL SETS AND SUBSETS -------------------------------------

    NODES = Symbol.(grid_infra.subs[!, :node_id]) |> sort   # node set
    GEN_TECHS = Symbol.(tech_props.gen[!, :Tech])           # generation tech set
    STO_TECHS = Symbol.(tech_props.sto[!, :Tech])           # storage tech set

    # Coastal municipalities
    # for offshore wind and sea water hp eligibility
    # Strömstad, Tanum, Lysekil, Orust, Stenungsund, Kungälv, Göteborg
    coast_municipalities = ["GBG"; "KUN"; "STE"; "ORU"; "LYS"; "TAN"; "STR"]
    coast_subs_df = filter(row -> any(startswith(row.node_id, prefix) for prefix in coast_municipalities), grid_infra.subs)
    COAST_NODES = Symbol.(coast_subs_df.node_id)

    # Pit Thermal Storage is not feasible in Gothenburg

    gothenburg = ["GBG"]
    gbg_subs_df = filter(row -> any(startswith(row.node_id, prefix) for prefix in gothenburg), grid_infra.subs)
    GBG = Symbol.(gbg_subs_df.node_id)

    # GENERATION TECHNOLOGY SUBSETS
    # define techs to exclude from tech props
    # comment out means the tech is included in the model
    excluded_gentechs = [
        # :OCGT,      # ocgt
        # :CCGT,      # ccgt
        # :WCHP,      # waste chp
        # :WCCHP,     # biomass chp
        # :PEMFC,     # pem fuel cells
        # :WON,       # onshore wind
        # :NWOFF,     # near shore offshore wind
        # :FWOFF,     # far shore offshore wind
        # :PVROOF,    # rooftop pv
        # :PVTRACK,   # tracking ground pv
        # :HPAIR,     # air source heat pumps
        # :HBW,       # biomass boilers        
        # :EB,        # electric boilers
        # :GB,        # gas boilers
        # :EC,        # electrolyser (pemec)
        # :HYD        # hydropower
    ]

    excluded_stotechs = [
        # :PTES,      # pit seasonal
        # :TTES,      # large hot water tanks
        # :HST,       # hydrogen storage tanks
        # :LRC,       # hydrogen lined rock caverns
        # :LI_EN,     # energy component of lithium ion battery
        # :LI_CAP,    # power capacity component of lithium ion battery
    ]

    # carrier generation technologies subset
    EL_GEN, HEAT_GEN, H2_GEN = carrier_subsets(tech_props.gen, excluded_gentechs) 

    # carrier storage technologies subset
    EL_STO, HEAT_STO, H2_STO = carrier_subsets(tech_props.sto, excluded_stotechs)    

    # TRANSMISSION NODES SUBSETS
    trans_node = filter(row -> row.import_trans == true, grid_infra.subs)
    TRANSMISSION_NODES = Symbol.(trans_node.node_id)

    # SPECIFIC TECHNOLOGY SUBSETS
    # manually defined from excel file input
    CHP = [             # CHP
            :WCHP,     # waste chp
            :WCCHP,    # biomass chp
    ]

    FC = [              # fuel cells
            :PEMFC,     # pem fuel cells
    ]

    WIND = [
            :WON,        # onshore
            :NWOFF,      # near shore offshore
            :FWOFF,      # far shore offshore
    ]

    PV = [
            :PVROOF,   # rooftop/commercial pv
            :PVTRACK   # tracking utility PV
    ]

    VRES = [WIND; PV]

    HP = [
            :HPAIR,    # heat pumps air source
    ]

    BOILER = [
                :EB,   # electric boilers
                :GB,    # biogas boilers
                :HBW   # biomass heat only boiler
    ]
    
    EC = [
            :EC,
    ]

    # Batteries separated into energy and capacity components
    BAT_CAP = [
                :LI_CAP,        # lithium ion capacity component
    ]
    
    BAT_EN = [
                :LI_EN,         # lithium ion energy component
    ]

    # subsets of storages, excluding capacity components of batteries
    STO_EN = setdiff(STO_TECHS, BAT_CAP)

    sets = (; NODES, TRANSMISSION_NODES, COAST_NODES, GBG, GEN_TECHS, EL_GEN, HEAT_GEN, H2_GEN, 
            STO_TECHS, EL_STO, HEAT_STO, H2_STO, PERIODS, LINES, NODE_FROM, NODE_TO,
            CHP, FC, WIND, PV, VRES, HP, BOILER, EC, BAT_CAP, BAT_EN, STO_EN)

    parameters = (; price_SE3, price_NO1, price_DK1, gentech_data, stotech_data, eldemand_data,
            reactive_demand, heatdemand_data, h2demand_data, lines_props)

    return sets, parameters
end
