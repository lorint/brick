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

# Allow ActiveRecord < 3.2 to work with Ruby 2.7 and later
if ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('2.7')
  if ActiveRecord.version < ::Gem::Version.new('3.2')
    # Remove circular reference for "now"
    ::Brick::Util._patch_require(
      'active_support/values/time_zone.rb', '/activesupport',
      ['  def parse(str, now=now)',
      '  def parse(str, now=now())']
    )
    # Remove circular reference for "reflection" for ActiveRecord 3.1
    if ActiveRecord.version >= ::Gem::Version.new('3.1')
      ::Brick::Util._patch_require(
        'active_record/associations/has_many_association.rb', '/activerecord',
        ['reflection = reflection)',
        'reflection = reflection())'],
        :HasManyAssociation # Make sure the path for this guy is available to be autoloaded
      )
    end
  end

  unless ActiveRecord.const_defined?(:NoDatabaseError) # Generic version of NoDatabaseError for Rails <= 4.0
    require 'active_model'
    require 'active_record/errors'
    class ::ActiveRecord::NoDatabaseError < ::ActiveRecord::StatementInvalid
    end
  end

  # Create unfrozen route path in Rails 3.x
  if ActiveRecord.version < ::Gem::Version.new('4')
    # ::Brick::Util._patch_require(
    #   'action_dispatch/routing/route_set.rb', '/actiondispatch',
    #   ["path = (script_name.blank? ? _generate_prefix(options) : script_name.chomp('/')).to_s",
    #    "path = (script_name.blank? ? _generate_prefix(options) : script_name.chomp('/')).to_s.dup"]
    #    #,
    #   #:RouteSet # Make sure the path for this guy is available to be autoloaded
    # )
    require 'action_dispatch/routing/route_set'
    # This is by no means elegant -- wish the above would work instead.  Here we completely replace #url_for
    # only in order to add a ".dup"
    ::ActionDispatch::Routing::RouteSet.class_exec do
      def url_for(options)
        finalize!
        options = (options || {}).reverse_merge!(default_url_options)

        handle_positional_args(options)

        user, password = extract_authentication(options)
        path_segments  = options.delete(:_path_segments)
        script_name    = options.delete(:script_name)

        # Just adding .dup on the end in order to not have a frozen string
        path = (script_name.blank? ? _generate_prefix(options) : script_name.chomp('/')).to_s.dup

        path_options = options.except(*::ActionDispatch::Routing::RouteSet::RESERVED_OPTIONS)
        path_options = yield(path_options) if block_given?

        path_addition, params = generate(path_options, path_segments || {})

        path << path_addition

        ActionDispatch::Http::URL.url_for(options.merge({
          :path => path,
          :params => params,
          :user => user,
          :password => password
        }))
      end
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
if Object.const_defined?('ActionPack') && !ActionPack.respond_to?(:version)
  module ActionPack
    def self.version
      ::Gem::Version.new(ActionPack::VERSION::STRING)
    end
  end
end
require 'action_view' # Needed for Rails <= 4.0
if Object.const_defined?('ActionView') && !ActionView.respond_to?(:version)
  module ActionView
    def self.version
      ActionPack.version
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
