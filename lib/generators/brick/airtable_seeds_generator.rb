# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'rails/generators/active_record'
require 'generators/brick/seeds_builder'
require 'generators/brick/airtable_api_caller'

module Brick
  class AirtableSeedsGenerator < ::Rails::Generators::Base
    desc 'Auto-generates a seeds file from existing data in an Airtable "base".'

    def airtable_seeds
      return unless (relations = ::Brick::AirtableApiCaller.pick_tables(:seeds))

      ::Brick::SeedsBuilder.generate_seeds(relations)
    end
  end
end
