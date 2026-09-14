Gem::Specification.new do |spec|
  spec.name          = "ballistics-engine"
  spec.version       = "0.39.0"
  spec.authors       = ["Alex Jokela"]
  spec.email         = ["email@tinycomputers.io"]

  spec.summary       = "High-performance ballistics calculations engine"
  spec.description   = "Ruby bindings for ballistics-engine - A high-performance Rust-based ballistics calculations library with 4-DOF trajectory modeling, wind deflection, atmospheric effects, and more."
  spec.homepage      = "https://github.com/ajokela/ballistics-engine-rb"
  spec.license       = "MIT OR Apache-2.0"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://docs.ballistics.rs"

  # Specify which files should be added to the gem when it is released.
  #
  # Cargo.lock is load-bearing here and its absence must not be quiet. extconf.rb
  # compiles the extension on the INSTALLING machine, so the lockfile that ships
  # inside the gem is what pins the dependency graph every user builds against.
  # A Dir[] glob that fails to match simply yields nothing, so before this guard a
  # build from a clean checkout produced a perfectly valid-looking gem with no lock
  # in it and unpinned resolution at install time.
  lockfile = File.expand_path("Cargo.lock", __dir__)
  unless File.exist?(lockfile)
    raise <<~MSG
      Cargo.lock is missing, and this gem cannot be built without it.

      It ships inside the gem and pins what every installing machine compiles
      against; building without it would publish unpinned dependency resolution.

      Generate it with `cargo generate-lockfile` (or any cargo build), confirm it
      pins the intended ballistics-engine version, and commit it -- it is tracked
      in this repository on purpose.
    MSG
  end

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE*", "Cargo.toml", "Cargo.lock", "src/**/*.rs", "extconf.rb"]
  spec.require_paths = ["lib"]
  # Use the mkmf extension path (extconf.rb) rather than the Cargo.toml builder
  # so the compiled extension is named after the crate ("ballistics_engine_rb"),
  # matching the magnus Init symbol. The Cargo.toml builder names it after the
  # gem ("ballistics-engine"), whose hyphen can't be a Rust/C Init symbol.
  spec.extensions = ["extconf.rb"]

  # Runtime dependencies
  spec.add_dependency "rb_sys", "~> 0.9"

  # Development dependencies
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
end
