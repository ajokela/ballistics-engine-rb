use magnus::{Error, RArray, RHash, function};
use ballistics_engine::{
    AtmosphericConditions, BCSegmentData, BallisticInputs, DragModel, MonteCarloParams,
    TrajectorySolver, WindConditions, calculate_zero_angle_with_conditions, run_monte_carlo,
};
use ballistics_engine::wind::WindSegment;

// Unit conversion constants
const GRAINS_TO_KG: f64 = 0.00006479891;
const FPS_TO_MPS: f64 = 0.3048;
const YARDS_TO_METERS: f64 = 0.9144;
const INCHES_TO_METERS: f64 = 0.0254;
const MPH_TO_MPS: f64 = 0.44704;
const MPH_TO_KMH: f64 = 1.609344;
const INHG_TO_HPA: f64 = 33.8639;
const DEGREES_TO_RADIANS: f64 = std::f64::consts::PI / 180.0;
const JOULES_TO_FTLBS: f64 = 0.737562;
const METERS_TO_INCHES: f64 = 39.37007874;

// Typed wrappers around RHash::lookup2 — magnus's lookup2<T,U,V> can't infer the output
// type V from the default U, so give each call site a concrete return type here.
fn opt_f64(h: &RHash, key: &str, default: f64) -> Result<f64, Error> {
    h.lookup2(key, default)
}
fn opt_bool(h: &RHash, key: &str, default: bool) -> Result<bool, Error> {
    h.lookup2(key, default)
}
fn opt_str(h: &RHash, key: &str, default: &str) -> Result<String, Error> {
    h.lookup2(key, default.to_string())
}
fn opt_usize(h: &RHash, key: &str, default: usize) -> Result<usize, Error> {
    h.lookup2(key, default)
}

fn drag_from_str(ruby: &magnus::Ruby, s: &str) -> Result<DragModel, Error> {
    match s.to_uppercase().as_str() {
        "G1" => Ok(DragModel::G1),
        "G7" => Ok(DragModel::G7),
        "G8" => Ok(DragModel::G8),
        _ => Err(Error::new(
            ruby.exception_arg_error(),
            "Invalid drag_model, must be G1, G7, or G8",
        )),
    }
}

/// Build WindConditions from an optional `wind` sub-hash (mph & degrees -> m/s & radians).
fn build_wind(h: &RHash) -> Result<WindConditions, Error> {
    if let Some(w) = h.lookup::<_, Option<RHash>>("wind")? {
        Ok(WindConditions {
            speed: opt_f64(&w, "speed_mph", 0.0)? * MPH_TO_MPS,
            direction: opt_f64(&w, "direction_degrees", 0.0)? * DEGREES_TO_RADIANS,
            // ballistics-engine 0.24.0 added vertical_speed (MBA-728); the Ruby `wind`
            // sub-hash has no vertical-wind key yet, so leave it at the engine default (0.0).
            ..Default::default()
        })
    } else {
        Ok(WindConditions::default())
    }
}

/// Build AtmosphericConditions from an optional `atmosphere` sub-hash. Note:
/// AtmosphericConditions.humidity is PERCENT (0-100), pressure is hPa, temp is Celsius.
fn build_atmosphere(h: &RHash) -> Result<AtmosphericConditions, Error> {
    if let Some(a) = h.lookup::<_, Option<RHash>>("atmosphere")? {
        let temp_f = opt_f64(&a, "temperature_f", 59.0)?;
        let pressure_inhg = opt_f64(&a, "pressure_inhg", 29.92)?;
        Ok(AtmosphericConditions {
            temperature: (temp_f - 32.0) * 5.0 / 9.0,
            pressure: pressure_inhg * INHG_TO_HPA,
            humidity: opt_f64(&a, "humidity_percent", 50.0)?,
            altitude: opt_f64(&a, "altitude_feet", 0.0)? * FPS_TO_MPS,
        })
    } else {
        Ok(AtmosphericConditions {
            temperature: 15.0,
            pressure: 1013.25,
            humidity: 50.0,
            altitude: 0.0,
        })
    }
}

/// `bc_segments` = array of [mach, bc] pairs (Mach-keyed). Converts directly.
fn extract_bc_segments(h: &RHash) -> Result<Option<Vec<(f64, f64)>>, Error> {
    match h.lookup::<_, Option<Vec<(f64, f64)>>>("bc_segments")? {
        Some(v) if !v.is_empty() => Ok(Some(v)),
        _ => Ok(None),
    }
}

