# frozen_string_literal: true

require 'brick'
require 'rails/generators'
# require 'rails/generators/active_record'

module Brick
  class InstallGenerator < ::Rails::Generators::Base
    # include ::Rails::Generators::Migration

    # source_root File.expand_path('templates', __dir__)
    # class_option(
    #   :with_changes,
    #   type: :boolean,
    #   default: false,
    #   desc: 'Store changeset (diff) with each version'
    # )

    desc 'Generates an initializer file for configuring Brick'

    def create_initializer_file
      is_brick_file = File.exist?(filename = 'config/initializers/brick.rb')
      if (is_brick_file && (tnps = ::Brick.config.table_name_prefixes).present?) ||
                           (::Brick.config.schema_behavior[:multitenant]
         ) || !is_brick_file
        # See if we can make suggestions for additional_references and polymorphic associations
        resembles_fks = Hash.new { |h, k| h[k] = [] }
        possible_polymorphics = {}
        relations = ::Brick.relations
        if is_brick_file
          # Need to remove any currently-existing additional_references so that it doesn't cloud the discovery process:
          ::Brick.config.additional_references&.each do |ar|
            if (fks = relations.fetch(ar[0], nil)&.fetch(:fks, nil))
              fks.delete(fks.find { |k, v| v[:is_bt] && k.start_with?('(brick) ') && v[:fk] == ar[1] }&.first)
            end
          end
        end
        possible_additional_references = relations.each_with_object(Hash.new { |h, k| h[k] = [] }) do |relation, s|
          next if relation.first.is_a?(Symbol)

          this_tnp = tnps&.keys&.find { |tnp| relation.first.start_with?(tnp) }
          model_filename = "app/models/#{ActiveSupport::Inflector.singularize(relation.first)}.rb"
          relation.last[:cols].each do |col, type|
            col_down = col.downcase

            if (is_possible_poly = ['character varying', 'text'].include?(type.first))
              if col_down.end_with?('_type')
                poly_type_cut_length = -6
                col_down = col_down[0..-6]
              elsif col_down.end_with?('type')
                poly_type_cut_length = -5
                col_down = col_down[0..-5]
              else
                is_possible_poly = false
              end
              is_possible_poly = false if col_down.length < 6 # Was it simply called "type" or something else really short?
              if is_possible_poly && !File.exist?(model_filename) # Make sure a model file isn't present
                possible_polymorphics["#{relation.first}.#{col_down}"] = "'#{relation.first}.#{col[0..poly_type_cut_length]}'"
                next
              end
            end

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
            elsif col_down.start_with?('fk')
              is_possible = true
              col_down = col_down[2..-1]
            end
            # This possible key not really a primary key and not yet used as a foreign key?
            if is_possible && !relation.last[:pkey].first&.last&.include?(col) &&
               !relation.last[:fks]&.any? { |_k, v| v[:is_bt] && v[:fk] == col } &&
               # Starting to look promising ... make sure a model file isn't present
               !File.exist?(model_filename)
              if (
                  (relations.fetch(f_table = col_down, nil) ||
                   relations.fetch(f_table = ActiveSupport::Inflector.pluralize(col_down), nil)
                  ) && s["#{relation.first}.#{col_down}"] << "['#{relation.first}', '#{col}', '#{f_table}']"
                 ) ||
                 (
                  this_tnp && (full_col_down = this_tnp + col_down) &&
                  (relations.fetch(f_table = full_col_down, nil) ||
                   relations.fetch(f_table = ActiveSupport::Inflector.pluralize(full_col_down), nil)
                  ) && s["#{relation.first}.#{full_col_down}"] << "['#{relation.first}', '#{col}', '#{f_table}']"
                 )
                # Found a possible_additional_reference (and set as the last action of the conditional check above)
              else
                resembles_fks["#{relation.first}.#{col_down}"] << "#{relation.first}.#{col}"
              end
            end
          end
        end

        possible_polymorphics.each_key do |k|
          # Also matching one of the FK suggestions means it could be polymorphic,
          # so delete any suggestions for a FK of the same name and only recommend
          # the polymorphic association.
          if resembles_fks.key?(k)
            resembles_fks.delete(k)
          elsif possible_additional_references.key?(k)
            possible_additional_references.delete(k)
          else
            # While this one has a type, it's missing a corresponding ID column so it isn't polymorphic
            possible_polymorphics.delete(k)
          end
        end
        resembles_fks = resembles_fks.values.flatten

        # Brick additional references
        # Used to have:  ActiveRecord::Base.connection.current_database  -- but this doesn't work with SQLite3Adapter
        current_db = ActiveRecord::Base.connection&.instance_variable_get(:@config)&.fetch(:database, nil)
        bar = case (possible_additional_references = possible_additional_references.values.flatten).length
              when 0
