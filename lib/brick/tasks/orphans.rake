# frozen_string_literal: true

if Object.const_defined?('::Rake::TaskManager')
  namespace :brick do
    desc 'Find any seemingly-orphaned records'
    task orphans: :environment do
      def class_pk(dotted_name, multitenant)
        Object.const_get((multitenant ? [dotted_name.split('.').last] : dotted_name.split('.')).map { |nm| "::#{nm.singularize.camelize}" }.join).primary_key
      end

      schema_list = ((multi = ::Brick.config.schema_behavior[:multitenant]) && ::Brick.db_schemas.keys.sort) || []
      if schema_list.length > 1
        require 'fancy_gets'
        include FancyGets
        schema = gets_list(
          list: schema_list,
          chosen: multi[:schema_to_analyse]
        )
      elsif schema_list.length.positive?
        schema = schema_list.first
      end
      ActiveRecord::Base.execute_sql("SET SEARCH_PATH = ?", schema) if schema
      orphans = +''
      ::Brick.relations.each do |k, v|
        next if v.key?(:isView) || ::Brick.config.exclude_tables.include?(k) ||
                !(pri_pk = v[:pkey].values.first&.first) ||
                !(pri_pk = class_pk(k, multi))
        v[:fks].each do |k1, v1|
          next if v1[:is_bt] ||
                  !(for_rel = ::Brick.relations.fetch(v1[:inverse_table], nil)) ||
                  v1[:inverse]&.key?(:polymorphic) ||
                  !(for_pk = for_rel.fetch(:pkey, nil)&.values&.first&.first) ||
                  !(for_pk = class_pk(v1[:inverse_table], multi))
          begin
            ActiveRecord::Base.execute_sql(
              "SELECT DISTINCT frn.#{v1[:fk]} AS pri_id, frn.#{for_pk} AS fk_id
              FROM #{v1[:inverse_table]} AS frn
                LEFT OUTER JOIN #{k} AS pri ON pri.#{pri_pk} = frn.#{v1[:fk]}
              WHERE frn.#{v1[:fk]} IS NOT NULL AND pri.#{pri_pk} IS NULL
              ORDER BY 1, 2"
            ).each do |o|
              orphans << "#{v1[:inverse_table]} #{o['fk_id']} refers to non-existant #{k} #{o['pri_id']}\n"
            end
          rescue StandardError => err
            puts "Strange -- #{err.inspect}"
          end
        end
      end
      puts "For #{schema}:\n#{'=' * (schema.length + 5)}" if schema
      if orphans.blank?
        puts "No orphans!"
      else
        print orphans
      end
    end
  end
end
