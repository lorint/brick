# frozen_string_literal: true

require 'active_record/version'
# ActiveRecord before 4.0 didn't have #version
unless ActiveRecord.respond_to?(:version)
  module ActiveRecord
    def self.version
      ::Gem::Version.new(ActiveRecord::VERSION::STRING)
    end
  end
end

# ActiveSupport, ActionPack, and ActionView before 4.0 didn't have #version
require 'active_support' # Needed for Rails 4.x
unless ActiveSupport.respond_to?(:version)
  module ActiveSupport
    def self.version
      ::Gem::Version.new(ActiveSupport::VERSION::STRING)
    end
  end
end
if Object.const_defined?('ActionPack')
  unless ActionPack.respond_to?(:version)
    module ActionPack
      def self.version
        ::Gem::Version.new(ActionPack::VERSION::STRING)
      end
    end
  end
  if Object.const_defined?('ActionView') && !ActionView.respond_to?(:version)
    module ActionView
      def self.version
        ActionPack.version
      end
    end
  end
end

# In ActiveSupport older than 5.0, the duplicable? test tries to new up a BigDecimal,
# and Ruby 2.6 and later deprecates #new.  This removes the warning from BigDecimal.
# This compatibility needs to be put into place in the application's "config/boot.rb"
# file by having the line "require 'brick/compatibility'" to be the last line in that
# file.
require 'bigdecimal'
if ActiveRecord.version < ::Gem::Version.new('5.0')
  if ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('2.6')
    def BigDecimal.new(*args, **kwargs)
      BigDecimal(*args, **kwargs)
    end

    if ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('3.1')
      # @@schemes fix for global_id gem < 1.0
      URI.class_variable_set(:@@schemes, {}) unless URI.class_variables.include?(:@@schemes)
      if Gem::Specification.all_names.find { |g| g.start_with?('puma-') }
        require 'rack/handler/puma'
        module Rack::Handler::Puma
          class << self
            alias _brick_run run
            def run(app, *args, **options)
              options.merge!(args.pop) if args.last.is_a?(Hash)
              _brick_run(app, **options)
            end
          end
        end
      end

      require 'json'
      if JSON::Parser.method(:initialize).parameters.length < 2 && JSON.method(:parse).arity == -2
        JSON.class_exec do
          def self.parse(source, opts = {})
            ::JSON::Parser.new(source, **opts).parse
          end
        end
      end
    end
  end
end
