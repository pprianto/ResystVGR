# Empty AxisArray constructor of given type and axes
AxisArray(T::Type, axes...) = AxisArray(Array{T}(undef, map(length, axes)...), axes...)

"Read model options from TOML config file and convert to NamedTuple"
function load_model_options(config_fn::String)
    current_dir = @__DIR__
    input_dir = joinpath(current_dir, "inputdata")
    results_dir = joinpath(current_dir, "results")

    config_dict = TOML.parsefile(joinpath(current_dir, "configs", "$config_fn.toml"))

    # Convert all strings to symbols except for file_name
    keys_symbols = Symbol.(keys(config_dict))
    values_symbols = [typeof(v) == String && k != "file_name" ? Symbol(v) : v for (k,v) in config_dict]

    configs = (; current_dir, input_dir, results_dir, zip(keys_symbols, values_symbols)...)
    return configs
end

"Read .xlsx file and convert first sheet to DataFrame"
function get_df(data)
    df = XLSX.readxlsx(data)
    sheet_name = XLSX.sheetnames(df)
    first_sheet = sheet_name[1]
    
    df_data = DataFrame(XLSX.readtable(data, first_sheet, infer_eltypes=true)) 

    return df_data
end

"Read either xls or csv file as dataframe"
function read_file(file_path)
    if endswith(file_path, ".xlsx") || endswith(file_path, ".xls")
        df = get_df(file_path)
    elseif endswith(file_path, ".csv")
        df = CSV.read(file_path, DataFrame)
    else
        error("Unsupported file format. Please provide XLS or CSV file.")
    end

    string_columns = names(df, col -> occursin("String", string(eltype(df[!, col]))))

    for col in string_columns
        df[!, col] = [ismissing(val) ? missing : String(val) for val in df[!, col]]
    end

    return df
end

"Filter df based on tech carrier"
function carrier_subsets(tech_df, excluded_tecs)

    if any(col -> any(x -> contains(string(x), "EL"), col), eachcol(tech_df))
        el_tech = filter(row -> occursin("EL", row.Carrier), tech_df)
        el_subset = Symbol.(el_tech.Tech)
    end

    el_subset = setdiff(el_subset, excluded_tecs)

    if any(col -> any(x -> contains(string(x), "HEAT"), col), eachcol(tech_df))
        heat_tech = filter(row -> occursin("HEAT", row.Carrier), tech_df)
        heat_subset = Symbol.(heat_tech.Tech)
    end

    heat_subset = setdiff(heat_subset, excluded_tecs)

    if any(col -> any(x -> contains(string(x), "H2"), col), eachcol(tech_df))    
        h2_tech = filter(row -> occursin("H2", row.Carrier), tech_df)
        h2_subset = Symbol.(h2_tech.Tech)
    end

    h2_subset = setdiff(h2_subset, excluded_tecs)

    return el_subset, heat_subset, h2_subset
end


function process_pp(pp_df)
    
    tech_names = Dict(
        "wind" => "WON",            # change into onshore wind
        "hydro" => "HYD",           # hydro
        "waste;biomass" => "WCHP",  # waste CHP, in Borås
        "biomass" => "HBW",       # biomass heat only boiler, in Trollhättan
        "electric" => "EB",         # electric heat only boiler, in Trollhättan
        "biofuel" => "GB",        # gas heat only boiler, in Trollhättan
        "solar" => "PVTRACK",        # utility scale PV
        "gas;oil" => "CCGT",        # combined cycle gas turbine, Rosenlundsverket
        "gas;wood;oil" => "CCGT",   # combined cycle gas turbine, Rya kraftverk
        "oil" => "GTSC"             # gas turbine simple cycle, Stenungsund kraftverk
    )

    pp_df[!, :tech] = [tech_names[name] for name in pp_df[:, :tech]]

    # replace missing values in installed capacity column with 0.0
    power_cols = [:el_MW, :heat_MW]

    for col in power_cols
        pp_df[!, col] = replace(pp_df[:, col], missing => 0.0)
    end

    # chp capacity is set according to the el power
    # heat MW of chp is set to 0
    pp_changed = findall(x -> x in [
                                85127533,       # Borås
                                51038647,       # Rosenlundsverket
                                917521835,      # Rya in Göteborg
                                15009765,       # Stenungsund
                                ], 
                                pp_df.pp_id)
    pp_df[pp_changed, :heat_MW] .= 0.0

    # Stenungsund decommissionioned, el power set to 0
    pp_df[pp_df.pp_id .== 15009765, :el_MW] .= 0.0

    # hydro capacities adjusted based on
    # https://vattenkraft.info/
    # crosscheck with vattenfall or relevant websites
    hydro_change = findall(x -> x in [
                                    88144184,   # olidans
                                    10884545,   # vargons
                                    528968206,  # kungfors
                                    125589869   # lilla edet
                                    ],
                            pp_df.pp_id
    )

    # ordered based on appearance in the rows
    pp_df[hydro_change, :el_MW] .= [
                                    3.0,    # kungfors
                                    91.0,   # olidans
                                    35.0,   # vargons
                                    46.0    # lilla edet
                                ]

    return pp_df
