# frozen_string_literal: true

class Quotation < ActiveRecord::Base
  belongs_to :chapter
  has_many :citations, dependent: :destroy
end
