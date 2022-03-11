# frozen_string_literal: true

class Section < ActiveRecord::Base
  belongs_to :chapter
  has_many :paragraphs, dependent: :destroy
end
