# Ballistics Engine - Ruby Bindings

High-performance ballistics calculations library for Ruby, powered by Rust.

## Features

- **4-DOF Trajectory Modeling** - Complete trajectory calculations with realistic physics
- **Multiple Drag Models** - G1, G7, and G8 ballistic coefficients
- **Wind Deflection** - Accurate wind drift calculations
- **Atmospheric Effects** - Temperature, pressure, humidity, and altitude compensation
- **Unit Conversion** - Automatic handling of imperial/metric conversions
- **High Performance** - Rust-based calculations for maximum speed

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ballistics-engine'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install ballistics-engine
```

## Quick Start

The API is hash-in / hash-out — pass a hash of imperial-unit parameters, get a hash back.

```ruby
require 'ballistics_engine'

# 168gr .308 with a 10 mph crosswind
result = BallisticsEngine.solve(
  "bc"                     => 0.223,   # G7 BC
  "bullet_weight_grains"   => 168.0,
  "muzzle_velocity_fps"    => 2650.0,
  "bullet_diameter_inches" => 0.308,
  "bullet_length_inches"   => 1.2,
  "sight_height_inches"    => 1.5,
  "zero_distance_yards"    => 100.0,
  "drag_model"             => "G7",    # G1 | G7 | G8
  "wind"       => { "speed_mph" => 10.0, "direction_degrees" => 90.0 },
  "atmosphere" => { "temperature_f" => 59.0, "pressure_inhg" => 29.92,
                    "humidity_percent" => 50.0, "altitude_feet" => 0.0 }
)

puts "Max range:       #{result['max_range_yards'].round(1)} yd"
puts "Time of flight:  #{result['time_of_flight'].round(3)} s"
puts "Impact velocity: #{result['impact_velocity_fps'].round(1)} fps"
result["points"].each do |p|
  puts "  range #{p['x'].round(1)}yd  drop #{p['y'].round(2)}yd  vel #{p['velocity_fps'].round(1)}fps"
end
```

### Velocity-dependent BC (`bc_segments`)

Supply your own velocity:BC ladder (velocities in fps). The BC applies while the bullet's
current speed is in `[velocity_min_fps, velocity_max_fps)`:

```ruby
BallisticsEngine.solve(inputs.merge(
  "use_bc_segments"  => true,
  "bc_segments_data" => [
    { "velocity_min_fps" => 1800.0, "velocity_max_fps" => 4000.0, "bc" => 0.243 },
    { "velocity_min_fps" => 1500.0, "velocity_max_fps" => 1800.0, "bc" => 0.228 },
    { "velocity_min_fps" => 1200.0, "velocity_max_fps" => 1500.0, "bc" => 0.205 }
  ]
))
# Also accepts [vmin_fps, vmax_fps, bc] triples.
```

### Segmented wind (`wind_segments`)

Distance-keyed wind (independent of the velocity-keyed BC above) — e.g. downrange sensors:

```ruby
BallisticsEngine.solve(inputs.merge(
  # [speed_mph, angle_degrees, until_yards]  (angle 90 = from the right)
  "wind_segments" => [[5.0, 90.0, 150.0], [7.0, 90.0, 300.0], [9.0, 90.0, 1000.0]]
))
```

### Zero angle and Monte Carlo

```ruby
z = BallisticsEngine.calculate_zero_angle(inputs.merge("target_distance_yards" => 1000.0))
puts "zero: #{z['zero_angle_moa'].round(2)} MOA"

mc = BallisticsEngine.monte_carlo(inputs.merge(
  "num_simulations"      => 1000,
  "velocity_std_dev_fps" => 10.0,
  "bc_std_dev"           => 0.01,
  "target_distance_yards"=> 1000.0
))
puts "hit probability: #{(mc['hit_probability'] * 100).round(1)}%"
```

## API Reference

All functions live on the `BallisticsEngine` module and take a single hash with **string
keys** in imperial units. Unknown keys are ignored; only the seven marked required are needed.

### `BallisticsEngine.solve(hash) => hash`

**Required:** `bc`, `bullet_weight_grains`, `muzzle_velocity_fps`, `bullet_diameter_inches`,
`bullet_length_inches`, `sight_height_inches`, `zero_distance_yards`.

**Optional (selected):**
- Aim/geometry: `drag_model`("G7"), `shooting_angle_degrees`, `muzzle_angle_degrees`,
  `twist_rate_inches`(10), `is_right_twist`(true), `muzzle_height_inches`, `target_height_inches`.
- Wind: `wind` = `{speed_mph, direction_degrees}`; `wind_segments` = `[[speed_mph, angle_deg, until_yards], ...]`.
- Atmosphere: `atmosphere` = `{temperature_f, pressure_inhg, humidity_percent, altitude_feet}`.
- BC: `use_bc_segments`, `bc_segments_data` (see above), `bc_segments` = `[[mach, bc], ...]`.
- Coriolis: `enable_coriolis`, `latitude_degrees`, `shot_direction_degrees`.
- Physics flags: `enable_advanced_effects`, `enable_magnus`, `enable_aerodynamic_jump`,
  `use_enhanced_spin_drift`, `use_form_factor`, `use_cluster_bc`, `enable_pitch_damping`,
  `enable_precession_nutation`, `enable_wind_shear` (+ `wind_shear_model`), `use_rk4`, `use_adaptive_rk45`.
- Powder: `use_powder_sensitivity`, `powder_temp_sensitivity`, `powder_temp_f`,
  `powder_temp_curve` = `[[temp_f, velocity_fps], ...]`, `powder_curve_temp_f`.
- Sampling/solver: `enable_trajectory_sampling`, `sample_interval_yards`, `max_range_yards`, `time_step_seconds`.

**Returns:** `max_range_yards`, `max_height_yards`, `time_of_flight`, `impact_velocity_fps`,
`impact_energy_ftlbs`, `points` (array of `{time, x, y, z, velocity_fps, energy_ftlbs}` — x=range,
y=drop, z=windage, in yards). Present when enabled: `sampled_points`, `aerodynamic_jump`,
`angular_state`, `max_yaw_angle_rad`, `max_precession_angle_rad`, `min_pitch_damping`, `transonic_mach`.

### `BallisticsEngine.calculate_zero_angle(hash) => hash`

Same bullet keys as `solve`, plus **required** `target_distance_yards` (and optional
`target_height_inches`, `wind`, `atmosphere`). Returns `zero_angle_radians`,
`zero_angle_degrees`, `zero_angle_moa`. Raises on non-convergence.

### `BallisticsEngine.monte_carlo(hash) => hash`

Bullet keys (optionally nested under `base_inputs`) plus std-dev params:
`num_simulations`(1000), `velocity_std_dev_fps`, `angle_std_dev_radians`, `bc_std_dev`,
`wind_speed_std_dev_mph`, `azimuth_std_dev_radians`, `target_distance_yards`,
`base_wind_speed_mph`, `base_wind_direction_degrees`, `hit_radius_inches`(≈11.8).
Returns `ranges_yards`, `impact_velocities_fps`, `impact_positions`
(`[{vertical_inches, lateral_inches}, ...]`), `hit_probability`, `num_simulations`.
## Development

After checking out the repo, run `bundle install` to install dependencies.

To build the native extension:

```bash
bundle exec rake compile
```

To run tests:

```bash
bundle exec rake test
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ajokela/ballistics-engine.

## License

This project is licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE](LICENSE) or http://opensource.org/licenses/MIT)

at your option.
