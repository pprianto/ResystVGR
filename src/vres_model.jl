function vres_constraints_GlobalEnergyGIS(modelinfo, gis_limits)
    (; m, sets, vars) = modelinfo
    (; NODES) = sets

    vres_sets = vres_sets_vgr()
    (; NWOFF_NODES, FWOFF_NODES, inland_techs, offshore_wind_projects) = vres_sets

    # onshore and pv ground limits - based on Niclas GIS
    create_gis_capacity_constraints!(m, vars, NODES, inland_techs, gis_limits)

    # near shore offshore wind limits capacity limits
    create_gis_capacity_constraints!(m, vars, NWOFF_NODES, [:NWOFF], gis_limits)

    # Fix variables for nodes not eligible for near shore offshore wind
    not_nwoff = setdiff(NODES, NWOFF_NODES)
    fix_offshore_variables!(vars, sets, not_nwoff, :NWOFF)

    # Generate constraints using vindbrukskollen for far offshore wind limits
    for (project_name, project_data) in offshore_wind_projects
        create_offshore_wind_constraint!(m, vars, project_data)
    end

    # far shore offshore wind could only be invested in above presumed nodes
    not_fwoff = setdiff(NODES, FWOFF_NODES)
    fix_offshore_variables!(vars, sets, not_fwoff, :FWOFF)

    return NWOFF_NODES, FWOFF_NODES
end

# Helper function to create capacity limit constraints with GIS limits
function create_gis_capacity_constraints!(m, vars, nodes, techs, gis_limits)
    (; GenerationInvestment) = vars
    for node in nodes, tech in techs
        @constraint(m,
            GenerationInvestment[node, tech] <= get(gis_limits, (node, tech), 0.0)
        )
    end
end

# Helper function to fix variables for non-eligible nodes
function fix_offshore_variables!(vars, sets, nodes, tech_symbol)
    (; GenerationInvestment, ActiveGeneration, ReactiveGeneration) = vars
    (; PERIODS) = sets
    isempty(nodes) && return
    
    for node in nodes
        fix(GenerationInvestment[node, tech_symbol], 0.0; force=true)

        for time in PERIODS
            fix(ActiveGeneration[node, tech_symbol, time], 0.0; force=true)
            fix(ReactiveGeneration[node, tech_symbol, time] , 0.0; force=true)
        end
    end
end

# function to create offshore wind capacity constraints
function create_offshore_wind_constraint!(m, vars, project_data)
    (; GenerationInvestment) = vars
    existing_generation = m[:existing_generation]

    @constraint(m,
        sum(existing_generation[node, :FWOFF] + GenerationInvestment[node, :FWOFF] 
            for node in project_data.nodes) <= project_data.capacity_mw
    )
end


function vres_sets_vgr()
    vänern_nodes = [
        # :TAN1, :GBG1, :GBG5, :ORU1, :LYS1,
        :AMA2, :LID1, :GOT4, :GOT3, :MEL3, :AMA1, :MRS1,      # Vänern
        # :VAR1, :TOR2,      # no shore nearby, offshore not possible
        # :TIB1, :HJO1,      # Vättern                      
    ]
    westcoast_nodes = [:TAN1, :GBG1, :GBG5, :ORU1, :LYS1]
    inland_techs = [:WON, :PVTRACK, :PVROOF]

    NWOFF_NODES = [westcoast_nodes; vänern_nodes]   # near shore offshore wind

    # Define offshore wind projects with their node connections and capacity limits. Connections according to:
    # https://www.lansstyrelsen.se/vastra-gotaland/miljo-och-vatten/energi--och-klimatomstallning/havsbaserad-vindkraft.html
    # Viable projects are Poseidon, Mareld, Vidar and Västvind. Heimdall, Gamma are not confirmed yet.
    # https://projekt.vattenfall.se/vindprojekt/havsbaserad-vindkraft/vidar
    # https://projekt.vattenfall.se/vindprojekt/havsbaserad-vindkraft/poseidon/
    offshore_wind_projects = Dict(
        # Individual projects
        :Vidar => (nodes = [:TAN1, :TAN2], capacity_mw = 2000),
        :Gamma => (nodes = [:LYS1, :LYS2], capacity_mw = 2500),
        # :Heimdall => (nodes = [:STR2, :STR3], capacity_mw = 1000),
        # :Mareld => (nodes = [:LYS1, :LYS2], capacity_mw = 2500),
        # :Poseidon => (nodes = [:STE1], capacity_mw = 1400),
        :Mareld_Poseidon => (nodes = [:ORU1, :STE1], capacity_mw = 3500), # combined project, can connect to either Lysekil or Stenungsund
        :Västvind => (nodes = [:GBG1, :GBG4, :GBG5], capacity_mw = 1000),
    )

    # based on RISE report and VGR websites
    # https://www.lansstyrelsen.se/vastra-gotaland/miljo-och-vatten/energi--och-klimatomstallning/havsbaserad-vindkraft.html

    # Collect all eligible FWOFF nodes
    FWOFF_NODES = reduce(vcat, [project_data.nodes for project_data in values(offshore_wind_projects)])      

    return (; NWOFF_NODES, FWOFF_NODES, inland_techs, offshore_wind_projects)
end

