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
      unless File.exist?(filename = 'config/initializers/brick.rb')
        # See if we can make suggestions for additional_references
        resembles_fks = []
        possible_additional_references = (relations = ::Brick.relations).each_with_object([]) do |v, s|
          v.last[:cols].each do |col, _type|
            col_down = col.downcase
            is_possible = true
            if col_down.end_with?('_id')
              col_down = col_down[0..-4]
            elsif col_down.end_with?('id')
              col_down = col_down[0..-3]
              is_possible = false if col_down.length < 3 # Was it simply called "id" or something else really short?
            elsif col_down.start_with?('id_')
              col_down = col_down[3..-1]
            elsif col_down.start_with?('id')
              col_down = col_down[2..-1]
            else
              is_possible = false
            end
            if col_down.start_with?('fk_')
              is_possible = true
              col_down = col_down[3..-1]
            end
            # This possible key not really a primary key and not yet used as a foreign key?
            if is_possible && !(relation = relations.fetch(v.first, {}))[:pkey].first&.last&.include?(col) &&
               !relations.fetch(v.first, {})[:fks]&.any? { |_k, v| v[:is_bt] && v[:fk] == col }
              if (relations.fetch(f_table = col_down, nil) ||
                 relations.fetch(f_table = ActiveSupport::Inflector.pluralize(col_down), nil)) &&
                 # Looks pretty promising ... just make sure a model file isn't present
                 !File.exist?("app/models/#{ActiveSupport::Inflector.singularize(v.first)}.rb")
                s << "['#{v.first}', '#{col}', '#{f_table}']"
              else
                resembles_fks << "#{v.first}.#{col}"
              end
            end
          end
          s
        end

        bar = case possible_additional_references.length
              when 0
+"# Brick.additional_references = [['orders', 'customer_id', 'customer'],
#                                ['customer', 'region_id', 'regions']]"
              when 1
+"# # Here is a possible additional reference that has been auto-identified for the #{ActiveRecord::Base.connection.current_database} database:
# Brick.additional_references = [[#{possible_additional_references.first}]"
              else
+"# # Here are possible additional references that have been auto-identified for the #{ActiveRecord::Base.connection.current_database} database:
# Brick.additional_references = [
#   #{possible_additional_references.join(",\n#   ")}
# ]"
              end
      if resembles_fks.length > 0
        bar << "\n# # Columns named somewhat like a foreign key which you may want to consider:
