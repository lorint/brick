# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'generators/brick/seeds_builder'

module Brick
  class SeedsGenerator < ::Rails::Generators::Base
    desc 'Auto-generates a seeds file from existing data.'

    def brick_seeds
      # %%% If Apartment is active and there's no schema_to_analyse, ask which schema they want

      ::Brick::SeedsBuilder.generate_seeds
    end
  end
end