end


function parse_potentials(substations_df, pp_df, solar_data, wind_data)

    # Define the potential for each technology at each node
    nodal_wind_potential = Dict{Tuple{Symbol, Symbol}, Float64}()
    nodal_offshore_potential = Dict{Tuple{Symbol, Symbol}, Float64}()
    nodal_solar_potential = Dict{Tuple{Symbol, Symbol}, Float64}()
    nodal_rooftop_potential = Dict{Tuple{Symbol, Symbol}, Float64}()

    # fill the potential Dicts
    # unit conversion from GW to MW
    for (i, node_id) in enumerate(substations_df[!, :node_id])
        nodal_wind_potential[(Symbol(node_id), fill(:WON, length(substations_df[!, :node_id]))[i])] = wind_data["capacity_onshoreA"][i] * 1000
        nodal_offshore_potential[(Symbol(node_id), fill(:NWOFF, length(substations_df[!, :node_id]))[i])] = wind_data["capacity_offshore"][i] * 1000
        nodal_solar_potential[(Symbol(node_id), fill(:PVTRACK, length(substations_df[!, :node_id]))[i])] = solar_data["capacity_pvplantA"][i] * 1000
        nodal_rooftop_potential[(Symbol(node_id), fill(:PVROOF, length(substations_df[!, :node_id]))[i])] = solar_data["capacity_pvrooftop"][i] * 1000
    end

    # remove offshore nodes with potential less than 1 MW
    for key in keys(nodal_offshore_potential)
        if nodal_offshore_potential[key] < 1
            delete!(nodal_offshore_potential, key)
        end
    end

    # list of nodes that are not on the western shore
    # these nodes are within Vanern and Vattern lakes
    # but for now Vättern is not included
    # manually based on GIS data
    NON_SHORE = [
                # :AMA2,      # Vänern
                # :LID1,      # Vänern
                # :GOT4,      # Vänern
                # :GOT3,      # Vänern
                # :MEL3,      # Vänern
                :VAR1,      # no shore nearby, offshore not possible
                # :AMA1,      # Vänern
                :TOR2,      # no shore nearby, offshore not possible
                :TIB1,      # Vättern
                # :MRS1,      # Vänern
                :HJO1,      # Vättern
    ]

    # remove potential of nodes that are not on the shore
    for key in collect(keys(nodal_offshore_potential))
        for node in NON_SHORE
            if key[1] == node
                delete!(nodal_offshore_potential, key)
            end
        end
    end

    # combine all potentials into one large dict
    combined_potential = merge(
                            nodal_wind_potential,
                            nodal_offshore_potential,
                            nodal_solar_potential,
                            nodal_rooftop_potential
    )

    # work with the existing power plant data from OSM
    # calculate the installed capacity                           
    pp_df[!, "total_MW"] = pp_df.el_MW .+ pp_df.heat_MW
    aggregated_pp_df = combine(groupby(pp_df, [:node_id, :tech]), :total_MW => sum => :sum_MW)

    capacity_lower_bounds = Dict{Tuple{Symbol, Symbol}, Float64}()
    for row in eachrow(aggregated_pp_df)
        capacity_lower_bounds[(Symbol(row.node_id), Symbol(row.tech))] = row.sum_MW
    end

    combined_potential_update = deepcopy(combined_potential)

    # Update potentials with the highest values
    # based on GIS or OSM data
    for key in keys(combined_potential_update)
        if haskey(capacity_lower_bounds, key)
            gis_value = combined_potential_update[key]
            osm_value = capacity_lower_bounds[key]
            if osm_value > gis_value
                combined_potential_update[key] = osm_value
            end
        end
    end

    # change very small potentials to 0
    # round potentials to 2 digits
    for (key, value) in combined_potential_update
        if value <= 1.0
            combined_potential_update[key] = 0.0  # Replace smaller than 1 to 0
        end
        combined_potential_update[key] = round(value, digits=2)
    end

    # return results to be implemented in model
    return capacity_lower_bounds, combined_potential_update

