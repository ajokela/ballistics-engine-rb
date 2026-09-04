# frozen_string_literal: true
#
# End-to-end test for BallisticsEngine.bridge_call — the raw pass-through to the
# engine's versioned JSON command bridge (ballistics_engine::bridge::bridge_call).
#
# The contract under test is deliberately thin: one String in (a full request
# envelope), one String out (a full response envelope). The wrapper parses nothing
# and raises nothing — the bridge is catch_unwind-guarded and reports every failure
# IN BAND as {"ok":false,"error":{...}}, so these checks assert on the envelope.
#
# The substantive reason this exists: `solve` reaches the whole solve-json v1 surface,
# including corrections.bc5d_table_path and atmosphere.pressure_reference, which the
# hash-based BallisticsEngine.solve cannot reach at all, and effects.wind_shear_model
# as a validated enum. The wind-shear checks below prove that route is live end to end.

require "json"
require "ballistics_engine"

failures = 0
def check(cond, msg)
  puts(cond ? "ok:   #{msg}" : "FAIL: #{msg}")
  cond ? 0 : 1
end

def envelope(command, request)
  JSON.generate("api_version" => 1, "command" => command, "request" => request)
end

def call(command, request)
  JSON.parse(BallisticsEngine.bridge_call(envelope(command, request)))
end

# A solve-json v1 document. `muzzle_angle_rad` is supplied directly so the shot's
# loft is a property of the test, not of a zero search.
def solve_request(muzzle_angle_rad:, max_range_m:, effects: {})
  {
    "schema_version" => 1,
    "projectile" => {
      "mass_kg" => 0.01134, "diameter_m" => 0.00782, "length_m" => 0.0353,
      "drag_model" => "G7", "ballistic_coefficient" => 0.243
    },
    "rifle" => {
      "muzzle_velocity_mps" => 823.0, "sight_height_m" => 0.05,
      "twist_rate_m_per_turn" => 0.2032, "twist_direction" => "right"
    },
    "shot" => { "max_range_m" => max_range_m, "muzzle_angle_rad" => muzzle_angle_rad },
    "atmosphere" => {},
    # Pure left-to-right crosswind (10 mph from 90 deg), so shear shows up as windage.
    "wind" => { "speed_mps" => 4.4704, "direction_from_rad" => 1.5707963267948966 },
    "solver" => { "method" => "rk4", "time_step_s" => 0.001 },
    "effects" => effects,
    "sampling" => { "interval_m" => 250.0 }
  }
end

def windage_at_muzzle_angle(angle, range, model)
  effects = model ? { "wind_shear_model" => model } : {}
  r = call("solve", solve_request(muzzle_angle_rad: angle, max_range_m: range, effects: effects))
  raise "solve failed: #{r["error"].inspect}" unless r["ok"]

  [r["result"]["samples"].last["windage_m"], r]
end

# --- 1. The wrapper is a string function, not a parsed one. --------------------
raw = BallisticsEngine.bridge_call(envelope("meta.version", {}))
failures += check(raw.is_a?(String), "bridge_call returns a String (caller owns the envelope)")
failures += check(raw.start_with?("{"), "returned String is a JSON document")

# --- 2. meta.version reports this binding's engine version. --------------------
ver = JSON.parse(raw)
failures += check(ver["ok"] == true, "meta.version envelope is ok")
failures += check(ver["api_version"] == 1, "envelope api_version is 1")
failures += check(ver["engine_version"] == "0.36.3",
                  "meta.version reports engine 0.36.3 (got #{ver["engine_version"].inspect})")
failures += check(ver["result"]["engine_version"] == "0.36.3",
                  "meta.version result.engine_version is 0.36.3")
failures += check(BallisticsEngine::VERSION == ver["engine_version"],
                  "gem VERSION #{BallisticsEngine::VERSION} matches the engine it links")

# --- 3. meta.capabilities lists the commands this build can run. ---------------
caps = call("meta.capabilities", {})
failures += check(caps["ok"] == true, "meta.capabilities envelope is ok")
commands = caps["result"]["commands"]
failures += check(commands.include?("solve"), "capabilities list includes solve")
failures += check(%w[card.come_ups true.fit bc5d.info].all? { |c| commands.include?(c) },
                  "capabilities list includes the card/truing/bc5d commands")
failures += check(caps["result"]["solve_schema_version"] == 1, "solve schema version is 1")

# --- 4. A real solve round-trips. ---------------------------------------------
flat = call("solve", solve_request(muzzle_angle_rad: 0.0, max_range_m: 1000.0))
failures += check(flat["ok"] == true, "solve returns ok (#{flat["error"].inspect if flat["error"]})")
failures += check(flat["command"] == "solve", "response echoes command 'solve'")
samples = flat["result"]["samples"]
failures += check(samples.is_a?(Array) && !samples.empty?, "solve returns samples (#{samples&.length})")
failures += check((samples.last["distance_m"] - 1000.0).abs < 1e-6,
                  "last sample is at the requested 1000 m (#{samples.last["distance_m"]})")
