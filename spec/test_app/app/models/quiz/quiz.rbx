# frozen_string_literal: true

module Quiz
  class Quiz < ActiveRecord::Base
    CONTAINER_TYPES = { assessment: 0, section: 1 }.freeze
    AMOEBA_LAMBDA = lambda {
      enable
      include_association :questions
      include_association :children
      nullify :inactivation_date
      set active: true
    }

    has_many :questions, dependent: :destroy
    has_many :responses
    has_many :parent_responses, class_name: 'Response', foreign_key: :quiz_id, primary_key: :parent_id
    has_many :children, class_name: 'Quiz', foreign_key: :parent_id, inverse_of: :parent, dependent: :destroy
    belongs_to :parent, class_name: 'Quiz', inverse_of: :children, optional: true
    belongs_to :category

    accepts_nested_attributes_for :questions, allow_destroy: true

    validates :name, presence: true
    validates :name, uniqueness: { scope: :parent_id, if: proc { self.section_container? } }
    validates :name, length: { maximum: 50 }
    validates :description, length: { maximum: 1500 }
  end
end
