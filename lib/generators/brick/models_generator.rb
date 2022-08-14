# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'

module Brick
  # Auto-generates models, controllers, or views
  class ModelsGenerator < ::Rails::Generators::Base
    include FancyGets
    # include ::Rails::Generators::Migration

    desc 'Auto-generates models, controllers, or views.'

    def brick_models
      # %%% If Apartment is active and there's no schema_to_analyse, ask which schema they want

      # Load all models
      if ::ActiveSupport.version < ::Gem::Version.new('6') ||
        ::Rails.configuration.instance_variable_get(:@autoloader) == :classic
        Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)
      else
        Zeitwerk::Loader.eager_load_all
      end

      # Generate a list of viable models that can be chosen
      longest_length = 0
      model_info = Hash.new { |h, k| h[k] = {} }
      tableless = Hash.new { |h, k| h[k] = [] }
      existing_models = ActiveRecord::Base.descendants.reject do |m|
        m.abstract_class? || !m.table_exists? || ::Brick.relations.key?(m.table_name)
      end
      models = ::Brick.relations.keys.map do |tbl|
        tbl_parts = tbl.split('.')
        tbl_parts[-1] = tbl_parts[-1].singularize
        tbl_parts.join('/').camelize
      end - existing_models.map(&:name)
      models.sort! do |a, b| # Sort first to separate namespaced stuff from the rest, then alphabetically
        is_a_namespaced = a.include?('::')
        is_b_namespaced = b.include?('::')
        if is_a_namespaced && !is_b_namespaced
          1
        elsif !is_a_namespaced && is_b_namespaced
          -1
        else
          a <=> b
        end
      end
      models.each do |m| # Find longest name in the list for future use to show lists on the right side of the screen
        if longest_length < (len = m.length)
          longest_length = len
        end
      end
      chosen = gets_list(list: models, chosen: models.dup)
      relations = ::Brick.relations
      chosen.each do |model_name|
        # If we're in a schema then make sure the module file exists
        base_module = if (model_parts = model_name.split('::')).length > 1
                        "::#{model_parts.first}".constantize
                      else
                        Object
                      end
        _built_model, code = Object.send(:build_model, relations, base_module, base_module.name, model_parts.last)
        path = ['models']
        path.concat(model_parts.map(&:underscore))
        dir = +"#{::Rails.root}/app"
        path[0..-2].each do |path_part|
          dir << "/#{path_part}"
          Dir.mkdir(dir) unless Dir.exists?(dir)
        end
        File.open("#{dir}/#{path.last}.rb", 'w') { |f| f.write code }
      end
      puts "\n*** Created #{chosen.length} model files under app/models ***"
    end

  private

    # # MySQL 5.6 utf8mb4 limit is 191 chars for keys used in indexes.
    # def item_type_options
    #   opt = { null: false }
    #   opt[:limit] = 191 if mysql?
    #   ", #{opt}"
    # end

    # def migration_version
    #   return unless (major = ActiveRecord::VERSION::MAJOR) >= 5

    #   "[#{major}.#{ActiveRecord::VERSION::MINOR}]"
    # end

    # # Class names of MySQL adapters.
    # # - `MysqlAdapter` - Used by gems: `mysql`, `activerecord-jdbcmysql-adapter`.
    # # - `Mysql2Adapter` - Used by `mysql2` gem.
    # def mysql?
    #   [
    #     'ActiveRecord::ConnectionAdapters::MysqlAdapter',
    #     'ActiveRecord::ConnectionAdapters::Mysql2Adapter'
    #   ].freeze.include?(ActiveRecord::Base.connection.class.name)
    # end

    # # Even modern versions of MySQL still use `latin1` as the default character
    # # encoding. Many users are not aware of this, and run into trouble when they
    # # try to use Brick in apps that otherwise tend to use UTF-8. Postgres, by
    # # comparison, uses UTF-8 except in the unusual case where the OS is configured
    # # with a custom locale.
    # #
    # # - https://dev.mysql.com/doc/refman/5.7/en/charset-applications.html
    # # - http://www.postgresql.org/docs/9.4/static/multibyte.html
    # #
    # # Furthermore, MySQL's original implementation of UTF-8 was flawed, and had
    # # to be fixed later by introducing a new charset, `utf8mb4`.
    # #
    # # - https://mathiasbynens.be/notes/mysql-utf8mb4
    # # - https://dev.mysql.com/doc/refman/5.5/en/charset-unicode-utf8mb4.html
    # #
    # def versions_table_options
    #   if mysql?
    #     ', { options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci" }'
    #   else
    #     ''
    #   end
    # end
  end
end
