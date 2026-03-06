# frozen_string_literal: true

CUSTOM_ID_INITIALIZER_PATH = CustomId::Installer::INITIALIZER_PATH.to_s

namespace :custom_id do
  desc "Install the CustomId initializer that auto-includes CustomId::Concern into ActiveRecord"
  task :install do
    result = CustomId::Installer.install!(Rails.root)
    case result
    when :created then puts "  #{"create".ljust(10)} #{CUSTOM_ID_INITIALIZER_PATH}"
    when :skipped then puts "  #{"skip".ljust(10)} #{CUSTOM_ID_INITIALIZER_PATH} already exists"
    end
  end

  desc "Remove the CustomId initializer"
  task :uninstall do
    result = CustomId::Installer.uninstall!(Rails.root)
    case result
    when :removed then puts "  #{"remove".ljust(10)} #{CUSTOM_ID_INITIALIZER_PATH}"
    when :skipped then puts "  #{"skip".ljust(10)} #{CUSTOM_ID_INITIALIZER_PATH} not found"
    end
  end

  namespace :db do
    # Resolves an ActiveRecord connection for an optional +database_key+.
    #
    # * When +database_key+ is nil or blank the default AR connection is returned.
    # * When a key is given the matching config for the current Rails environment is
    #   looked up via +configurations.find_db_config+.  A named abstract AR subclass
    #   (CustomId::RakeDbProxy) is used so the global default connection is never replaced.
    # * Rails 7.2+ requires a named class for +establish_connection+; assigning to a
    #   constant gives the class a non-nil +name+ so the check passes.
    # * Aborts with a list of valid database names when the key is unknown.
    resolve_connection = lambda do |database_key|
      return ActiveRecord::Base.connection if database_key.nil? || database_key.strip.empty?

      db_config = ActiveRecord::Base.configurations.find_db_config(database_key)
      unless db_config
        all_configs = ActiveRecord::Base.configurations.configurations
        available = all_configs.select { |c| c.env_name == Rails.env }.reject(&:replica?).map(&:name).join(", ")
        abort "  error: Unknown database \"#{database_key}\". " \
              "Available for \"#{Rails.env}\": #{available}"
      end

      unless CustomId.const_defined?(:RakeDbProxy, false)
        proxy = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        CustomId.const_set(:RakeDbProxy, proxy)
      end
      CustomId::RakeDbProxy.establish_connection(db_config)
      CustomId::RakeDbProxy.connection
    end

    desc "Enable the pgcrypto PostgreSQL extension required by the DB functions [DATABASE]"
    task :enable_pgcrypto, [:database] => :environment do |_task, args|
      conn = resolve_connection.call(args[:database])
      unless CustomId::DbExtension::PG_ADAPTERS.include?(conn.adapter_name.downcase)
        abort "  error: pgcrypto is a PostgreSQL extension; adapter is #{conn.adapter_name}"
      end
      conn.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
      db_tag = args[:database].presence ? " (db=#{args[:database]})" : ""
      puts "  #{"create".ljust(10)} pgcrypto extension#{db_tag}"
    rescue ActiveRecord::StatementInvalid => e
      abort "  error: #{e.message}"
    end

    desc "Install the shared custom_id_base58() DB function (PG/MySQL only) [DATABASE]"
    task :install_function, [:database] => :environment do |_task, args|
      conn = resolve_connection.call(args[:database])
      CustomId::DbExtension.install_generate_function!(conn)
      puts "  #{"create".ljust(10)} custom_id_base58() function"
    rescue NotImplementedError => e
      abort "  error: #{e.message}"
    end

    desc "Remove the shared custom_id_base58() DB function (PG/MySQL only) [DATABASE]"
    task :uninstall_function, [:database] => :environment do |_task, args|
      conn = resolve_connection.call(args[:database])
      CustomId::DbExtension.uninstall_generate_function!(conn)
      puts "  #{"remove".ljust(10)} custom_id_base58() function"
    rescue NotImplementedError => e
      abort "  error: #{e.message}"
    end

    desc "Add a database-level trigger on TABLE with PREFIX [COLUMN=id] [SIZE=16] [DATABASE]"
    task :add_trigger, %i[table prefix column size database] => :environment do |_task, args|
      table = args[:table]
      prefix = args[:prefix]
      abort 'Usage: rails "custom_id:db:add_trigger[table,prefix,column,size,database]"' if table.nil? || prefix.nil?
      column = (args[:column].presence || "id").to_sym
      size = (args[:size].presence || "16").to_i
      conn = resolve_connection.call(args[:database])
      CustomId::DbExtension.install_trigger!(conn, table, prefix: prefix, column: column, size: size)
      db_tag = args[:database].presence ? " (db=#{args[:database]})" : ""
      puts "  #{"create".ljust(10)} trigger on #{table}.#{column}#{db_tag} (prefix=#{prefix}, size=#{size})"
      if CustomId::DbExtension::MYSQL_ADAPTERS.include?(conn.adapter_name.downcase)
        warn "  warn       MySQL: pair this trigger with `cid \"#{prefix}\"` on the model."
        warn "             Without cid, ActiveRecord reads LAST_INSERT_ID() = 0 for string PKs"
        warn "             and nil for other trigger-managed columns after INSERT."
        warn "             The trigger still fires for raw SQL inserts that bypass ActiveRecord."
      end
    rescue NotImplementedError => e
      abort "  error: #{e.message}"
    end

    desc "Remove the database-level trigger from TABLE [COLUMN=id] [DATABASE]"
    task :remove_trigger, %i[table column database] => :environment do |_task, args|
      table = args[:table]
      abort 'Usage: rails "custom_id:db:remove_trigger[table,column,database]"' if table.nil?
      column = (args[:column].presence || "id").to_sym
      conn = resolve_connection.call(args[:database])
      CustomId::DbExtension.uninstall_trigger!(conn, table, column: column)
      db_tag = args[:database].presence ? " (db=#{args[:database]})" : ""
      puts "  #{"remove".ljust(10)} trigger on #{table}.#{column}#{db_tag}"
    rescue NotImplementedError => e
      abort "  error: #{e.message}"
    end
  end
end
