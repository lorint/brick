# frozen_string_literal: true

module Quiz
  class Response < ActiveRecord::Base
    belongs_to :quiz

    has_many :answers, dependent: :destroy
    accepts_nested_attributes_for :answers, allow_destroy: true
  end
end
