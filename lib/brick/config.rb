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

    # Indicates whether Brick models are on or off. Default: true.
    def enable_models
      @mutex.synchronize { !!@enable_models }
    end

    def enable_models=(enable)
      @mutex.synchronize { @enable_models = enable }
    end

    # Indicates whether Brick controllers are on or off. Default: true.
    def enable_controllers
      @mutex.synchronize { !!@enable_controllers }
    end

    def enable_controllers=(enable)
      @mutex.synchronize { @enable_controllers = enable }
    end

    # Indicates whether Brick views are on or off. Default: true.
    def enable_views
      @mutex.synchronize { !!@enable_views }
    end

    def enable_views=(enable)
      @mutex.synchronize { @enable_views = enable }
    end

    # Indicates whether Brick routes are on or off. Default: true.
    def enable_routes
      @mutex.synchronize { !!@enable_routes }
    end

    def enable_routes=(enable)
      @mutex.synchronize { @enable_routes = enable }
    end

    # Additional table associations to use (Think of these as virtual foreign keys perhaps)
    def additional_references
      @mutex.synchronize { @additional_references }
    end

    def additional_references=(references)
      @mutex.synchronize { @additional_references = references }
    end

    # Skip creating a has_many association for these
    def skip_hms
      @mutex.synchronize { @skip_hms }
    end

    def skip_hms=(skips)
      @mutex.synchronize { @skip_hms = skips }
    end

    # Associations to treat as a has_one
    def has_ones
      @mutex.synchronize { @has_ones }
    end

    def has_ones=(hos)
      @mutex.synchronize { @has_ones = hos }
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

    def skip_database_views
      @mutex.synchronize { @skip_database_views }
    end

    def skip_database_views=(disable)
      @mutex.synchronize { @skip_database_views = disable }
    end

    def exclude_tables
      @mutex.synchronize { @exclude_tables }
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

    def table_name_prefixes
      @mutex.synchronize { @table_name_prefixes }
    end

    def table_name_prefixes=(value)
      @mutex.synchronize { @table_name_prefixes = value }
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
  end
end
