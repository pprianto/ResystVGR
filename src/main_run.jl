function run_model(solver, config_fn = "default")
    configs = load_model_options(config_fn)
    !isdir(configs.results_dir) && mkpath(configs.results_dir)
    
    println("\nCONFIGURATION SUMMARY:")
    print_configs(configs)

    println("\nSOLVER PARAMETERS:")
    m = set_solver(solver)
    inputs = read_input_data(configs)

    println("\nMODEL GENERATION:")
    @time "Sets"  sets, parameters = make_sets(inputs, configs)

    modelinfo = (; m, sets, parameters, inputs, configs)
    @time "Vars"  vars = make_variables(modelinfo)

    modelinfo = (; modelinfo..., vars)
    @time "All constraints"  modelinfo = make_constraints(modelinfo)

    println("\nSOLVING MODEL...")
    solvetime = @elapsed optimize!(m)
    timetext = solvetime >= 3600 ? "$(solvetime/3600) hours" : "$(solvetime/60) min"

    println("---------------------------------------------")
    println("Time needed to solve = $timetext")
    println("---------------------------------------------")

    return modelinfo
end


function print_configs(configs)
    (; demand, subscription, potential, ev_V2G, share_V2G, file_name, allow_export, ccc, el_heat_tax, emission_fee) = configs

    increase = (demand == :alpha) ? "medium" : "high"
    import_capacity = (subscription < 4400) ? "Low" : (subscription > 4400) ? "High" : "Medium"
    re_potential = (potential == :gis) ? "GIS" : "Eresan"
    v2g_info = (ev_V2G == :yes) ? "$(ev_V2G) with share of $(share_V2G)" : "$(ev_V2G)"

    println("Case name: $(file_name)")
    println("Demand increase scenario: $(increase)")
    println("Possibility for export: $(allow_export)")
    println("RE potential from $(re_potential)")
    println("$(import_capacity) import subcsription with limit of: $(subscription) MW")
    println("Assumed power lines CCC: $(ccc) A")
    println("Electricity to heat tax: $(el_heat_tax) €/MWh")
    println("Emission fee: $(emission_fee) €/tonneCO2")
    println("Possibility for V2G: $(v2g_info)")

    return nothing
end


function set_solver(solver)
    if solver == :gurobi
        # Workaround for bug:
        # https://discourse.julialang.org/t/how-can-i-clear-solver-attributes-in-jump/57953
        optimizer = optimizer_with_attributes(
                Gurobi.Optimizer,
                "Threads" => 24,                     # shutoff for now, memory limit?
                # "BarHomogeneous" => 1,              # 1: enabled
                "Crossover" => 0,                  # 0: disabled
                # "CrossoverBasis" => 0,                  # 0: disabled
                # "BarConvTol" => 1e-6,                  # 0: disabled
                # "BarOrder" => 1,                  # -1=auto, 0=Approximate Minimum Degree, 1=Nested Dissection
                "Method" => 2,                     # -1: auto, 1: dual simplex, 2: barrier
                # "Presolve" => 1,                    # 2: aggressive
                # "PreSparsify" => 2,                    # 2: aggressive
                # "NumericFocus" => 2,
                # "NodefileStart" => 0.5,
                # "Aggregate" => 2,
                # "MemLimit" => 250,
                "ScaleFlag" => 2,
                # "DisplayInterval" => 300,
        )
        
        # set_silent(model)
        # log_file = joinpath(configs.results_dir, "1year_log.txt")
        # set_optimizer_attribute(model, "LogFile", log_file)

    elseif solver == :copt
        optimizer = optimizer_with_attributes(
                COPT.Optimizer,
                "LpMethod" => 2,        # -1=simple auto, 1=Dual simplex, 2=Barrier, 3=Crossover, 4=Concurrent, 5=heuristic auto, 6=PDLP
                "BarIterLimit" => 1e9,
                # "BarHomogeneous" => 1,  # 0=no, 1=yes
                # "BarOrder" => 1,       # -1=auto, 0=Approximate Minimum Degree, 1=Nested Dissection
                # "BarStart" => 2,       # -1=auto, 0=Asimple, 1=Mehrotra, 2=Modified Mehrotra
                # "Dualize" => 1,
                "Crossover" => 0,       # 0=no, 1=yes
                "Scaling" => 1,         # -1=auto, 0=no, 1=yes
                # "Presolve" => 4,        # -1=auto, 0=off, 1=fast, 2=normal, 3=aggressive, 4=unlimited (until nothing else possible)
                # "GPUMode" => 1,       # 0=CPU, 1=GPU (used with PDLP algoritm, only for machine 41)
                # "PDLPTol" => 1e-7,
                "Threads" => 24,
                "BarThreads" => 24,
                "SimplexThreads" => 24,
        )

    elseif solver == :highs
        optimizer = optimizer_with_attributes(
            HiGHS.Optimizer,
            # "threads" => 32,
            "presolve" => "on",
            "solver" => "ipm",          # simplex, ipm=barrier, pdlp
            "run_crossover" => "on",
            "ranging" => "on",
        )

    else
        @error "No solver named $(solver)."
    end

    m = direct_model(optimizer)

    return m
end


function query_solutions(modelinfo)
    (;  m, configs) = modelinfo

    if termination_status(m) == MOI.OPTIMAL
        println("---------------------------------------------")
        println("The solver termination status is $(termination_status(m))")
        println("Optimal solution found")
        
    else
        println("---------------------------------------------")
        println("The solver termination status is $(termination_status(m))")
        println("No optimal solution found")
        
    end

    cost = objective_value(m)

    if cost >= 1e6
        println("The system cost is $(cost / 1e6) M€.")
    else
        println("The system cost is $(cost) M€.")
    end

    # Convert the model variables into DataFrames
    costs = convert_costs(modelinfo)
    generation_capacities, storage_capacities = convert_invs(modelinfo)
    generation_dispatch, storage_dispatch = convert_dispatch(modelinfo)
    conversion_demands = convert_ptx(modelinfo)
    export_import = convert_expimp(modelinfo)
    voltage_solutions = convert_voltage(modelinfo)
    nodal_el = convert_nodal_el(modelinfo)
    nodal_reactive = convert_nodal_reactive(modelinfo)
    nodal_heat = convert_nodal_heat(modelinfo)
    nodal_h2 = convert_nodal_h2(modelinfo)
    nodal_marginal_costs = convert_mc(modelinfo)
    lines_solutions = convert_lines(modelinfo)

    results = (; costs, generation_capacities, storage_capacities, generation_dispatch,
            storage_dispatch, export_import, conversion_demands, voltage_solutions,
            nodal_el, nodal_reactive, nodal_heat, nodal_h2, nodal_marginal_costs, lines_solutions)

    if configs.use_EV == :yes
        ev_solutions = convert_ev(modelinfo)
        results = (; results..., ev_solutions)
    end

    round_df_floats!(results, 4)

    return results
end


function save_variables(results, modelinfo)
    (; configs) = modelinfo
    (; results_dir, file_name) = configs

    # Save decision variables in CSV
    for (var_name, result) in pairs(results)
        suffix = lowercase(string(var_name))
        CSV.write(joinpath(results_dir, "$(file_name)_$(suffix).csv"), result; delim=";")
    end

    return nothing
end


function run_scenario(config_path, solver=:copt)
    modelinfo = run_model(solver, config_path);
    results = query_solutions(modelinfo);
    if modelinfo.configs.save == :yes
        save_variables(results, modelinfo);
    end
end