+"  # Brick.additional_references = [['orders', 'customer_id', 'customer'],
  #                                ['customer', 'region_id', 'regions']]"
              when 1
+"  # # Here is a possible additional reference that has been auto-identified for the #{current_db} database:
  # Brick.additional_references = [#{possible_additional_references.first}]"
              else
+"  # # Here are possible additional references that have been auto-identified for the #{current_db} database:
  # Brick.additional_references = [
  #   #{possible_additional_references.join(",\n  #   ")}
  # ]"
              end
      if resembles_fks.length > 0
        bar << "\n  # # Columns named somewhat like a foreign key which you may want to consider:
  # #   #{resembles_fks.join(', ')}"
      end

      poly = case (possible_polymorphics = possible_polymorphics.values.flatten.map { |poss_poly| "#{poss_poly} => nil"}).length
      when 0
" like this:
  # Brick.polymorphics = {
  #                        'comments.commentable' => nil,
  #                        'images.imageable' => nil
  #                      }"
      when 1
".
  # # Here is a possible polymorphic association that has been auto-identified for the #{current_db} database:
  # Brick.polymorphics = { #{possible_additional_references.first} }"

      else
".
  # # Here are possible polymorphic associations that have been auto-identified for the #{current_db} database:
  # Brick.polymorphics = {
  #   #{possible_polymorphics.join(",\n  #   ")}
  # }"
      end

      create_file(filename, "# frozen_string_literal: true

# Settings for the Brick gem
# (By default this auto-creates models, controllers, views, and routes on-the-fly.)

if ActiveRecord::Base.respond_to?(:brick_select) && !::Brick.initializer_loaded
  # Mode -- generally :on or :off, or only in :development.  Also available is :diag_env which enables only
  # when the environment variable BRICK is set.
  Brick.mode = :development
  # Can be further overridden by placing this line in development.rb / test.rb / production.rb:
  # # Brick.mode = :on # (or :off to entirely disable)

  # # Custom path prefix to apply to all auto-generated Brick routes.  Also causes auto-generated controllers
  # # to be created inside a module with the same name.
  # ::Brick.path_prefix = 'brick'

  # # Normally all are enabled in development mode, and for security reasons only models are enabled in production
  # # and test.  This allows you to either (a) turn off models entirely, or (b) enable controllers, views, and routes
  # # in production.
  # Brick.enable_routes = true # Setting this to \"false\" will disable routes in development
  # Brick.enable_models = false
  # Brick.enable_controllers = true # Setting this to \"false\" will disable controllers in development
  # Brick.enable_views = true # Setting this to \"false\" will disable views in development

  # # If The Brick sees that RSwag gem is present, it allows for API resources to be automatically served out.
  # # You can configure one or more root path(s) for these resources, and when there are multiple then an attempt
  # # is made to return data from that version of the view or table name, or the most recent prior to that version:
  # ::Brick.api_roots = ['/api/v1/']
  # # You may also want to add an OpenAPI 3.0 documentation endpoint using Rswag::Ui:
  # Rswag::Ui.configure do |config|
  #   config.swagger_endpoint '/api-docs/v1/swagger.json', 'API V1 Docs'
  # end

  # # To establish OpenAPI 3.0 documentation endpoints without use of Rswag, such as if you want to use fancier
  # # tooling such as Scalar API or similar, the Brick also allows you to establish endpoints directly:
  # ::Brick.swagger_endpoint '/api-docs/v1/swagger.json', 'API V1 Docs'

  # # By default models are auto-created for database views, and set to be read-only.  This can be skipped.
  # Brick.skip_database_views = true

  # # Any tables or views you'd like to skip when auto-creating models
  # Brick.exclude_tables = ['custom_metadata', 'version_info']

  # # Class that auto-generated models should inherit from
  # Brick.models_inherit_from = ApplicationRecord

  # # Class that auto-generated controllers should inherit from
  # # (Would generally want to un-comment this line if you want to enforce any authentication which is
  # # established in your ApplicationController, or for auto-created controllers to support
  # # Turbo Stream broadcasts.)
  # ::Brick.controllers_inherit_from = 'ApplicationController'

  # # When table names have specific prefixes automatically place them in their own module with a table_name_prefix.
  #{
    if tnps
      "Brick.table_name_prefixes = #{tnps.inspect}"
    else
      "# Brick.table_name_prefixes = { 'nav_' => 'Navigation' }"
    end
  }

  # # COLUMN SEQUENCING AND INCLUSION / EXCLUSION

  # # By default if there is a primary key present then rows in an index view are ordered by this primary key.  To
  # # use a different rule for doing ORDER BY, you can override this default ordering done by The Brick, for instance
  # # to have the rows in a contact list sorted by email:
  # Brick.order = { 'contacts' => { _brick_default: :email } }
  # # or by last name then first name:
  # Brick.order = { 'contacts' => { _brick_default: [:lastname, :firstname] } }
  # # Totally legitimate to have the default order be the name of a belongs_to or has_many association instead of an
  # # actual column name, in which case for has_many it just orders by the count of how many records are associated,
  # # and for belongs_to it's based on the primary table's DSL if any is defined (since that is what is used to
  # # calculate what is shown when a foreign table lists out related records).  If contacts relates to addresses,
  # # then this is perfectly fine:
  # Brick.order = { 'contacts' => { _brick_default: :address } }
  # # You can even have a specific custom clause used in the ORDER BY.  In this case it is recommended to include a
  # # special placeholder for the table name with the sequence \"^^^\".  Here is an example of having the default
  # # ordering happening on the \"code\" column, and also defining custom sorting to be done, in this case proper
  # # ordering if that code is stored as a dotted numeric value:
  # Brick.order = { 'document_trees' => { _brick_default: :code,
  #                                       code: \"ORDER BY STRING_TO_ARRAY(^^^.code, '.')::int[]\" } }

  # # Sequence of columns for each model.  This also allows you to add read-only calculated columns in the same
  # # kind of way that they can be added in the include: portion of include/exclude columns, below.
  # # Designated by { <table name> => [<column name>, <column name>] }
  # Brick.column_sequence = { 'users' => ['email', 'profile.firstname', 'profile.lastname'] }

  # # Specific columns to include or exclude for each model.  If there are only inclusions then only those
  # # columns show.  If there are any exclusions then all non-excluded columns are attempted to be shown,
  # # which negates the usefulness of inclusions except to add calculated column detail built from DSL.
  # # Designated by <table name>.<column name>
  # Brick.column_sequence = { 'users' =>   { include: ['email', 'profile.firstname', 'profile.lastname'] },
  #                           'profile' => { exclude: ['birthdate'] } }

  # # When rendering the grid on index pages, a default number of columns to keep as \"sticky\" so that they remain
  # # at the left of the grid while scrolling.  By default this is 0 extra columns -- only the link to that
  # # object's show / edit page is sticky.  And this would add one extra column in the mix:
  # Brick.sidescroll = { num_frozen_columns: 1 }
  # # As well if you would like to customise this for specific resources, that is possible:
  # Brick.sidescroll = { num_frozen_columns: 0,
  #                      'products' => { num_frozen_columns: 2 } }

  # # EXTRA FOREIGN KEYS AND OTHER HAS_MANY SETTINGS

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

  # # Custom columns to add to a table, minimally defined with a name and DSL string.
  # Brick.custom_columns = { 'users' =>  { messages:    ['[COUNT(messages)] messages', 'messages'] },
  #                          'orders' => { salesperson:  '[salesperson.first] [salesperson.last]',
  #                                        products:    ['[COUNT(order_items.product)] products', 'order_items.product' ] }
  #                        }

  # # Skip creating a has_many association for these (only retain the belongs_to built from this additional_reference).
  # # (Uses the same exact three-part format as would define an additional_reference)
  # # Say for instance that we didn't care to display the favourite colours that users have:
  # Brick.exclude_hms = [['users', 'favourite_colour_id', 'colours']]

  # # Skip showing counts for these specific has_many associations when building auto-generated #index views.
  # # When there are related tables with a significant number of records (generally 100,000 or more), this can lessen
  # # the load on the database considerably, sometimes fixing what might appear to be an index page that just \"hangs\"
  # # for no apparent reason.
  # Brick.skip_index_hms = ['User.litany_of_woes']

  # # By default primary tables involved in a foreign key relationship will indicate a \"has_many\" relationship pointing
  # # back to the foreign table.  In order to represent a \"has_one\" association instead, an override can be provided
  # # using the primary model name and the association name which you instead want to have treated as a \"has_one\":
  # Brick.has_ones = [['User', 'user_profile']]
  # # If you want to use an alternate name for the \"has_one\", such as in the case above calling the association \"profile\"
  # # instead of \"user_profile\", then apply that as a third parameter like this:
  # Brick.has_ones = [['User', 'user_profile', 'profile']]

  # # Automatically establish #accepts_nested_attributes_for logic on has_many and has_one associations.
  # # This video to demonstrates how this works:  https://github.com/lorint/brick/assets/5301131/82ac4f6d-bc23-4a55-adab-bc754bcb0f26
  # Brick.nested_attributes = { 'User' => ['profile', 'posts'] }

  # # Auto-create specific has_many ___, through: ___ associations
  # Brick.hmts = [['recipes', 'recipe_ingredients', 'ingredients']]

  # # Treat specific tables as being associative, using them to wire up HMT relationships.  (This is normally the
  # # default when a table contains only foreign keys, but when that otherwise associative \"JOIN\" table has any
  # # other data columns, it is considered a data table and not really associative.  This overrides in order to
  # # have a table to still be treated as associative, causing HMTs to be auto-generated.)
  # Brick.treat_as_associative = ['flights']

  # # Further, if you want to present a given associative table in various ways then you can choose a 2D
  # # constellation map of checkboxes, or bezier curves showing the association between a list at the left and at
  # # the right.  Indicating just :bezier is the same as :bezier_full, which shows the full list of all possible
  # # things that can be associated.  :bezier_union shows just the ones that are currently wired up, and
  # # :bezier_excluded, :bezier_excluded_left, or :bezier_excluded_right shows the ones not yet wired up.
  # Brick.treat_as_associative = { 'flights' => { bezier: ['departure.code', 'arrival.code'] },
  #                                'crew' => { constellation: ['flight', 'personnel', '[used ? [used it!] : []]'] } }

  # # We normally don't show the timestamp columns \"created_at\", \"updated_at\", and \"deleted_at\", and also do
  # # not consider them when finding associative tables to support an N:M association.  (That is, ones that can be a
  # # part of a has_many :through association.)  If you want to use different exclusion columns than our defaults
  # # then this setting resets that list.  For instance, here is an override that is useful in the Sakila sample
  # # database:
  # Brick.metadata_columns = ['last_update']

  # # Columns for which to add a validate presence: true even though the database doesn't have them marked as NOT NULL.
  # # Designated by <table name>.<column name>
  # Brick.not_nullables = ['users.name']

  # # String or text columns which for editing purposes should be treated as JSON.  Format for the hash is:
  # # { table_name => [column names] }
  # Brick.json_columns = { 'users' => ['info'] }

  # # FRIENDLY DSL

  # # A simple DSL is available to allow more user-friendly display of objects.  Normally a user object might be shown
  # # as its first non-metadata column, or if that is not available then something like \"User #42\" where 42 is that
  # # object's ID.  If there is no primary key then even that is not possible, so the object's .to_s method is called.
  # # To override these defaults and specify exactly what you want shown, such as first names and last names for a
  # # user, then you can use model_descrips like this, putting expressions with property references in square brackets:
  # Brick.model_descrips = { 'User' => '[profile.firstname] [profile.lastname]' }

  # # FULL TEXT SEARCH
  # # You can enable Elasticsearch support by adding the elasticsearch-model and elasticsearch-rails gems, and either
  # # having a copy of Opensearch or Elasticsearch locally installed on the same machine listening on port 9200, or by
  # # setting the ELASTICSEARCH_URL environment variable to point to the URI of a search machine.
  # # With that configured, you can pick specific table names and permissions for search and update by putting them in
  # # a hash like this:
  # Brick.elasticsearch_models = { 'notes' => 'crud', 'issues' => 'cru', 'orders' => 'r' }
  # # or to blanketly enable all models to have auto-updating CRUD behaviour when there are ActiveRecord changes, use:
  # Brick.elasticsearch_models = :all
  # # As well there is another permission available -- the 'i' permission -- which will auto-create an index if it
  # # is missing.  If you set 'icrud' for a model it will auto-create an index, or to always do this for all models
  # # then you can specify \"full control\" like this:
  # Brick.elasticsearch_models = :full

  # # ERD SETTINGS

  # # By default the Entity Relationship Diagram fragment which is available to be shown on the Grid page includes
  # # primary and foreign keys.  In order for it to show all columns in all cases, set this value to +true+:
  # Brick.config.erd_show_columns = true
  # # or to show all columns for specific tables, supply an array of model names:
  # Brick.config.erd_show_columns = ['User', 'OrderDetail']

  # # SINGLE TABLE INHERITANCE

  # # Specify STI subclasses either directly by name or as a general module prefix that should always relate to a specific
  # # parent STI class.  The prefixed :: here for these examples is mandatory.  Also having a suffixed :: means instead of
  # # a class reference, this is for a general namespace reference.  So in this case requests for, say, either of the
  # # non-existent classes Animals::Cat or Animals::Goat (or anything else with the module prefix of \"Animals::\" would
  # # build a model that inherits from Animal.  And a request specifically for the class Snake would build a new model
  # # that inherits from Reptile, and no other request would do this -- only specifically for Snake.  The ending ::
  # # indicates that it's a module prefix instead of a specific class name.
  # Brick.sti_namespace_prefixes = { '::Animals::' => 'Animal',
  #                                  '::Snake' => 'Reptile' }

  # # Custom inheritance_column to be used for STI.  This is by default \"type\", and applies to all models.  With this
  # # option you can change this either for specific models, or apply a new overall name generally:
  # Brick.sti_type_column = 'sti_type'
  # Brick.sti_type_column = { 'rails_type' => ['sales.specialoffer'] }

  # # POLYMORPHIC ASSOCIATIONS

  # # Polymorphic associations are set up by providing a model name and polymorphic association name#{poly}

  # # MULTITENANCY VIA THE ROS-APARTMENT GEM

  # # If you are using the ros-apartment gem along with Postgres then you can have automatic detection of polymorphic
  # # type names (model class names listed in a column such as imageable_type) by choosing a schema that is loaded up
  # # with data that represents the full range of the various polymorphic has_many classes that should be associated.
  # Brick.schema_behavior = :namespaced