/// `bc_segments_data` = array of {velocity_min_fps, velocity_max_fps, bc} hashes
/// OR [vmin_fps, vmax_fps, bc] triples. Velocities stay in FPS: the solver compares
/// BCSegmentData bounds directly against the bullet's velocity_fps (not m/s).
/// RHash is not TryConvertOwned, so iterate by index and try the hash form first.
fn extract_bc_segments_data(h: &RHash) -> Result<Vec<BCSegmentData>, Error> {
    let mut out = Vec::new();
    if let Some(arr) = h.lookup::<_, Option<RArray>>("bc_segments_data")? {
        for i in 0..arr.len() {
            if let Ok(seg) = arr.entry::<RHash>(i as isize) {
                let bc = match seg.lookup::<_, Option<f64>>("bc")? {
                    Some(v) => v,
                    None => opt_f64(&seg, "bc_value", 0.0)?,
                };
                out.push(BCSegmentData {
                    velocity_min: seg.fetch::<_, f64>("velocity_min_fps")?,
                    velocity_max: seg.fetch::<_, f64>("velocity_max_fps")?,
                    bc_value: bc,
                });
            } else {
                let (vmin, vmax, bc): (f64, f64, f64) = arr.entry(i as isize)?;
                out.push(BCSegmentData {
                    velocity_min: vmin,
                    velocity_max: vmax,
                    bc_value: bc,
                });
            }
        }
    }
    Ok(out)
}

/// `wind_segments` = array of [speed_mph, angle_degrees, until_yards] -> engine
/// `WindSegment` (km/h, deg, meters). ballistics-engine 0.24.0 converted `WindSock` /
/// `TrajectorySolver::set_wind_segments` from `(f64, f64, f64)` tuples to this named
/// struct; keep the Ruby-facing arrays as plain 3-number triples and convert at the
/// boundary via `WindSegment::new`.
fn extract_wind_segments(h: &RHash) -> Result<Vec<WindSegment>, Error> {
    match h.lookup::<_, Option<Vec<(f64, f64, f64)>>>("wind_segments")? {
        Some(v) => Ok(v
            .into_iter()
            .map(|(mph, ang, until_yd)| {
                WindSegment::new(mph * MPH_TO_KMH, ang, until_yd * YARDS_TO_METERS)
            })
            .collect()),
        None => Ok(Vec::new()),
    }
}

/// `powder_temp_curve` = array of [temp_f, velocity_fps] -> [(celsius, m/s)].
fn extract_powder_curve(h: &RHash) -> Result<Option<Vec<(f64, f64)>>, Error> {
    match h.lookup::<_, Option<Vec<(f64, f64)>>>("powder_temp_curve")? {
        Some(v) if !v.is_empty() => Ok(Some(
            v.into_iter()
                .map(|(tf, vfps)| ((tf - 32.0) * 5.0 / 9.0, vfps * FPS_TO_MPS))
                .collect(),
        )),
        _ => Ok(None),
    }
}

