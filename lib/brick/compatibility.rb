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
if ::Gem::Version.new(RUBY_VERSION) >= ::Gem::Version.new('2.6') &&
   ActiveRecord.version < ::Gem::Version.new('5.0')
  def BigDecimal.new(*args, **kwargs)
    BigDecimal(*args, **kwargs)
  end
end
