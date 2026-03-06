# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "custom_id"
require "active_record"
require "minitest/autorun"

# ---------------------------------------------------------------------------
# In-memory SQLite database for ActiveRecord tests
# ---------------------------------------------------------------------------
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Silence ActiveRecord migration output in test runs
ActiveRecord::Migration.verbose = false

# ---------------------------------------------------------------------------
# Simulate the Rails initializer so AR models pick up CustomId::Concern
# automatically, exactly as they would in a Rails app after running
# `rails custom_id:install`.
# ---------------------------------------------------------------------------
ActiveSupport.on_load(:active_record) do
  include CustomId::Concern
end
