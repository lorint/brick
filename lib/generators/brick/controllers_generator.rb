# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'rails/generators/active_record'
require 'fancy_gets'

module Brick
  # Auto-generates controllers
  class ControllersGenerator < ::Rails::Generators::Base
    include FancyGets
    # include ::Rails::Generators::Migration

    desc 'Auto-generates controllers'

    def brick_controllers
      # %%% If Apartment is active and there's no schema_to_analyse, ask which schema they want

      ::Brick.mode = :on
      ActiveRecord::Base.establish_connection

      # Load all models and controllers
      ::Brick.eager_load_classes

      # Generate a list of viable controllers that can be chosen
      longest_length = 0
      model_info = Hash.new { |h, k| h[k] = {} }
      tableless = Hash.new { |h, k| h[k] = [] }
      existing_controllers = ActionController::Base.descendants.reject do |c|
        c.name.start_with?('Turbo::Native::')
      end.map(&:name)
      controllers = ::Brick.relations.each_with_object([]) do |rel, s|
        next if rel.first.is_a?(Symbol)

        tbl_parts = rel.first.split('.')
        tbl_parts.shift if [::Brick.default_schema, 'public'].include?(tbl_parts.first)
        tbl_parts[-1] = tbl_parts[-1].pluralize
        begin
          s << ControllerOption.new(tbl_parts.join('/').camelize, rel.last[:class_name].constantize)
        rescue
        end
      end.reject { |c| existing_controllers.include?(c.to_s) }
      controllers.sort! do |a, b| # Sort first to separate namespaced stuff from the rest, then alphabetically
        is_a_namespaced = a.to_s.include?('::')
        is_b_namespaced = b.to_s.include?('::')
        if is_a_namespaced && !is_b_namespaced
          1
        elsif !is_a_namespaced && is_b_namespaced
          -1
        else
          a.to_s <=> b.to_s
        end
      end
      controllers.each do |m| # Find longest name in the list for future use to show lists on the right side of the screen
        if longest_length < (len = m.to_s.length)
          longest_length = len
        end
      end
      chosen = gets_list(list: controllers, chosen: controllers.dup)
      relations = ::Brick.relations
      chosen.each do |controller_option|
        if (controller_parts = controller_option.to_s.split('::')).length > 1
          namespace = controller_parts.first.constantize
        end
        _built_controller, code = Object.send(:build_controller, namespace, controller_parts.last, controller_parts.last.pluralize, controller_option.model, relations)
        path = ['controllers']
        path.concat(controller_parts.map(&:underscore))
        dir = +"#{::Rails.root}/app"
        path[0..-2].each do |path_part|
          dir << "/#{path_part}"
          Dir.mkdir(dir) unless Dir.exist?(dir)
        end
        File.open("#{dir}/#{path.last}.rb", 'w') { |f| f.write code } unless code.blank?
      end
      puts "\n*** Created #{chosen.length} controller files under app/controllers ***"
    end
  end
end

class ControllerOption
  attr_accessor :name, :model

  def initialize(name, model)
    self.name = name
    self.model = model
  end

  def to_s
    name
  end
end
