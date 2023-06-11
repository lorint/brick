# frozen_string_literal: true

require 'singleton'
require 'brick/serializers/yaml'

module Brick
  # Global configuration affecting all threads. Some thread-specific
  # configuration can be found in `brick.rb`, others in `controller.rb`.
  class Config
    include Singleton
    attr_accessor :serializer, :version_limit, :association_reify_error_behaviour,
                  :object_changes_adapter, :root_model

    def initialize
      # Variables which affect all threads, whose access is synchronized.
      @mutex = Mutex.new
      @enabled = true

      # Variables which affect all threads, whose access is *not* synchronized.
      @serializer = Brick::Serializers::YAML
    end

    def mode
      @mutex.synchronize do
        case @brick_mode
        when nil, :development
          (::Rails.env == 'development' || ENV.key?('BRICK')) ? :on : nil
        when :diag_env
          ENV.key?('BRICK') ? :on : nil
        else
          @brick_mode
        end
      end
    end

    def mode=(setting)
      @mutex.synchronize { @brick_mode = setting unless @brick_mode == :on }
    end

    # Any path prefixing to apply to all auto-generated Brick routes
    def path_prefix
      @mutex.synchronize { @path_prefix }
    end

    def path_prefix=(path)
      @mutex.synchronize { @path_prefix = path }
    end

    # Indicates whether Brick models are on or off. Default: true.
    def enable_models
      brick_mode = mode
      @mutex.synchronize { brick_mode == :on && (@enable_models.nil? || @enable_models) }
    end

    def enable_models=(enable)
      @mutex.synchronize { @enable_models = enable }
    end

    # Indicates whether Brick controllers are on or off. Default: true.
    def enable_controllers
      brick_mode = mode
      @mutex.synchronize { brick_mode == :on && (@enable_controllers.nil? || @enable_controllers) }
    end

    def enable_controllers=(enable)
      @mutex.synchronize { @enable_controllers = enable }
    end

    # Indicates whether Brick views are on or off. Default: true.
    def enable_views
      brick_mode = mode
      @mutex.synchronize { brick_mode == :on && (@enable_views.nil? || @enable_views) }
    end

    def enable_views=(enable)
      @mutex.synchronize { @enable_views = enable }
    end

    # Indicates whether Brick routes are on or off. Default: true.
    def enable_routes
      brick_mode = mode
      @mutex.synchronize { brick_mode == :on && (@enable_routes.nil? || @enable_routes) }
    end

    def enable_routes=(enable)
      @mutex.synchronize { @enable_routes = enable }
    end

    def enable_api
      @mutex.synchronize { @enable_api }
    end

    def enable_api=(enable)
      @mutex.synchronize { @enable_api = enable }
    end

    def api_roots
      @mutex.synchronize { @api_roots || ["/api/v1/"] }
    end

    def api_roots=(path)
      @mutex.synchronize { @api_roots = path }
    end

    def api_filter
      @mutex.synchronize { @api_filter }
    end

    def api_filter=(proc)
      @mutex.synchronize { @api_filter = proc }
    end

    # # Proc gets called with up to 4 arguments:  object_name, api_version, columns, data
    # # Expected to return an array, either just of symbols defining column names, or an array with two sub-arrays, first of column detail and second of data
    # def api_column_filter
    #   @mutex.synchronize { @api_column_filter }
    # end

    # def api_column_filter=(proc)
    #   @mutex.synchronize { @api_column_filter = proc }
    # end

    # Allows you to rename and exclude columns either specific to a given API version, or generally for a database object name
    def api_column_renaming
      @mutex.synchronize { @api_column_renaming }
    end

    def api_column_renaming=(renames)
      @mutex.synchronize { @api_column_renaming = renames }
    end

    # All the view prefix things
    def api_view_prefix
      @mutex.synchronize { @api_view_prefix }
    end

    def api_view_prefix=(view_prefix)
      @mutex.synchronize { @api_view_prefix = view_prefix }
    end

    def api_remove_view_prefix
      @mutex.synchronize { @api_remove_view_prefix || @api_view_prefix }
    end

    def api_remove_view_prefix=(view_prefix)
      @mutex.synchronize { @api_remove_view_prefix = view_prefix }
    end

    def api_add_view_prefix
      @mutex.synchronize { @api_add_view_prefix || @api_view_prefix }
    end

    def api_add_view_prefix=(view_prefix)
      @mutex.synchronize { @api_add_view_prefix = view_prefix }
    end

    # Additional table associations to use (Think of these as virtual foreign keys perhaps)
    def additional_references
      @mutex.synchronize { @additional_references }
    end

    def additional_references=(references)
      @mutex.synchronize { @additional_references = references }
    end

    # Custom columns to add to a table, minimally defined with a name and DSL string
    def custom_columns
      @mutex.synchronize { @custom_columns }
    end

    def custom_columns=(cust_cols)
      @mutex.synchronize { @custom_columns = cust_cols }
    end

    # Skip creating a has_many association for these
    def exclude_hms
      @mutex.synchronize { @exclude_hms }
    end

    def exclude_hms=(skips)
      @mutex.synchronize { @exclude_hms = skips }
    end

    # Skip showing counts for these specific has_many associations when building auto-generated #index views
    def skip_index_hms
      @mutex.synchronize { @skip_index_hms || {} }
    end

    def skip_index_hms=(skips)
      @mutex.synchronize do
        @skip_index_hms ||= skips.each_with_object({}) do |v, s|
                              class_name, assoc_name = v.split('.')
                              (s[class_name] ||= {})[assoc_name.to_sym] = nil
                            end
      end
    end

    # Associations to treat as a has_one
    def has_ones
      @mutex.synchronize { @has_ones }
    end

    def has_ones=(hos)
      @mutex.synchronize { @has_ones = hos }
    end

    # Associations upon which to add #accepts_nested_attributes_for logic
    def nested_attributes
      @mutex.synchronize { @nested_attributes }
    end

    def nested_attributes=(anaf)
      @mutex.synchronize { @nested_attributes = anaf }
    end

    # Polymorphic associations
    def polymorphics
      @mutex.synchronize { @polymorphics }
    end

    def polymorphics=(polys)
      @mutex.synchronize { @polymorphics = polys }
    end

    def json_columns
      @mutex.synchronize { @json_columns ||= {} }
    end

    def json_columns=(cols)
      @mutex.synchronize { @json_columns = cols }
    end

    def model_descrips
      @mutex.synchronize { @model_descrips ||= {} }
    end

    def model_descrips=(descrips)
      @mutex.synchronize { @model_descrips = descrips }
    end

    def sti_namespace_prefixes
      @mutex.synchronize { @sti_namespace_prefixes ||= {} }
    end

    def sti_namespace_prefixes=(prefixes)
      @mutex.synchronize { @sti_namespace_prefixes = prefixes }
    end

    def schema_behavior
      @mutex.synchronize { @schema_behavior ||= {} }
    end

    def schema_behavior=(schema)
      @mutex.synchronize { @schema_behavior = schema }
    end

    def sti_type_column
      @mutex.synchronize { @sti_type_column ||= {} }
    end

    def sti_type_column=(type_col)
      @mutex.synchronize do
        (@sti_type_column = type_col).each_with_object({}) do |v, s|
          if v.last.nil?
            # Set an STI type column generally
            ActiveRecord::Base.inheritance_column = v.first
          else
            # Custom STI type columns for models built from specific tables
            (v.last.is_a?(Array) ? v.last : [v.last]).each do |table|
              if (relation = ::Brick.relations.fetch(table, nil))
                relation[:sti_col] = v.first
              end
            end
          end
        end
      end
    end

    def default_route_fallback
      @mutex.synchronize { @default_route_fallback }
    end

    def default_route_fallback=(resource_name)
      @mutex.synchronize { @default_route_fallback = resource_name }
    end

    def skip_database_views
      @mutex.synchronize { @skip_database_views }
    end

    def skip_database_views=(disable)
      @mutex.synchronize { @skip_database_views = disable }
    end

    def exclude_tables
      @mutex.synchronize { @exclude_tables || [] }
    end

    def exclude_tables=(value)
      @mutex.synchronize { @exclude_tables = value }
    end

    def models_inherit_from
      @mutex.synchronize { @models_inherit_from }
    end

    def models_inherit_from=(value)
      @mutex.synchronize { @models_inherit_from = value }
    end

    def controllers_inherit_from
      @mutex.synchronize { @controllers_inherit_from }
    end

    def controllers_inherit_from=(value)
      @mutex.synchronize { @controllers_inherit_from = value }
    end

    def table_name_prefixes
      @mutex.synchronize { @table_name_prefixes }
    end

    def table_name_prefixes=(value)
      @mutex.synchronize { @table_name_prefixes = value }
    end

    def order
      @mutex.synchronize { @order || {} }
    end

    # Get something like:
    # Override how code sorts with:
    #   { 'on_call_list' => { code: "ORDER BY STRING_TO_ARRAY(code, '.')::int[]" } }
    # Specify default thing to order_by with:
    #   { 'on_call_list' => { _brick_default: [:last_name, :first_name] } }
    #   { 'on_call_list' => { _brick_default: :sequence } }
    def order=(orders)
      @mutex.synchronize do
        case (brick_default = orders.fetch(:_brick_default, nil))
        when NilClass
          orders[:_brick_default] = orders.keys.reject { |k| k == :_brick_default }.first
        when String
          orders[:_brick_default] = [brick_default.to_sym]
        when Symbol
          orders[:_brick_default] = [brick_default]
        end
        @order = orders
      end
    end

    def metadata_columns
      @mutex.synchronize { @metadata_columns }
    end

    def metadata_columns=(columns)
      @mutex.synchronize { @metadata_columns = columns }
    end

    def not_nullables
      @mutex.synchronize { @not_nullables }
    end

    def not_nullables=(columns)
      @mutex.synchronize { @not_nullables = columns }
    end

    def always_load_fields
      @mutex.synchronize { @always_load_fields || {} }
    end

    def always_load_fields=(field_set)
      @mutex.synchronize { @always_load_fields = field_set }
    end

    # Add status page showing all resources and what files have been built out for them
    def add_status
      true
    end

    # Add a special page to show references to non-existent records ("orphans")
    def add_orphans
      true
    end

    def license
      @mutex.synchronize { @license }
    end

    def license=(key)
      @mutex.synchronize { @license = key }
    end
  end
end
