function read_input_data(configs)
    (; input_dir, results_dir, el_price_year, target_year, demand, file_name, profile_year, potential) = configs

    # electricity price
    elpris_df = read_file(joinpath(input_dir, "elpris_$(el_price_year).csv"))
    round_df_floats!(elpris_df, 2)

    # electrical infrastructure
    substations_df = read_file(joinpath(input_dir, "subs_final.csv"))
    lines_df = read_file(joinpath(input_dir, "lines_final.csv"))
    pp_df = read_file(joinpath(input_dir, "pp_final.csv"))
    pp_df = process_pp(pp_df)       # rename the tech according to the index sets

    round_df_floats!(substations_df, 3)
    round_df_floats!(pp_df, 3)

    # technology properties
    # assume 2050
    gen_tech_df = read_file(joinpath(input_dir, "gen_tech_$(target_year).csv"))
    sto_tech_df = read_file(joinpath(input_dir, "sto_tech_$(target_year).csv"))

    round_df_floats!(gen_tech_df, 3)
    round_df_floats!(sto_tech_df, 3)

    # demand data
    # currently in hourly period
    el_demand_df = read_file(joinpath(input_dir, "el_nodal_demand_$(demand).csv"))
    el_demand_df = new_industries_el_demand(el_demand_df, configs)
    heat_demand_df = read_file(joinpath(input_dir, "heat_nodal_demand_$(demand).csv"))
    h2_demand_df = read_file(joinpath(input_dir, "h2_nodal_demand_$(demand).csv"))

    # save new el demand after additional industry
    if configs.save == :yes
        CSV.write(joinpath(results_dir, "$(file_name)_el_nodal_demand_$(demand).csv"), el_demand_df; delim=";")
        CSV.write(joinpath(results_dir, "$(file_name)_heat_nodal_demand_$(demand).csv"), heat_demand_df; delim=";")
        CSV.write(joinpath(results_dir, "$(file_name)_h2_nodal_demand_$(demand).csv"), h2_demand_df; delim=";")
    end
    
    round_df_floats!(el_demand_df, 3)
    round_df_floats!(heat_demand_df, 3)
    round_df_floats!(h2_demand_df, 3)

    # Demand profiles in axis arrays
    el = df_to_axisarray(el_demand_df)
    heat = df_to_axisarray(heat_demand_df)
    h2 = df_to_axisarray(h2_demand_df)

    # ---------------------- POWER FACTOR, FOR REACTIVE POWER DEMAND --------------------
    # Assuming the reactive demand corresponds to 0.99 cos phi
    demand_cos_ϕ = 0.99                             # assumed load power factor
    demand_sin_ϕ = sqrt.(1 .- demand_cos_ϕ.^2)
    reactive = el .* demand_sin_ϕ ./ demand_cos_ϕ

    # RE profiles
    pv_fix_profile = read_file(joinpath(input_dir, "nodal_profile_pv_fixed_$(profile_year).csv"))          # fixed axis pv
    pv_opt_profile = read_file(joinpath(input_dir, "nodal_profile_pv_double_axis_$(profile_year).csv"))    # opt tracking pv
    wt_on_profile = read_file(joinpath(input_dir, "nodal_profile_onshore_wind_$(profile_year).csv"))       # onshore wind

    # Near shore wind profile based on potential type
    potential_prefix = potential in [:gis, :eresan] ? string(potential) : 
        error("Potential with the name $(potential) is not defined.")
    nwt_off_profile = read_file(joinpath(input_dir, "nodal_profile_$(potential_prefix)_near_offshore_wind_$(profile_year).csv"))

    # Far shore wind profile
    fwt_off_profile = read_file(joinpath(input_dir, "nodal_profile_far_offshore_wind_$(profile_year).csv"))     # far shore offshore wind

    round_df_floats!(pv_fix_profile, 3)
    round_df_floats!(pv_opt_profile, 3)
    round_df_floats!(wt_on_profile, 3)
    round_df_floats!(nwt_off_profile, 3)
    round_df_floats!(fwt_off_profile, 3)

    # RE profile in axis arrays
    pv_fix = df_to_axisarray(pv_fix_profile)     # fixed axis pv
    pv_opt = df_to_axisarray(pv_opt_profile)     # opt tracking pv
    wt_on = df_to_axisarray(wt_on_profile)       # onshore wind
    nwt_off = df_to_axisarray(nwt_off_profile)   # near offshore wind
    fwt_off = df_to_axisarray(fwt_off_profile)   # far offshore wind

    # RE potentials based on GIS and military limitations
    wind_potential = configs.limited == :no ? 
        MAT.matread(joinpath(input_dir, "GISdata_wind2019_vgr104b.mat")) : 
        MAT.matread(joinpath(input_dir, "GISdata_wind2019_vgr104b_milex.mat"))

    solar_potential = configs.limited == :no ? 
        MAT.matread(joinpath(input_dir, "GISdata_solar2019_vgr104b.mat")) : 
        MAT.matread(joinpath(input_dir, "GISdata_solar2019_vgr104b_milex.mat"))        

    # EV data
    nr_vehicles = read_file(joinpath(input_dir, "nr_of_vehicles.csv"))
    fleet_availability = read_file(joinpath(input_dir, "fleet_availability.csv"))
    share_ev_all = read_file(joinpath(input_dir, "share_ev_year.csv"))
    ev_demand_profile = read_file(joinpath(input_dir, "ev_demand_profile.csv"))
    ev_charging_profile = read_file(joinpath(input_dir, "ev_charging_profile.csv"))

    round_df_floats!(fleet_availability, 3)
    round_df_floats!(share_ev_all, 3)
    
    nr_vehicles = vehicle_df_to_axisarray(nr_vehicles) 
    fleet_availability = df_to_axisarray(fleet_availability) 
    share_ev_all = df_to_axisarray(share_ev_all)
    ev_demand_profile = df_to_axisarray(ev_demand_profile)
    ev_charging_profile = df_to_axisarray(ev_charging_profile)

    # collections of input data for return
    price = (; SE3=Array(elpris_df.SE3), NO1=Array(elpris_df.NO1), DK1=Array(elpris_df.DK1))
    grid_infra = (; subs=substations_df, lines=lines_df, pp=pp_df)
    tech_props = (; gen=gen_tech_df, sto=sto_tech_df)    
    demand = (; el, heat, h2, reactive)
    profiles = (; WON=wt_on, NWOFF=nwt_off, FWOFF=fwt_off, PVROOF=pv_fix, PVTRACK=pv_opt)
    potentials = (; wind=wind_potential, solar=solar_potential)
    ev_data = (; nr_vehicles, fleet_availability, share_ev_all, ev_demand_profile, ev_charging_profile)
    
    return (; price, grid_infra, tech_props, demand, profiles, potentials, ev_data)
end
