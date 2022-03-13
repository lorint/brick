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
    def additional_references=(references)
      @mutex.synchronize { @additional_references = references }
    end

    def additional_references
      @mutex.synchronize { @additional_references }
    end
  end
end
