# frozen_string_literal: true

class Pet < ActiveRecord::Base
  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :owner, class_name: 'Person', optional: true
  else
    belongs_to :owner, class_name: 'Person'
  end
  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :animal, optional: true
  else
    belongs_to :animal
  end
end
