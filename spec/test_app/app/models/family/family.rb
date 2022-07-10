# frozen_string_literal: true

class Family < ActiveRecord::Base
  has_many :family_lines, class_name: 'FamilyLine', foreign_key: :parent_id
  has_many :children, class_name: 'Family', foreign_key: :parent_id
  has_many :grandsons, through: :family_lines
  has_one :mentee, class_name: 'Family', foreign_key: :partner_id

  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :parent, class_name: 'Family', foreign_key: :parent_id, optional: true
  else
    belongs_to :parent, class_name: 'Family', foreign_key: :parent_id
  end
  if ActiveRecord.version >= Gem::Version.new('5.0')
    belongs_to :mentor, class_name: 'Family', foreign_key: :partner_id, optional: true
  else
    belongs_to :mentor, class_name: 'Family', foreign_key: :partner_id
  end

  accepts_nested_attributes_for :mentee
  accepts_nested_attributes_for :children
end
