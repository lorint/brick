# frozen_string_literal: true

class Thing < ActiveRecord::Base
  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :person, optional: true
  else
    belongs_to :person
  end
end