end


function new_industries_el_demand(el_demand_df, configs)
    # new load in Torslanda and Mariestad
    # NOVO 1.17 TWh Torslanda
    # NOVO 2.25 TWh Mariestad

    el_demand_df[!, "GBG1"] .+= 1170000/8760    # NOVO Torslanda
    el_demand_df[!, "MRS1"] .+= 2250000/8760    # NOVO Mariestad

    return el_demand_df
end


function round_df_floats!(df::DataFrame, precision)
# Function to round float columns
    for col in names(df)
        if eltype(df[!, col]) == Float64
            df[!, col] .= round.(df[!, col], digits=precision)
        end
    end
end


function round_df_floats!(nt::NamedTuple, precision)
    for df in nt
        for col in names(df)
            if eltype(df[!, col]) == Float64
                df[!, col] .= round.(df[!, col], digits=precision)
            end
        end
    end
end

"""
Function to create admittance matrix of the network
adapted from the JuMP documentation
https://jump.dev/JuMP.jl/stable/tutorials/applications/optimal_power_flow/
"""
function admittance_matrix(lines_df)

    # get number of nodes and lines
    max_node_num = max(
                        maximum(lines_df.station_from), 
                        maximum(lines_df.station_to)
                    )

    min_node_num = min(
                        minimum(lines_df.station_from), 
                        minimum(lines_df.station_to)
                    )

    no_nodes = max_node_num
    no_lines = size(lines_df, 1)
    
    # arrays for row/column
    nodes = [i for i in min_node_num : max_node_num]


    # construct incidence matrix
    incidence_matrix = SparseArrays.sparse(
                            lines_df.station_from,      # vertice
                            1:no_lines,                 # edge
                            1,                          # to
                            no_nodes,                   # row size
                            no_lines                    # from size
                            ) +
                        SparseArrays.sparse(
                            lines_df.station_to,        # vertice
                            1:no_lines,                 # edge
                            -1,                         # from
                            no_nodes,                   # row size
                            no_lines                    # from size
                        )

    # line impedance data in complex
    z_total = lines_df.r_total .+ im * lines_df.x_total

    # admittance matrix, change from SparseArrays to Array
    Ybus = incidence_matrix * SparseArrays.spdiagm(1 ./ z_total) * incidence_matrix'
    Ybus = Array(Ybus)

    # conductance and susceptance matrix    
    G = real(Ybus)
    B = imag(Ybus)

    # change to dataframe for later uses (parameters in the model)
    Ybus = DataFrame(Ybus, Symbol.(nodes))
    G = DataFrame(G, Symbol.(nodes))
    B = DataFrame(B, Symbol.(nodes))

    return Ybus, G, B
end

