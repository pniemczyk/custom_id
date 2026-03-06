# frozen_string_literal: true

require_relative "custom_id/version"
require_relative "custom_id/concern"
require_relative "custom_id/installer"
require_relative "custom_id/db_extension"

module CustomId
  class Error < StandardError; end
end

require "custom_id/railtie" if defined?(Rails::Railtie)