#{Brick.config.schema_behavior.present? ? "  Brick.schema_behavior = { multitenant: { schema_to_analyse: #{
  Brick.config.schema_behavior[:multitenant]&.fetch(:schema_to_analyse, nil).inspect}" :
"  # Brick.schema_behavior = { multitenant: { schema_to_analyse: 'engineering'"
} } }
#{"
  # # Note that for each polymorphic model configured then it is better to set the list of classes up in the model
  # # file itself with a line like:
  # delegated_type :commentable, type: ['Post', 'Comment']" if ActiveRecord::Base.respond_to?(:delegated_type)}

  # # DEFAULT ROOT ROUTE

  # # If a default route is not supplied, Brick attempts to find the most \"central\" table and wires up the default
  # # route to go to the :index action for what would be a controller for that table.  You can specify any controller
  # # name and action you wish in order to override this and have that be the default route when none other has been
  # # specified in routes.rb or elsewhere.  (Or just use an empty string in order to disable this behaviour.)
  # This defaults to \"customers#index\", and if there was also a prefix set called \"admin\" then it would instead
  # go to \"admin/customers#index\".
  # Brick.default_route_fallback = 'customers'
  # Brick.default_route_fallback = 'orders#outstanding' # Example of a non-RESTful route
  # Brick.default_route_fallback = '' # Omits setting a default route in the absence of any other

  # # GENERATORS
  # # ==========

  # # MIGRATIONS

  # # Salesforce has table names which use multiple underscores in a row, more than two at a time.  This can greatly
  # # confuse some of the other underscore support put into place for Oracle table names which can have up to two
  # # underscores at a time.
  # #
  # # Setting this +true+ turns on \"salesforce mode\" which means that auto-created migrations will convert
  # # underscores in filenames and class names to the letter 'x' in order to keep the peace.
  # Brick.config.salesforce_mode = true
end
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