"""
Function to add impendances and Slim to the raw OSM lines

values of R/km, X/km, and I_max in kA is currently based on
https://pandapower.readthedocs.io/en/latest/std_types/basic.html#lines
type 490-AL1/64-ST1A 110.0
susceptance is not modelled
use short line model
"""
function lines_properties(lines_df, configs)
    (; ccc, nomV, line_limit) = configs

    # values assumed to be uniform
    r_per_km = 0.042 # Ω / km
    x_per_km = 0.36 # Ω / km
    z_per_km = r_per_km + im * x_per_km # Ω / kmB
    max_i_ka = ccc / 1e3 # current carrying capacity in kA

    # resistance, reactance, impedance columns
    lines_df[!, :r_per_km] .= r_per_km
    lines_df[!, :x_per_km] .= x_per_km
    lines_df[!, :z_per_km] .= z_per_km

    # impedance due to parallel lines and length
    lines_df[!, :r_line] = [1 / sum(1/row[:r_per_km] for _ in 1:row[:circuits]) for row in eachrow(lines_df)]
    lines_df[!, :x_line] = [1 / sum(1/row[:x_per_km] for _ in 1:row[:circuits]) for row in eachrow(lines_df)]
    lines_df[!, :z_line] = [1 / sum(1/row[:z_per_km] for _ in 1:row[:circuits]) for row in eachrow(lines_df)]
    lines_df[!, :z_total] = lines_df[!, :z_line] .* lines_df[!, :length_km]

    # admittance of each lines
    # negative due to the convention in admittance matrix Y_ij equal to negative of admittance each line -y_ij
    lines_df[!, :y_total] = -1 ./ (lines_df[!, :z_total])

    # split into real imag parts for r,x,g,b
    lines_df[!, :r_total] = real(lines_df[!, :z_total])
    lines_df[!, :x_total] = imag(lines_df[!, :z_total])

    lines_df[!, :g_total] = real(lines_df[!, :y_total])
    lines_df[!, :b_total] = imag(lines_df[!, :y_total])

    # thermal limits
    lines_df[!, :max_i_ka] .= max_i_ka
    lines_df[!, :s_max] = sqrt(3) .* nomV .* lines_df[!, :max_i_ka] .* lines_df[!, :circuits]
    lines_df[!, :s_max_model] = sqrt(3) .* nomV .* lines_df[!, :max_i_ka] .* lines_df[!, :circuits] .* line_limit

    round_df_floats!(lines_df, 3)

    return lines_df
end


function lines_prep(lines_df)

    lines = lines_df[!, [:lines_id, :node_from, :node_to, :g_total, :b_total, :s_max]]
    lines[!, :arcs_fr] = [(row.lines_id, row.node_from, row.node_to) for row in eachrow(lines)]
    lines[!, :arcs_to] = [(row.lines_id, row.node_to, row.node_from) for row in eachrow(lines)]

    # Power system sets
    LINES = Symbol.(lines[!, :lines_id])         # power lines set
    NODE_FROM = Symbol.(lines[!, :node_from])    # set of node from of the line
    NODE_TO = Symbol.(lines[!, :node_to])        # set of node to of the line
    ARCS_FR = Symbol.(lines[!, :arcs_fr])        # combined set of lines - nodes
    ARCS_TO = Symbol.(lines[!, :arcs_to])

    lines_props = Dict(Symbol.(lines[!, :lines_id]) .=> NamedTuple.(eachrow(lines[!, Not(:lines_id)])))

    lines_sets = (; 
                LINES,
                NODE_FROM, 
                NODE_TO, 
                ARCS_FR,
                ARCS_TO
            )

    return lines_sets, lines_props
end


"Convert DataFrame to AxisArray, sort column names to avoid inconsistent ordering in input files."
function df_to_axisarray(df)
    row_names = df[!, 1]
    # Remove redundant hour column to avoid sorting issues when we take Matrix(df).
    if "hour" in names(df)
        select!(df, Not(:hour))
    end

    col_names = Symbol.(names(df)) |> sort
    select!(df, col_names)

    return AxisArray(Matrix(df), row_names, col_names)
end


"Convert vehicle DataFrame to AxisArray, sort column names to avoid inconsistent ordering in input files."
function vehicle_df_to_axisarray(df)
    df[!, 2:end] = convert.(Int64, df[!, 2:end])
    df.type = Symbol.(uppercase.(df.type))

    select!(df, Not(:type))

    row_names = [:CARS; :LT; :HT; :BUS]
    col_names = Symbol.(names(df)) |> sort

    return AxisArray(Matrix(df), row_names, col_names)
end
