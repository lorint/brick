# frozen_string_literal: true

require 'rails/generators'
# require 'rails/generators/active_record'

module Brick
  class InstallGenerator < ::Rails::Generators::Base
    # include ::Rails::Generators::Migration

    source_root File.expand_path('templates', __dir__)
    class_option(
      :with_changes,
      type: :boolean,
      default: false,
      desc: 'Store changeset (diff) with each version'
    )

    desc 'Generates an initializer file for configuring Brick'

    def create_initializer_file
      unless File.exists?(filename = 'config/initializers/brick.rb')
        create_file filename, "# frozen_string_literal: true

# # Settings for the Brick gem
# # (By default this auto-creates models, controllers, views, and routes on-the-fly.)

# # Normally these all start out as being enabled, but can be selectively disabled:
# Brick.enable_routes = false
# Brick.enable_models = false
# Brick.enable_controllers = false
# Brick.enable_views = false

# # By default models are auto-created from database views, and set to be read-only.  This can be skipped.
# Brick.skip_database_views = true

# # Any tables or views you'd like to skip when auto-creating models
# Brick.exclude_tables = ['custom_metadata', 'version_info']

# # Additional table references which are used to create has_many / belongs_to associations inside auto-created
# # models.  (You can consider these to be \"virtual foreign keys\" if you wish)...  You only have to add these
# # in cases where your database for some reason does not have foreign key constraints defined.  Sometimes for
# # performance reasons or just out of sheer laziness these might be missing.
# # Each of these virtual foreign keys is defined as an array having three values:
# #   foreign table name / foreign key column / primary table name.
# # (We boldly expect that the primary key identified by ActiveRecord on the primary table will be accurate,
# # usually this is \"id\" but there are some good smarts that are used in case some other column has been set
# # to be the primary key.
# Brick.additional_references = [['orders', 'customer_id', 'customer'],
#                                ['customer', 'region_id', 'regions']]

# # By default primary tables involved in a foreign key relationship will indicate a \"has_many\" relationship pointing
# # back to the foreign table.  In order to represent a \"has_one\" association instead, an override can be provided
# # using the primary model name and the association name which you instead want to have treated as a \"has_one\":
# Brick.has_ones = [['User', 'user_profile']]
# # If you want to use an alternate name for the \"has_one\", such as in the case above calling the association \"profile\"
# # instead of \"user_profile\", then apply that as a third parameter like this:
# Brick.has_ones = [['User', 'user_profile', 'profile']]

# # We normally don't consider the timestamp columns \"created_at\", \"updated_at\", and \"deleted_at\" to count when
# # finding tables which can serve as associative tables in an N:M association.  That is, ones that can be a
# # part of a has_many :through association.  If you want to use different exclusion columns than our defaults
# # then this setting resets that list.  For instance, here is the override for the Sakila sample database:
# Brick.metadata_columns = ['last_updated']

# # If a default route is not supplied, Brick attempts to find the most \"central\" table and wires up the default
# # route to go to the :index action for what would be a controller for that table.  You can specify any controller
# # name and action you wish in order to override this and have that be the default route when none other has been
# # specified in routes.rb or elsewhere.  (Or just use an empty string in order to disable this behaviour.)
# Brick.default_route_fallback = 'customers' # This defaults to \"customers/index\"
# Brick.default_route_fallback = 'orders/outstanding' # Example of a non-RESTful route
# Brick.default_route_fallback = '' # Omits setting a default route in the absence of any other
"
      end
    end

    # def create_migration_file
    #   add_brick_migration('create_versions')
    #   add_brick_migration('add_object_changes_to_versions') if options.with_changes?
    # end

    # def self.next_migration_number(dirname)
    #   ::ActiveRecord::Generators::Base.next_migration_number(dirname)
    # end

  protected

    # def add_brick_migration(template)
    #   migration_dir = File.expand_path('db/migrate')
    #   if self.class.migration_exists?(migration_dir, template)
    #     ::Kernel.warn "Migration already exists: #{template}"
    #   else
    #     migration_template(
    #       "#{template}.rb.erb",
    #       "db/migrate/#{template}.rb",
    #       item_type_options: item_type_options,
    #       migration_version: migration_version,
    #       versions_table_options: versions_table_options
    #     )
    #   end
    # end

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