/// Build a fully-populated BallisticInputs from an imperial Ruby hash (imperial -> SI).
/// Shared by solve, calculate_zero_angle, and monte_carlo.
fn build_inputs(ruby: &magnus::Ruby, h: &RHash) -> Result<BallisticInputs, Error> {
    let drag_model = drag_from_str(ruby, &opt_str(h, "drag_model", "G7")?)?;
    let bullet_diameter_inches: f64 = h.fetch("bullet_diameter_inches")?;
    let bullet_weight_grains: f64 = h.fetch("bullet_weight_grains")?;

    let bc_seg_data = extract_bc_segments_data(h)?;

    let mut inputs = BallisticInputs {
        bc_type: drag_model,
        bc_value: h.fetch("bc")?,
        bullet_diameter: bullet_diameter_inches * INCHES_TO_METERS,
        bullet_mass: bullet_weight_grains * GRAINS_TO_KG,
        bullet_length: h.fetch::<_, f64>("bullet_length_inches")? * INCHES_TO_METERS,
        muzzle_velocity: h.fetch::<_, f64>("muzzle_velocity_fps")? * FPS_TO_MPS,
        sight_height: h.fetch::<_, f64>("sight_height_inches")? * INCHES_TO_METERS,
        target_distance: h.fetch::<_, f64>("zero_distance_yards")? * YARDS_TO_METERS,
        // geometry / aim
        shooting_angle: opt_f64(h, "shooting_angle_degrees", 0.0)? * DEGREES_TO_RADIANS,
        muzzle_angle: opt_f64(h, "muzzle_angle_degrees", 0.0)? * DEGREES_TO_RADIANS,
        azimuth_angle: opt_f64(h, "azimuth_angle_degrees", 0.0)? * DEGREES_TO_RADIANS,
        twist_rate: opt_f64(h, "twist_rate_inches", 10.0)?, // inches/turn, NOT SI
        is_twist_right: opt_bool(h, "is_right_twist", true)?,
        caliber_inches: bullet_diameter_inches,
        weight_grains: bullet_weight_grains,
        muzzle_height: opt_f64(h, "muzzle_height_inches", 0.0)? * INCHES_TO_METERS,
        target_height: opt_f64(h, "target_height_inches", 0.0)? * INCHES_TO_METERS,
        // physics flags
        enable_aerodynamic_jump: opt_bool(h, "enable_aerodynamic_jump", false)?,
        enable_advanced_effects: opt_bool(h, "enable_advanced_effects", false)?,
        enable_magnus: opt_bool(h, "enable_magnus", false)?,
        enable_coriolis: opt_bool(h, "enable_coriolis", false)?,
        latitude: h.lookup::<_, Option<f64>>("latitude_degrees")?,
        shot_azimuth: opt_f64(h, "shot_direction_degrees", 0.0)? * DEGREES_TO_RADIANS,
        use_enhanced_spin_drift: opt_bool(h, "use_enhanced_spin_drift", false)?,
        use_form_factor: opt_bool(h, "use_form_factor", false)?,
        use_cluster_bc: opt_bool(h, "use_cluster_bc", false)?,
        enable_pitch_damping: opt_bool(h, "enable_pitch_damping", false)?,
        enable_precession_nutation: opt_bool(h, "enable_precession_nutation", false)?,
        use_rk4: opt_bool(h, "use_rk4", true)?,
        use_adaptive_rk45: opt_bool(h, "use_adaptive_rk45", true)?,
        tipoff_yaw: opt_f64(h, "tipoff_yaw_degrees", 0.0)? * DEGREES_TO_RADIANS,
        tipoff_decay_distance: opt_f64(h, "tipoff_decay_distance_yards", 50.0)? * YARDS_TO_METERS,
        // powder sensitivity
        use_powder_sensitivity: opt_bool(h, "use_powder_sensitivity", false)?,
        powder_temp_sensitivity: opt_f64(h, "powder_temp_sensitivity", 0.0)?, // (m/s)/C
        powder_temp: (opt_f64(h, "powder_temp_f", 59.0)? - 32.0) * 5.0 / 9.0,
        powder_temp_curve: extract_powder_curve(h)?,
        powder_curve_temp_c: h
            .lookup::<_, Option<f64>>("powder_curve_temp_f")?
            .map(|tf| (tf - 32.0) * 5.0 / 9.0),
        // wind shear
        enable_wind_shear: opt_bool(h, "enable_wind_shear", false)?,
        wind_shear_model: opt_str(h, "wind_shear_model", "none")?,
        // sampling
        enable_trajectory_sampling: opt_bool(h, "enable_trajectory_sampling", false)?,
        // BC segments
        use_bc_segments: opt_bool(h, "use_bc_segments", false)?,
        bc_segments: extract_bc_segments(h)?,
        bc_segments_data: if bc_seg_data.is_empty() {
            None
        } else {
            Some(bc_seg_data)
        },
        // metadata
        manufacturer: h.lookup::<_, Option<String>>("manufacturer")?,
        bullet_model: h.lookup::<_, Option<String>>("bullet_model")?,
        bullet_id: h.lookup::<_, Option<String>>("bullet_id")?,
        bullet_cluster: h.lookup::<_, Option<usize>>("bullet_cluster")?,
        ..Default::default()
    };

    // ground_threshold / sample_interval have non-trivial engine defaults (-100 m / 10 m);
    // only override them if the caller supplied a value (in yards -> meters).
    if let Some(gt) = h.lookup::<_, Option<f64>>("ground_threshold_yards")? {
        inputs.ground_threshold = gt * YARDS_TO_METERS;
    }
    if let Some(si) = h.lookup::<_, Option<f64>>("sample_interval_yards")? {
        inputs.sample_interval = si * YARDS_TO_METERS;
    }

    Ok(inputs)
}

