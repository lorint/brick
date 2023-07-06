# frozen_string_literal: true

require 'rails/generators'
require 'fancy_gets'

module Brick
  class SeedsGenerator < ::Rails::Generators::Base
    include FancyGets

    desc 'Auto-generates a seeds file from existing data.'

    def brick_seeds
      # %%% If Apartment is active and there's no schema_to_analyse, ask which schema they want

      ::Brick.mode = :on
      ActiveRecord::Base.establish_connection

      if (tables = ::Brick.relations.reject { |k, v| v.key?(:isView) && v[:isView] == true }.map(&:first).sort).empty?
        puts "No tables found in database #{ActiveRecord::Base.connection.current_database}."
        return
      end

      if File.exist?(seed_file_path = "#{::Rails.root}/db/seeds.rb")
        puts "WARNING: seeds file #{seed_file_path} appears to already be present."
      end

      # Generate a list of tables that can be chosen
      chosen = gets_list(list: tables, chosen: tables.dup)
      schemas = chosen.each_with_object({}) do |v, s|
        if (v_parts = v.split('.')).length > 1
          s[v_parts.first] = nil unless [::Brick.default_schema, 'public'].include?(v_parts.first)
        end
      end
      seeds = +"# Seeds file for #{ActiveRecord::Base.connection.current_database}:"
      done = []
      fks = {}
      stuck = {}
      indexes = {} # Track index names to make sure things are unique
      ar_base = Object.const_defined?(:ApplicationRecord) ? ApplicationRecord : Class.new(ActiveRecord::Base)
      # Start by making entries for fringe models (those with no foreign keys).
      # Continue layer by layer, creating entries for models that reference ones already done, until
      # no more entries can be created.  (At that point hopefully all models are accounted for.)
      while (fringe = chosen.reject do |tbl|
                        snag_fks = []
                        snags = ::Brick.relations.fetch(tbl, nil)&.fetch(:fks, nil)&.select do |_k, v|
                          v[:is_bt] && !v[:polymorphic] &&
                          tbl != v[:inverse_table] && # Ignore self-referencing associations (stuff like "parent_id")
                          !done.include?(v[:inverse_table]) &&
                          ::Brick.config.ignore_migration_fks.exclude?(snag_fk = "#{tbl}.#{v[:fk]}") &&
                          snag_fks << snag_fk
                        end
                        if snags&.present?
                          # puts snag_fks.inspect
                          stuck[tbl] = snags
                        end
                      end).present?
        seeds << "\n"
        fringe.each do |tbl|
          next unless ::Brick.config.exclude_tables.exclude?(tbl) &&
                      (relation = ::Brick.relations.fetch(tbl, nil))&.fetch(:cols, nil)&.present? &&
                      (klass = Object.const_get(class_name = relation[:class_name])).table_exists?

          pkey_cols = (rpk = relation[:pkey].values.flatten) & (arpk = [ar_base.primary_key].flatten.sort)
          # In case things aren't as standard
          if pkey_cols.empty?
            pkey_cols = if rpk.empty? # && relation[:cols][arpk.first]&.first == key_type
                          arpk
                        elsif rpk.first
                          rpk
                        end
          end
          schema = if (tbl_parts = tbl.split('.')).length > 1
                     if tbl_parts.first == (::Brick.default_schema || 'public')
                       tbl_parts.shift
                       nil
                     else
                       tbl_parts.first
                     end
                   end

          # %%% For the moment we're skipping polymorphics
          fkeys = relation[:fks].values.select { |assoc| assoc[:is_bt] && !assoc[:polymorphic] }
          # Refer to this table name as a symbol or dotted string as appropriate
          # tbl_code = tbl_parts.length == 1 ? ":#{tbl_parts.first}" : "'#{tbl}'"
          seeds << "  # #{class_name}\n"

          is_empty = true
          klass.order(*pkey_cols).each do |obj|
            is_empty = false
            pk_val = obj.send(pkey_cols.first)
            fk_vals = []
            data = []
            relation[:cols].each do |col, col_type|
              next if !(fk = fkeys.find { |assoc| col == assoc[:fk] }) &&
                      pkey_cols.include?(col)

              if (val = obj.send(col)) && (val.is_a?(Time) || val.is_a?(Date))
                val = val.to_s
              end
              if fk
                fk_vals << "#{fk[:assoc_name]}: #{fk[:inverse_table]}_#{val.inspect}" if val
              else
                data << "#{col}: #{val.inspect}"
              end
            end
            seeds << "#{tbl}_#{pk_val} = #{class_name}.create(#{(fk_vals + data).join(', ')})\n"
          end
          File.open(seed_file_path, "w") { |f| f.write seeds }
        end
        done.concat(fringe)
        chosen -= done
      end
      puts "\n*** Created seeds for #{done.length} models in db/seeds.rb ***"
    end
  end
end
