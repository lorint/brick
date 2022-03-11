# frozen_string_literal: true

class Boolit < ActiveRecord::Base
  default_scope { where(scoped: true) }
end
