# frozen_string_literal: true

class Citation < ActiveRecord::Base
  belongs_to :quotation
end
