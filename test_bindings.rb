#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Demonstration of the BallisticsEngine hash API. Run after building the extension:
#   rake compile && ruby -Ilib test_bindings.rb

require_relative "lib/ballistics_engine"

puts "BallisticsEngine #{BallisticsEngine::VERSION}"
puts "=" * 60

inputs = {
  "bc"                     => 0.223,
  "bullet_weight_grains"   => 168.0,
  "muzzle_velocity_fps"    => 2650.0,
  "bullet_diameter_inches" => 0.308,
  "bullet_length_inches"   => 1.2,
  "sight_height_inches"    => 1.5,
  "zero_distance_yards"    => 1000.0,
  "drag_model"             => "G7"
}

puts "\n1. Trajectory"
r = BallisticsEngine.solve(inputs)
puts "   max range:       #{r['max_range_yards'].round(1)} yd"
puts "   time of flight:  #{r['time_of_flight'].round(3)} s"
puts "   impact velocity: #{r['impact_velocity_fps'].round(1)} fps"
puts "   points:          #{r['points'].length}"

puts "\n2. Velocity-dependent BC (bc_segments)"
seg = BallisticsEngine.solve(inputs.merge(
  "use_bc_segments"  => true,
  "bc_segments_data" => [
    { "velocity_min_fps" => 1800.0, "velocity_max_fps" => 4000.0, "bc" => 0.223 },
    { "velocity_min_fps" => 1200.0, "velocity_max_fps" => 1800.0, "bc" => 0.205 }
  ]
))
puts "   impact velocity: #{seg['impact_velocity_fps'].round(1)} fps (vs #{r['impact_velocity_fps'].round(1)} flat)"

puts "\n3. Segmented wind"
w = BallisticsEngine.solve(inputs.merge(
  "wind_segments" => [[5.0, 90.0, 500.0], [10.0, 90.0, 1000.0]]
))
puts "   windage at impact: #{w['points'].last['z'].round(2)} yd"

puts "\n4. Zero angle"
z = BallisticsEngine.calculate_zero_angle(inputs.merge("target_distance_yards" => 1000.0))
puts "   zero angle: #{z['zero_angle_moa'].round(2)} MOA"

puts "\n5. Monte Carlo"
mc = BallisticsEngine.monte_carlo(inputs.merge(
  "num_simulations" => 500, "velocity_std_dev_fps" => 10.0, "target_distance_yards" => 1000.0
))
puts "   simulations:     #{mc['num_simulations']}"
puts "   hit probability: #{(mc['hit_probability'] * 100).round(1)}%"

puts "\nDone."
