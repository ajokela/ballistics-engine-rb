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

puts(failures.zero? ? "\nALL CHECKS PASSED" : "\n#{failures} CHECK(S) FAILED")
exit(failures.zero? ? 0 : 1)
