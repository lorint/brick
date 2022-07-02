# frozen_string_literal: true

if Object.const_defined?('::Rake::TaskManager')
  namespace :brick do
    desc 'Find any seemingly-orphaned records'
    task orphans: :environment do
      schema_list = ((multi = ::Brick.config.schema_behavior[:multitenant]) && ::Brick.db_schemas.keys.sort) || []
      schema = if schema_list.length == 1
                 schema_list.first
               elsif schema_list.length.positive?
                 require 'fancy_gets'
                 include FancyGets
                 gets_list(list: schema_list, chosen: multi[:schema_to_analyse])
               end
      ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema) if schema
      orphans = ::Brick.find_orphans(schema)
      puts "Orphans in #{schema}:\n#{'=' * (schema.length + 12)}" if schema
      if orphans.empty?
        puts "No orphans!"
      else
        orphans.each do |o|
          via = " (via #{o[4]})" unless "#{o[2].split('.').last.underscore.singularize}_id" == o[4]
          puts "#{o[0]} #{o[1]} refers#{via} to non-existent #{o[2]} #{o[3]}#{" (in table \"#{o[5]}\")" if o[5]}"
        end
        puts
      end
    end
  end
end