/// Calculate a trajectory from an imperial Ruby hash. Returns a Ruby hash.
fn solve_trajectory(ruby: &magnus::Ruby, h: RHash) -> Result<RHash, Error> {
    let inputs = build_inputs(ruby, &h)?;
    let wind = build_wind(&h)?;
    let atmosphere = build_atmosphere(&h)?;

    let mut solver = TrajectorySolver::new(inputs, wind, atmosphere);
    let segs = extract_wind_segments(&h)?;
    if !segs.is_empty() {
        solver.set_wind_segments(segs);
    }
    if let Some(mr) = h.lookup::<_, Option<f64>>("max_range_yards")? {
        solver.set_max_range(mr * YARDS_TO_METERS);
    }
    if let Some(ts) = h.lookup::<_, Option<f64>>("time_step_seconds")? {
        solver.set_time_step(ts);
    }

    let result = solver
        .solve()
        .map_err(|e| Error::new(ruby.exception_runtime_error(), e.to_string()))?;

    let out = ruby.hash_new();
    out.aset("max_range_yards", result.max_range / YARDS_TO_METERS)?;
    out.aset("max_height_yards", result.max_height / YARDS_TO_METERS)?;
    out.aset("time_of_flight", result.time_of_flight)?;
    out.aset("impact_velocity_fps", result.impact_velocity / FPS_TO_MPS)?;
    out.aset("impact_energy_ftlbs", result.impact_energy * JOULES_TO_FTLBS)?;

    let points = ruby.ary_new();
    for point in &result.points {
        let ph = ruby.hash_new();
        ph.aset("time", point.time)?;
        ph.aset("x", point.position.x / YARDS_TO_METERS)?;
        ph.aset("y", point.position.y / YARDS_TO_METERS)?;
        ph.aset("z", point.position.z / YARDS_TO_METERS)?;
        ph.aset("velocity_fps", point.velocity_magnitude / FPS_TO_MPS)?;
        ph.aset("energy_ftlbs", point.kinetic_energy * JOULES_TO_FTLBS)?;
        points.push(ph)?;
    }
    out.aset("points", points)?;

    // Rich output (present only when the corresponding feature produced Some).
    if let Some(samples) = &result.sampled_points {
        let arr = ruby.ary_new();
        for s in samples {
            let sh = ruby.hash_new();
            sh.aset("distance_yards", s.distance_m / YARDS_TO_METERS)?;
            sh.aset("drop_inches", s.drop_m * METERS_TO_INCHES)?;
            sh.aset("wind_drift_inches", s.wind_drift_m * METERS_TO_INCHES)?;
            sh.aset("velocity_fps", s.velocity_mps / FPS_TO_MPS)?;
            sh.aset("energy_ftlbs", s.energy_j * JOULES_TO_FTLBS)?;
            sh.aset("time", s.time_s)?;
            let flags = ruby.ary_new();
            for f in &s.flags {
                flags.push(format!("{:?}", f))?;
            }
            sh.aset("flags", flags)?;
            arr.push(sh)?;
        }
        out.aset("sampled_points", arr)?;
    }
    if let Some(aj) = &result.aerodynamic_jump {
        let jh = ruby.hash_new();
        jh.aset("vertical_jump_moa", aj.vertical_jump_moa)?;
        jh.aset("horizontal_jump_moa", aj.horizontal_jump_moa)?;
        jh.aset("jump_angle_rad", aj.jump_angle_rad)?;
        jh.aset("magnus_component_moa", aj.magnus_component_moa)?;
        jh.aset("yaw_component_moa", aj.yaw_component_moa)?;
        jh.aset("stabilization_factor", aj.stabilization_factor)?;
        out.aset("aerodynamic_jump", jh)?;
    }
    if let Some(a) = &result.angular_state {
        let ah = ruby.hash_new();
        ah.aset("pitch_angle", a.pitch_angle)?;
        ah.aset("yaw_angle", a.yaw_angle)?;
        ah.aset("pitch_rate", a.pitch_rate)?;
        ah.aset("yaw_rate", a.yaw_rate)?;
        ah.aset("precession_angle", a.precession_angle)?;
        ah.aset("nutation_phase", a.nutation_phase)?;
        out.aset("angular_state", ah)?;
    }
    if let Some(v) = result.max_yaw_angle {
        out.aset("max_yaw_angle_rad", v)?;
    }
    if let Some(v) = result.max_precession_angle {
        out.aset("max_precession_angle_rad", v)?;
    }
    if let Some(v) = result.min_pitch_damping {
        out.aset("min_pitch_damping", v)?;
    }
    if let Some(v) = result.transonic_mach {
        out.aset("transonic_mach", v)?;
    }

    Ok(out)
}

