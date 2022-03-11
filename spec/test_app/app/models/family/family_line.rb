# frozen_string_literal: true

module Family
  class FamilyLine < ActiveRecord::Base
    if ActiveRecord.version >= Gem::Version.new('5.0')
      belongs_to :parent, class_name: '::Family::Family', foreign_key: :parent_id, optional: true
    else
      belongs_to :parent, class_name: '::Family::Family', foreign_key: :parent_id
    end
    if ActiveRecord.version >= Gem::Version.new('5.0')
      belongs_to :grandson, class_name: '::Family::Family',
                            foreign_key: :grandson_id,
                            optional: true
    else
      belongs_to :grandson, class_name: '::Family::Family',
                            foreign_key: :grandson_id
    end
  end
end
