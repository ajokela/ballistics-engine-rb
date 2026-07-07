# frozen_string_literal: true
#
# CI smoke test for the installed gem (the rb-sys extension compiled against the
# crates.io `ballistics-engine` dependency). Exercises the current hash-based
# BallisticsEngine.solve API and the directional Coriolis exposure.

require "ballistics_engine"

failures = 0
def check(cond, msg)
  if cond
    puts "ok:   #{msg}"
    0
  else
    puts "FAIL: #{msg}"
    1
  end
end

base = {
  "bc" => 0.5,
  "bullet_weight_grains" => 168.0,
  "muzzle_velocity_fps" => 2650.0,
  "bullet_diameter_inches" => 0.308,
  "bullet_length_inches" => 1.2,
  "sight_height_inches" => 1.5,
  "zero_distance_yards" => 1000.0,
  "drag_model" => "G7"
}

# 1. Basic solve returns a usable trajectory.
r = BallisticsEngine.solve(base)
failures += check(r["points"].is_a?(Array) && !r["points"].empty?, "solve returns trajectory points")
failures += check(r["impact_velocity_fps"].to_f > 0.0, "impact velocity is positive")
failures += check(r["max_range_yards"].to_f > 0.0, "max range is positive")

# 2. Directional Coriolis (Eotvos): an east shot lifts above a west shot at equal range.
def final_vertical(dir, base)
  BallisticsEngine.solve(
    base.merge("enable_coriolis" => true, "latitude_degrees" => 45.0, "shot_direction_degrees" => dir)
  )["points"].last["y"]
end
east = final_vertical(90.0, base)
west = final_vertical(270.0, base)
failures += check(east != west, "shot_direction changes Coriolis (east != west)")
failures += check(east > west, "Coriolis Eotvos sign: east (#{east.round(4)}) higher than west (#{west.round(4)})")

# 3. Manual velocity:BC segments (a full-flight low BC forces more drag than flat 0.5).
flat = BallisticsEngine.solve(base)
seg = BallisticsEngine.solve(
  base.merge(
    "use_bc_segments" => true,
    "bc_segments_data" => [{ "velocity_min_fps" => 100.0, "velocity_max_fps" => 4000.0, "bc" => 0.2 }]
  )
)
failures += check(seg["impact_velocity_fps"].to_f < flat["impact_velocity_fps"].to_f - 10.0,
                  "bc_segments 0.2 lowers impact velocity vs flat 0.5 " \
                  "(#{seg['impact_velocity_fps'].round(1)} < #{flat['impact_velocity_fps'].round(1)})")

# 4. Segmented wind produces lateral drift.
no_wind_z = flat["points"].last["z"]
seg_wind_z = BallisticsEngine.solve(
  base.merge("wind_segments" => [[10.0, 90.0, 500.0], [20.0, 90.0, 1000.0]])
)["points"].last["z"]
failures += check(seg_wind_z != no_wind_z, "wind_segments produce lateral drift (z #{seg_wind_z.round(2)} != #{no_wind_z.round(2)})")

# 5. calculate_zero_angle returns a small positive launch angle.
za = BallisticsEngine.calculate_zero_angle(base.merge("target_distance_yards" => 100.0))
failures += check(za["zero_angle_radians"].to_f > 0.0 && za["zero_angle_degrees"].to_f < 1.0,
                  "zero angle is a small positive angle (#{za['zero_angle_degrees'].round(4)} deg)")

# 6. Monte Carlo returns the requested number of shots and a valid hit probability.
mc = BallisticsEngine.monte_carlo(
  base.merge("num_simulations" => 200, "velocity_std_dev_fps" => 10.0, "target_distance_yards" => 1000.0)
)
failures += check(mc["ranges_yards"].is_a?(Array) && mc["ranges_yards"].length == 200, "monte_carlo returns 200 ranges")
failures += check((0.0..1.0).cover?(mc["hit_probability"].to_f), "hit_probability in [0,1] (#{mc['hit_probability']})")
failures += check(mc["impact_velocities_fps"].all? { |v| v.to_f > 0.0 }, "all monte_carlo impact velocities positive")

# 7. Trajectory sampling populates sampled_points.
sp = BallisticsEngine.solve(base.merge("enable_trajectory_sampling" => true, "sample_interval_yards" => 100.0))
failures += check(sp["sampled_points"].is_a?(Array) && !sp["sampled_points"].empty?,
                  "sampled_points populated when sampling enabled (#{sp['sampled_points']&.length} samples)")

puts(failures.zero? ? "\nALL CHECKS PASSED" : "\n#{failures} CHECK(S) FAILED")
exit(failures.zero? ? 0 : 1)
