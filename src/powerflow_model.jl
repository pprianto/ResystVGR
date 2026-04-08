function make_powerflow_vars(modelinfo)
    (; m, sets, parameters, configs) = modelinfo
    (; NODES, PERIODS, LINES) = sets
    (; lines_props) = parameters
    (; nomV, line_limit) = configs

    # ---------------------- VOLTAGE VARIABLES ------------------------------------------
    # voltage nominal and angles (in kV for voltage magnitude, radians for angle)
    # first nodes is excluded since it is considered slack bus
    # voltage bounds
    v_min = 0.95 * nomV
    v_max = 1.05 * nomV
    angle_limit = π  # π radian which means 180 degrees
    constant_for_line_constraint = 0.9 # constant for limiting the solution space for linearised power flow
    
    @variables m begin
        v_min <= NodalVoltage[node in NODES, time in PERIODS] <= v_max
        -angle_limit <= NodalAngle[node in NODES, time in PERIODS] <= angle_limit
    end

    # ---------------------- POWER FLOW VARIABLES ---------------------------------------
    # applied to lines and node from/to sets
    # since the flow can only be exist in power lines
    # but nodes still need to be taken into account
    # refer to Allard et el. (2020) eq. (4) - (7)
    # https://doi.org/10.1016/j.apenergy.2020.114958

    # line limits
    line_limits = Dict(line => line_limit * lines_props[line][:s_max] for line in LINES)
    
    @variable(m, ActiveFlow[line in LINES, time in PERIODS])
    @variable(m, ReactiveFlow[line in LINES, time in PERIODS])
    
    # line variable limits
    for line in LINES, time in PERIODS
        set_lower_bound(ActiveFlow[line, time], -constant_for_line_constraint * line_limits[line])
        set_upper_bound(ActiveFlow[line, time], constant_for_line_constraint * line_limits[line])
        set_lower_bound(ReactiveFlow[line, time], -constant_for_line_constraint * line_limits[line])
        set_upper_bound(ReactiveFlow[line, time], constant_for_line_constraint * line_limits[line])
    end

    vars = (; NodalVoltage, NodalAngle, ActiveFlow, ReactiveFlow)
    return vars
end


function powerflow_constraints(modelinfo)
    (; m, sets, parameters, vars, configs) = modelinfo
    (; TRANSMISSION_NODES, PERIODS, LINES, NODE_FROM, NODE_TO) = sets
    (; NodalVoltage, NodalAngle, ActiveFlow, ReactiveFlow) = vars
    (; lines_props) = parameters
    (; nomV, line_limit) = configs

    # Import bus voltage and angle over time, assumes all transmission nodes are voltage controlled buses
    # considering the voltage magnitude and angle in transmission system are close to nominal values
    # with the first entry is the slack bus
    # the 7 other import buses have variable nodal angle

    slack_bus = TRANSMISSION_NODES[1]  # slack bus considered as first transmission node entry
    
    for time in PERIODS
        for node in TRANSMISSION_NODES
            fix(NodalVoltage[node, time], nomV, force=true)
        end

        fix(NodalAngle[slack_bus, time], 0.0, force=true)
    end

    # ---------------------- LINEARISED POWER FLOW LIMITS -------------------------------
    # refer to Allard et el. (2020) eq. (8)
    # https://doi.org/10.1016/j.apenergy.2020.114958
    # apparent power limits have been defined in Variables - power flow variables
    # power flow equations

    constant_for_line_constraint = 0.9 # constant for limiting the solution space for linearised power flow

    # constraints definition
    # for collecting in results
    p_flow = AxisArray(ConstraintRef, LINES, PERIODS)
    q_flow = AxisArray(ConstraintRef, LINES, PERIODS)
    s_limit_Q1 = AxisArray(ConstraintRef, LINES, PERIODS)
    s_limit_Q2 = AxisArray(ConstraintRef, LINES, PERIODS)
    s_limit_Q3 = AxisArray(ConstraintRef, LINES, PERIODS)
    s_limit_Q4 = AxisArray(ConstraintRef, LINES, PERIODS)

    # Line parameters and thermal limits for each line
    line_parameters = Dict{Symbol, NamedTuple}()
    for line in LINES
        G = lines_props[line][:g_total]
        B = lines_props[line][:b_total]
        s_max_limit = sqrt(2) * line_limit * lines_props[line][:s_max]
        line_parameters[line] = (G=G, B=B, s_max_limit=s_max_limit)
    end

    for (idx, line) in enumerate(LINES)
        line_params = line_parameters[line]
        node_from = NODE_FROM[idx]
        node_to = NODE_TO[idx]
        
        for time in PERIODS
            # active flow
            p_flow[line, time] = @constraint(m,
                ActiveFlow[line, time] == nomV * (line_params.G * (NodalVoltage[node_from, time] - NodalVoltage[node_to, time]) + 
                                        nomV * line_params.B * (NodalAngle[node_to, time] - NodalAngle[node_from, time]))
            )

            # reactive flow
            q_flow[line, time] = @constraint(m,
                ReactiveFlow[line, time] == nomV * (line_params.B * (NodalVoltage[node_to, time] - NodalVoltage[node_from, time]) + 
                                            nomV * line_params.G * (NodalAngle[node_to, time] - NodalAngle[node_from, time]))
            )

            # voltage angle difference limits (in radians)
            # assumed to be limited by 30 deg or 0.5 radians
            @constraint(m,
                NodalAngle[node_from, time] - NodalAngle[node_to, time] <= 0.5
            )

            @constraint(m,
                NodalAngle[node_from, time] - NodalAngle[node_to, time] >= -0.5
            )

            # linearised thermal constraints
            s_limit_Q1[line, time] = @constraint(m,
                ActiveFlow[line, time] + ReactiveFlow[line, time] <= constant_for_line_constraint * line_params.s_max_limit
            )

            s_limit_Q2[line, time] = @constraint(m,
                ActiveFlow[line, time] - ReactiveFlow[line, time] <= constant_for_line_constraint * line_params.s_max_limit
            )

            s_limit_Q3[line, time] = @constraint(m,
                -ActiveFlow[line, time] + ReactiveFlow[line, time] <= constant_for_line_constraint * line_params.s_max_limit
            )

            s_limit_Q4[line, time] = @constraint(m,
                -ActiveFlow[line, time] - ReactiveFlow[line, time] <= constant_for_line_constraint * line_params.s_max_limit
            )
        end
    end

    constraints = (; p_flow, q_flow)

    return constraints
end