/// Solve for the launch angle that zeroes at a target distance.
fn calculate_zero_angle(ruby: &magnus::Ruby, h: RHash) -> Result<RHash, Error> {
    let inputs = build_inputs(ruby, &h)?;
    let target_yd: f64 = h.fetch("target_distance_yards")?;
    let target_h_in: f64 = h.lookup2("target_height_inches", 0.0)?;
    let wind = build_wind(&h)?;
    let atmosphere = build_atmosphere(&h)?;

    let rad = calculate_zero_angle_with_conditions(
        inputs,
        target_yd * YARDS_TO_METERS,
        target_h_in * INCHES_TO_METERS,
        wind,
        atmosphere,
    )
    .map_err(|e| {
        Error::new(
            ruby.exception_runtime_error(),
            format!("Unable to find zero angle for target distance {target_yd}: {e}"),
        )
    })?;

    let out = ruby.hash_new();
    out.aset("zero_angle_radians", rad)?;
    out.aset("zero_angle_degrees", rad / DEGREES_TO_RADIANS)?;
    out.aset("zero_angle_moa", rad / DEGREES_TO_RADIANS * 60.0)?;
    Ok(out)
}

/// Monte Carlo dispersion. Reads `base_inputs` sub-hash (or the top-level hash) for the
/// bullet, plus std-dev params, and returns per-shot ranges/velocities/positions + hit prob.
fn monte_carlo(ruby: &magnus::Ruby, h: RHash) -> Result<RHash, Error> {
    let base = match h.lookup::<_, Option<RHash>>("base_inputs")? {
        Some(b) => b,
        None => h,
    };
    let inputs = build_inputs(ruby, &base)?;

    let params = MonteCarloParams {
        num_simulations: opt_usize(&h, "num_simulations", 1000)?,
        velocity_std_dev: opt_f64(&h, "velocity_std_dev_fps", 0.0)? * FPS_TO_MPS,
        angle_std_dev: opt_f64(&h, "angle_std_dev_radians", 0.001)?,
        bc_std_dev: opt_f64(&h, "bc_std_dev", 0.01)?,
        wind_speed_std_dev: opt_f64(&h, "wind_speed_std_dev_mph", 0.0)? * MPH_TO_MPS,
        target_distance: h
            .lookup::<_, Option<f64>>("target_distance_yards")?
            .map(|y| y * YARDS_TO_METERS),
        base_wind_speed: opt_f64(&h, "base_wind_speed_mph", 0.0)? * MPH_TO_MPS,
        base_wind_direction: opt_f64(&h, "base_wind_direction_degrees", 0.0)? * DEGREES_TO_RADIANS,
        azimuth_std_dev: opt_f64(&h, "azimuth_std_dev_radians", 0.001)?,
    };

    let res = run_monte_carlo(inputs, params)
        .map_err(|e| Error::new(ruby.exception_runtime_error(), e.to_string()))?;

    let out = ruby.hash_new();
    out.aset(
        "ranges_yards",
        res.ranges
            .iter()
            .map(|m| m / YARDS_TO_METERS)
            .collect::<Vec<f64>>(),
    )?;
    out.aset(
        "impact_velocities_fps",
        res.impact_velocities
            .iter()
            .map(|v| v / FPS_TO_MPS)
            .collect::<Vec<f64>>(),
    )?;
    let positions = ruby.ary_new();
    for p in &res.impact_positions {
        let ph = ruby.hash_new();
        ph.aset("vertical_inches", p.y * METERS_TO_INCHES)?; // McCoy Y = vertical
        ph.aset("lateral_inches", p.z * METERS_TO_INCHES)?; // McCoy Z = lateral
        positions.push(ph)?;
    }
    out.aset("impact_positions", positions)?;
    let radius_m = opt_f64(&h, "hit_radius_inches", 0.3 * METERS_TO_INCHES)? / METERS_TO_INCHES;
    out.aset("hit_probability", res.hit_probability(radius_m))?;
    out.aset("num_simulations", res.ranges.len())?;
    Ok(out)
}

#[magnus::init]
fn init(ruby: &magnus::Ruby) -> Result<(), Error> {
    let module = ruby.define_module("BallisticsEngine")?;
    module.define_module_function("solve", function!(solve_trajectory, 1))?;
    module.define_module_function("calculate_zero_angle", function!(calculate_zero_angle, 1))?;
    module.define_module_function("monte_carlo", function!(monte_carlo, 1))?;
    Ok(())
}
