# frozen_string_literal: true

require_relative "lib/custom_id/version"

Gem::Specification.new do |spec|
  spec.name    = "custom_id"
  spec.version = CustomId::VERSION
  spec.authors = ["Pawel Niemczyk"]
  spec.email   = ["pniemczyk.info@gmail.com"]

  spec.summary     = "Prefixed, Stripe-style custom IDs for ActiveRecord models"
  spec.description = <<~DESC
    CustomId generates unique, human-readable, prefixed string IDs (e.g. "usr_7xKmN2pQ…")
    for ActiveRecord models. Inspired by Stripe-style identifiers. Supports embedding
    shared characters from related model IDs, custom target columns, configurable
    random-part length, and an optional PostgreSQL trigger-based alternative.
  DESC
  spec.homepage = "https://github.com/pniemczyk/custom_id"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = "https://github.com/pniemczyk/custom_id"
  spec.metadata["changelog_uri"]         = "https://github.com/pniemczyk/custom_id/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/tasks/*.rake",
    "llms/**/*.md",
    "AGENTS.md",
    "CLAUDE.md",
    "README.md",
    "LICENSE.txt",
    "CHANGELOG.md"
  ]

  spec.require_paths = ["lib"]

  # Alphabetical within section
  spec.add_dependency "activerecord",  ">= 7.0", "< 9"
  spec.add_dependency "activesupport", ">= 7.0", "< 9"
  spec.add_dependency "railties",      ">= 7.0", "< 9"
end
