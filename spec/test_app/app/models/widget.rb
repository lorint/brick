# frozen_string_literal: true

class Widget < ActiveRecord::Base
  EXCLUDED_NAME = 'Biglet'
  has_one :wotsit, dependent: :destroy
  if ActiveRecord.version >= ::Gem::Version.new('4.0')
    has_many :fluxors, -> { order(:name) }, dependent: :destroy
  else
    has_many :fluxors, dependent: :destroy
  end

  # HABTM
  has_and_belongs_to_many :foo_habtms

  # HMT
  has_many :foo_hmt_widgets
  has_many :foo_hmts, through: :foo_hmt_widgets

  has_many :whatchamajiggers, as: :owner
  validates :name, exclusion: { in: [EXCLUDED_NAME] }
end
