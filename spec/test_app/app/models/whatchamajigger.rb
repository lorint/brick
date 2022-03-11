# frozen_string_literal: true

class Whatchamajigger < ActiveRecord::Base
  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :owner, polymorphic: true, optional: true
  else
    belongs_to :owner, polymorphic: true
  end
end
