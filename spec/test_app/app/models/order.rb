# frozen_string_literal: true

class Order < ActiveRecord::Base
  belongs_to :customer
  has_many :line_items
end
