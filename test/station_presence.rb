# frozen_string_literal: true
#
# Station presence (engine 0.49.0): a `temperature_f` or `pressure_inhg` key in the
# `atmosphere` hash is a reading and flies exactly as given, whatever its value and whatever
# the altitude. A key left out (or nil) keeps the engine's legacy rule, which flies ICAO
# standard air at a real altitude.
#
# Before this the hash's 59 °F / 29.92 inHg defaults were plain numbers, and above 1 m of
# altitude the engine read a temperature within 0.1 °C of 15 °C, or a pressure within
# 0.5 hPa of 1013.25 hPa, as "not given" and flew the ICAO standard value instead. So a real
# 29.92 inHg reading at 5000 ft flew as about 24.9 inHg, and a real 59 °F as about 41 °F.

require "ballistics_engine"

failures = 0
def check(cond, msg)
  puts(cond ? "ok:   #{msg}" : "FAIL: #{msg}")
  cond ? 0 : 1
end

BASE = {
  "bc" => 0.5,
  "bullet_weight_grains" => 168.0,
  "muzzle_velocity_fps" => 2650.0,
  "bullet_diameter_inches" => 0.308,
  "bullet_length_inches" => 1.2,
  "sight_height_inches" => 1.5,
  "zero_distance_yards" => 100.0,
  "drag_model" => "G7",
  "max_range_yards" => 875.0
}.freeze
ALT_FT = 5000.0

def solve_at(atmosphere)
  r = BallisticsEngine.solve(BASE.merge("atmosphere" => atmosphere))
  [r["impact_velocity_fps"], r["points"].last["y"]]
end

def zero_at(atmosphere)
  BallisticsEngine.calculate_zero_angle(
    BASE.merge("target_distance_yards" => 600.0, "atmosphere" => atmosphere)
  )["zero_angle_radians"]
end

def rel(a, b)
  (a - b).abs / [b.abs, 1e-12].max
end

# ICAO standard (°C, hPa) at a geometric altitude, as the engine flies an omitted reading.
def icao_station_air(alt_m)
  radius = 6_356_766.0
  h = radius * alt_m / (radius + alt_m)
  t_k = 288.15 - 0.0065 * h
  p_pa = 101_325.0 * (t_k / 288.15)**(-9.80665 / (-0.0065 * 287.0531))
  [t_k - 273.15, p_pa / 100.0]
end

# 1. A typed sea-level pressure at altitude flies as typed.
omitted = solve_at("altitude_feet" => ALT_FT)
typed = solve_at("altitude_feet" => ALT_FT, "pressure_inhg" => 29.92)
lower = solve_at("altitude_feet" => ALT_FT, "pressure_inhg" => 29.80)
higher = solve_at("altitude_feet" => ALT_FT, "pressure_inhg" => 30.04)
failures += check(rel(typed[0], omitted[0]) > 1e-3,
                  "typed 29.92 inHg at 5000 ft differs from omitted (#{typed[0]} vs #{omitted[0]} fps)")
# Denser air slows the bullet more: v(29.80) > v(29.92) > v(30.04).
failures += check(lower[0] > typed[0] && typed[0] > higher[0],
                  "typed 29.92 inHg lies between its out-of-band neighbours " \
                  "(#{lower[0]} > #{typed[0]} > #{higher[0]})")

# 2. A typed standard temperature at altitude flies as typed.
typed_t = solve_at("altitude_feet" => ALT_FT, "temperature_f" => 59.0)
colder = solve_at("altitude_feet" => ALT_FT, "temperature_f" => 58.6)
warmer = solve_at("altitude_feet" => ALT_FT, "temperature_f" => 59.4)
failures += check(rel(typed_t[0], omitted[0]) > 1e-4,
                  "typed 59 °F at 5000 ft differs from omitted (#{typed_t[0]} vs #{omitted[0]} fps)")
# Colder air is denser: v(58.6) < v(59) < v(59.4).
failures += check(colder[0] < typed_t[0] && typed_t[0] < warmer[0],
                  "typed 59 °F lies between its out-of-band neighbours " \
                  "(#{colder[0]} < #{typed_t[0]} < #{warmer[0]})")

# 3. Omitted values still fly the ICAO standard air, exactly as before.
t_c, p_hpa = icao_station_air(ALT_FT * 0.3048)
icao = solve_at("altitude_feet" => ALT_FT, "temperature_f" => t_c * 9.0 / 5.0 + 32.0,
                "pressure_inhg" => p_hpa / 33.8639)
failures += check(rel(omitted[0], icao[0]) < 1e-9 && (omitted[1] - icao[1]).abs < 1e-9,
                  "omitted at 5000 ft flies the ICAO standard air (#{omitted} vs #{icao})")
nil_keys = begin
  solve_at("altitude_feet" => ALT_FT, "temperature_f" => nil, "pressure_inhg" => nil)
rescue TypeError => e
  e
end
failures += check(nil_keys == omitted, "nil temperature_f / pressure_inhg are omitted (#{nil_keys.inspect})")

# 4. At sea level nothing changes: the typed defaults equal the omitted ones.
failures += check(solve_at("temperature_f" => 59.0, "pressure_inhg" => 29.92) == solve_at({}),
                  "at sea level typed 59 °F / 29.92 inHg equal omitted")

# 5. calculate_zero_angle reads the atmosphere the same way.
z_omitted = zero_at("altitude_feet" => ALT_FT)
z_typed = zero_at("altitude_feet" => ALT_FT, "pressure_inhg" => 29.92)
z_typed_t = zero_at("altitude_feet" => ALT_FT, "temperature_f" => 59.0)
failures += check(z_typed != z_omitted,
                  "zero: typed 29.92 inHg at 5000 ft differs from omitted (#{z_typed} vs #{z_omitted})")
failures += check(z_typed_t != z_omitted,
                  "zero: typed 59 °F at 5000 ft differs from omitted (#{z_typed_t} vs #{z_omitted})")

puts(failures.zero? ? "\nALL CHECKS PASSED" : "\n#{failures} CHECK(S) FAILED")
exit(failures.zero? ? 0 : 1)
