# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'

module Brick
  # Auto-generates models, controllers, or views
  class ModelGenerator < ::Rails::Generators::Base
    include FancyGets
    # include ::Rails::Generators::Migration

    # # source_root File.expand_path('templates', __dir__)
    # class_option(
    #   :with_changes,
    #   type: :boolean,
    #   default: false,
    #   desc: 'Add IMPORT_TEMPLATE to model'
    # )

    desc 'Auto-generates models, controllers, or views.'

    def brick_model
      # %%% If Apartment is active, ask which schema they want

      # Load all models
      Rails.configuration.eager_load_namespaces.select { |ns| ns < Rails::Application }.each(&:eager_load!)

      # Generate a list of viable models that can be chosen
      longest_length = 0
      model_info = Hash.new { |h, k| h[k] = {} }
      tableless = Hash.new { |h, k| h[k] = [] }
      models = ActiveRecord::Base.descendants.reject do |m|
        trouble = if m.abstract_class?
                    true
                  elsif !m.table_exists?
                    tableless[m.table_name] << m.name
                    ' (No Table)'
                  else
                    this_f_keys = (model_info[m][:f_keys] = m.reflect_on_all_associations.select { |a| a.macro == :belongs_to }) || []
                    column_names = (model_info[m][:column_names] = m.columns.map(&:name) - [m.primary_key, 'created_at', 'updated_at', 'deleted_at'] - this_f_keys.map(&:foreign_key))
                    if column_names.empty? && this_f_keys && !this_f_keys.empty?
                      fk_message = ", although #{this_f_keys.length} foreign keys"
                      " (No columns#{fk_message})"
                    end
                  end
        # puts "#{m.name}#{trouble}" if trouble&.is_a?(String)
        trouble
      end
      models.sort! do |a, b| # Sort first to separate namespaced stuff from the rest, then alphabetically
        is_a_namespaced = a.name.include?('::')
        is_b_namespaced = b.name.include?('::')
        if is_a_namespaced && !is_b_namespaced
          1
        elsif !is_a_namespaced && is_b_namespaced
          -1
        else
          a.name <=> b.name
        end
      end
      models.each do |m| # Find longest name in the list for future use to show lists on the right side of the screen
        # Strangely this can't be inlined since it assigns to "len"
        if longest_length < (len = m.name.length)
          longest_length = len
        end
      end
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
