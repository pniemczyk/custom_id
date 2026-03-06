# frozen_string_literal: true

module CustomId
  # Hooks CustomId into a Rails application.
  #
  # When Rails loads, this Railtie exposes the +custom_id:install+ and
  # +custom_id:uninstall+ rake tasks so developers can set up the initializer
  # that auto-includes {CustomId::Concern} into every ActiveRecord model.
  class Railtie < Rails::Railtie
    railtie_name :custom_id

    rake_tasks do
      load File.expand_path("../tasks/custom_id.rake", __dir__)
    end
  end
end