# #   #{resembles_fks.join(', ')}"
      end

      create_file(filename, "# frozen_string_literal: true

# # Settings for the Brick gem
# # (By default this auto-creates models, controllers, views, and routes on-the-fly.)

# # Normally all are enabled in development mode, and for security reasons only models are enabled in production
# # and test.  This allows you to either (a) turn off models entirely, or (b) enable controllers, views, and routes
# # in production.
# Brick.enable_routes = true # Setting this to \"false\" will disable routes in development
# Brick.enable_models = false
# Brick.enable_controllers = true # Setting this to \"false\" will disable controllers in development
# Brick.enable_views = true # Setting this to \"false\" will disable views in development

# # By default models are auto-created for database views, and set to be read-only.  This can be skipped.
# Brick.skip_database_views = true

# # Any tables or views you'd like to skip when auto-creating models
# Brick.exclude_tables = ['custom_metadata', 'version_info']

# # Class that auto-generated models should inherit from
# Brick.models_inherit_from = ApplicationRecord

# # When table names have specific prefixes automatically place them in their own module with a table_name_prefix.
# Brick.table_name_prefixes = { 'nav_' => 'Navigation' }

# # Additional table references which are used to create has_many / belongs_to associations inside auto-created
# # models.  (You can consider these to be \"virtual foreign keys\" if you wish)...  You only have to add these
# # in cases where your database for some reason does not have foreign key constraints defined.  Sometimes for
# # performance reasons or just out of sheer laziness these might be missing.
# # Each of these virtual foreign keys is defined as an array having three values:
# #   foreign table name / foreign key column / primary table name.
# # (We boldly expect that the primary key identified by ActiveRecord on the primary table will be accurate,
# # usually this is \"id\" but there are some good smarts that are used in case some other column has been set
# # to be the primary key.)
#{bar}

# # Skip creating a has_many association for these (only retain the belongs_to built from this additional_reference).
# # (Uses the same exact three-part format as would define an additional_reference)
# # Say for instance that we didn't care to display the favourite colours that users have:
# Brick.exclude_hms = [['users', 'favourite_colour_id', 'colours']]

# # Skip showing counts for these specific has_many associations when building auto-generated #index views.
# # When there are related tables with a significant number of records, this can lessen the load on the database
# # considerably, sometimes fixing what might appear to be an index page that just \"hangs\" for no apparent reason.
Brick.skip_index_hms = ['User.litany_of_woes']

# # By default primary tables involved in a foreign key relationship will indicate a \"has_many\" relationship pointing
# # back to the foreign table.  In order to represent a \"has_one\" association instead, an override can be provided
# # using the primary model name and the association name which you instead want to have treated as a \"has_one\":
# Brick.has_ones = [['User', 'user_profile']]
# # If you want to use an alternate name for the \"has_one\", such as in the case above calling the association \"profile\"
# # instead of \"user_profile\", then apply that as a third parameter like this:
# Brick.has_ones = [['User', 'user_profile', 'profile']]

# # We normally don't show the timestamp columns \"created_at\", \"updated_at\", and \"deleted_at\", and also do
# # not consider them when finding associative tables to support an N:M association.  (That is, ones that can be a
# # part of a has_many :through association.)  If you want to use different exclusion columns than our defaults
# # then this setting resets that list.  For instance, here is an override that is useful in the Sakila sample
# # database:
# Brick.metadata_columns = ['last_update']

# # Columns for which to add a validate presence: true even though the database doesn't have them marked as NOT NULL.
# # Designated by <table name>.<column name>
# Brick.not_nullables = ['users.name']

# # A simple DSL is available to allow more user-friendly display of objects.  Normally a user object might be shown
# # as its first non-metadata column, or if that is not available then something like \"User #45\" where 45 is that
# # object's ID.  If there is no primary key then even that is not possible, so the object's .to_s method is called.
# # To override these defaults and specify exactly what you want shown, such as first names and last names for a
# # user, then you can use model_descrips like this, putting expressions with property references in square brackets:
# Brick.model_descrips = { 'User' => '[profile.firstname] [profile.lastname]' }

# # Specify STI subclasses either directly by name or as a general module prefix that should always relate to a specific
# # parent STI class.  The prefixed :: here for these examples is mandatory.  Also having a suffixed :: means instead of
# # a class reference, this is for a general namespace reference.  So in this case requests for, say, either of the
# # non-existant classes Animals::Cat or Animals::Goat (or anything else with the module prefix of \"Animals::\" would
# # build a model that inherits from Animal.  And a request specifically for the class Snake would build a new model
# # that inherits from Reptile, and no other request would do this -- only specifically for Snake.  The ending ::
# # indicates that it's a module prefix instead of a specific class name.
# Brick.sti_namespace_prefixes = { '::Animals::' => 'Animal',
#                                  '::Snake' => 'Reptile' }

# # Polymorphic associations must be explicitly specified, which is as easy as providing a model name and polymorphic
# # association name like this:
# Brick.polymorphics = ['Comment.commentable', 'Image.imageable']

# # If a default route is not supplied, Brick attempts to find the most \"central\" table and wires up the default
# # route to go to the :index action for what would be a controller for that table.  You can specify any controller
# # name and action you wish in order to override this and have that be the default route when none other has been
# # specified in routes.rb or elsewhere.  (Or just use an empty string in order to disable this behaviour.)
# Brick.default_route_fallback = 'customers' # This defaults to \"customers/index\"
# Brick.default_route_fallback = 'orders/outstanding' # Example of a non-RESTful route
# Brick.default_route_fallback = '' # Omits setting a default route in the absence of any other
")
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