failures += check(samples.last["speed_mps"].to_f > 0.0,
                  "terminal speed is positive (#{samples.last["speed_mps"].round(1)} m/s)")
failures += check(flat["result"]["summary"]["time_of_flight_s"].to_f > 0.0, "time of flight is positive")

# --- 5. effects.wind_shear_model is accepted and echoed. ----------------------
# The v1 surface types this field as an enum, so a bad name is reported (check 7)
# rather than silently mapped to the power law the way the hash surface's free-form
# wind_shear_model string is.
sheared = call("solve", solve_request(muzzle_angle_rad: 0.2, max_range_m: 3000.0,
                                      effects: { "wind_shear_model" => "power_law" }))
failures += check(sheared["ok"] == true, "solve accepts effects.wind_shear_model")
failures += check(sheared["result"]["resolved_request"]["effects"]["wind_shear_model"] == "power_law",
                  "resolved_request echoes wind_shear_model=power_law")

# --- 6. ...and it CHANGES the answer on a lofted shot. ------------------------
# The boundary-layer profile is floored at a ratio of 1.0 below the 10 m
# meteorological reference height (bullet height above the muzzle + ~1.5 m of assumed
# muzzle height), so a flat-fire shot is byte-identical with and without shear and
# proves nothing. The shot is lofted to 0.2 rad so it climbs well past that floor.
loft_none, loft_none_env = windage_at_muzzle_angle(0.2, 3000.0, nil)
loft_pl, = windage_at_muzzle_angle(0.2, 3000.0, "power_law")
loft_log, = windage_at_muzzle_angle(0.2, 3000.0, "logarithmic")
apex = loft_none_env["result"]["summary"]["maximum_height_m"]
failures += check(apex.to_f > 10.0,
                  "the lofted shot really does climb past the 10 m shear reference " \
                  "(apex #{apex.to_f.round(1)} m)")
failures += check((loft_pl - loft_none).abs > 1.0,
                  "power_law shear changes lofted windage " \
                  "(#{loft_none.round(3)} m -> #{loft_pl.round(3)} m, " \
                  "delta #{(loft_pl - loft_none).round(3)} m)")
failures += check((loft_log - loft_none).abs > 1.0,
                  "logarithmic shear changes lofted windage " \
                  "(#{loft_none.round(3)} m -> #{loft_log.round(3)} m, " \
                  "delta #{(loft_log - loft_none).round(3)} m)")
failures += check(loft_pl.abs > loft_none.abs,
                  "shear increases drift rather than reducing it (floor is 1.0, never below)")

# Control: the same comparison flat, where the floor makes shear a no-op. This is
# the check that would silently pass a broken wiring, so it is asserted as EQUAL.
flat_none, = windage_at_muzzle_angle(0.0, 1000.0, nil)
flat_pl, = windage_at_muzzle_angle(0.0, 1000.0, "power_law")
failures += check(flat_none == flat_pl,
                  "flat fire is unchanged by shear, as the 1.0 floor requires " \
                  "(#{flat_none.round(6)} m both ways)")

# --- 7. Failures come back in band; nothing raises. ---------------------------
bad_model = call("solve", solve_request(muzzle_angle_rad: 0.2, max_range_m: 3000.0,
                                        effects: { "wind_shear_model" => "hurricane" }))
failures += check(bad_model["ok"] == false, "an unknown shear model is a failed envelope, not an exception")
failures += check(bad_model["error"]["details"]["error"]["path"] == "$.effects.wind_shear_model",
                  "the error names the offending field path")

unknown = call("nope.not_a_command", {})
failures += check(unknown["ok"] == false && unknown["error"]["code"] == "unknown_command",
                  "an unknown command returns error.code=unknown_command")

malformed = JSON.parse(BallisticsEngine.bridge_call("{ this is not json"))
failures += check(malformed["ok"] == false && malformed["error"]["code"] == "invalid_json",
                  "malformed request JSON returns error.code=invalid_json")

wrong_api = JSON.parse(BallisticsEngine.bridge_call(
                         JSON.generate("api_version" => 99, "command" => "meta.version", "request" => {})
                       ))
failures += check(wrong_api["ok"] == false && wrong_api["error"]["code"] == "unsupported_api_version",
                  "a future api_version is rejected in band")

puts(failures.zero? ? "\nALL CHECKS PASSED" : "\n#{failures} CHECK(S) FAILED")
exit(failures.zero? ? 0 : 1)
