# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

# Build the Rust cdylib and install it as "ballistics_engine_rb.{so,bundle}".
# The target name must match the crate's [lib] name so the magnus-generated
# Init_ballistics_engine_rb symbol lines up with `require "ballistics_engine_rb"`.
create_rust_makefile("ballistics_engine_rb")
