# frozen_string_literal: true

require 'brick'
require 'rails/generators'
require 'fancy_gets'

module Brick
  class SeedsGenerator < ::Rails::Generators::Base
    include FancyGets

    desc 'Auto-generates a seeds file from existing data.'

    SeedModel = Struct.new(:table_name, :klass, :is_brick)
    SeedModel.define_method(:to_s) do
      "#{klass.name}#{' (brick-generated)' if is_brick}"
    end

    def brick_seeds
      # %%% If Apartment is active and there's no schema_to_analyse, ask which schema they want

      ::Brick.mode = :on
      ActiveRecord::Base.establish_connection

      # Load all models
      ::Brick.eager_load_classes

      # Generate a list of viable models that can be chosen
      # First start with any existing models that have been defined ...
      existing_models = ActiveRecord::Base.descendants.each_with_object({}) do |m, s|
        s[m.table_name] = SeedModel.new(m.table_name, m, false) if !m.abstract_class? && !m.is_view? && m.table_exists?
      end
      models = (existing_models.values +
                # ... then add models which can be auto-built by Brick
                ::Brick.relations.reject do |k, v|
                  k.is_a?(Symbol) || (v.key?(:isView) && v[:isView] == true) || existing_models.key?(k)
                end.map { |k, v| SeedModel.new(k, v[:class_name].constantize, true) }
               ).sort { |a, b| a.to_s <=> b.to_s }
      if models.empty?
        puts "No viable models found for database #{ActiveRecord::Base.connection.current_database}."
        return
      end

      if File.exist?(seed_file_path = "#{::Rails.root}/db/seeds.rb")
        puts "WARNING: seeds file #{seed_file_path} appears to already be present.\nOverwrite?"
        return unless gets_list(list: ['No', 'Yes']) == 'Yes'

        puts "\n"
      end

      chosen = gets_list(list: models, chosen: models.dup)
      schemas = chosen.each_with_object({}) do |v, s|
        if (v_parts = v.table_name.split('.')).length > 1
          s[v_parts.first] = nil unless [::Brick.default_schema, 'public'].include?(v_parts.first)
        end
      end
      seeds = +'# Seeds file for '
      if (arbc = ActiveRecord::Base.connection).respond_to?(:current_database) # SQLite3 can't do this!
        seeds << "#{arbc.current_database}:\n"
      elsif (filename = arbc.instance_variable_get(:@connection_parameters)&.fetch(:database, nil))
        seeds << "#{filename}:\n"
      end
      done = []
      fks = {}
      stuck = {}
      indexes = {} # Track index names to make sure things are unique
      ar_base = Object.const_defined?(:ApplicationRecord) ? ApplicationRecord : Class.new(ActiveRecord::Base)
      # Start by making entries for fringe models (those with no foreign keys).
      # Continue layer by layer, creating entries for models that reference ones already done, until
      # no more entries can be created.  (At that point hopefully all models are accounted for.)
      while (fringe = chosen.reject do |seed_model|
                        tbl = seed_model.table_name
                        snag_fks = []
                        snags = ::Brick.relations.fetch(tbl, nil)&.fetch(:fks, nil)&.select do |_k, v|
                          # Skip any foreign keys which should be deferred ...
                          !Brick.drfgs[tbl]&.any? do |drfg|
                            drfg[0] == v.fetch(:fk, nil) && drfg[1] == v.fetch(:inverse_table, nil)
                          end &&
                          v[:is_bt] && !v[:polymorphic] && # ... and polymorphics ...
                          tbl != v[:inverse_table] && # ... and self-referencing associations (stuff like "parent_id")
                          !done.any? { |done_seed_model| done_seed_model.table_name == v[:inverse_table] } &&
                          ::Brick.config.ignore_migration_fks.exclude?(snag_fk = "#{tbl}.#{v[:fk]}") &&
                          snag_fks << snag_fk
                        end
                        if snags&.present?
                          # puts snag_fks.inspect
                          stuck[tbl] = snags
                        end
                      end
            ).present?
        seeds << "\n"
        fringe.each do |seed_model|
          tbl = seed_model.table_name
          next unless ::Brick.config.exclude_tables.exclude?(tbl) &&
                      (relation = ::Brick.relations.fetch(tbl, nil))&.fetch(:cols, nil)&.present? &&
                      (klass = seed_model.klass).table_exists?

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

          has_rows = false
          is_empty = true
          klass.order(*pkey_cols).each do |obj|
            unless has_rows
              has_rows = true
              seeds << "  puts 'Seeding: #{seed_model.klass.name}'\n"
            end
            is_empty = false
            pk_val = obj.send(pkey_cols.first)
            fk_vals = []
            data = []
            relation[:cols].each do |col, _col_type|
              next if !(fk = fkeys.find { |assoc| col == assoc[:fk] }) &&
                      pkey_cols.include?(col)

              begin
                if (val = obj.send(col)) && (val.is_a?(Time) || val.is_a?(Date))
                  val = val.to_s
                end
              rescue StandardError => e # ActiveRecord::Encryption::Errors::Configuration
              end
              if fk
                inv_tbl = fk[:inverse_table].gsub('.', '__')
                fk_vals << "#{fk[:assoc_name]}: #{inv_tbl}_#{brick_escape(val)}" if val
              else
                data << "#{col}: #{val.inspect}"
              end
            end
            seeds << "#{tbl.gsub('.', '__')}_#{brick_escape(pk_val)} = #{seed_model.klass.name}.create(#{(fk_vals + data).join(', ')})\n"
          end
          seeds << "  # (Skipping #{seed_model.klass.name} as it has no rows)\n" unless has_rows
          File.open(seed_file_path, "w") { |f| f.write seeds }
        end
        done.concat(fringe)
        chosen -= done
      end
      stuck_counts = Hash.new { |h, k| h[k] = 0 }
      chosen.each do |leftover|
        puts "Can't do #{leftover.klass.name} because:\n  #{stuck[leftover.table_name].map do |snag|
          stuck_counts[snag.last[:inverse_table]] += 1
          snag.last[:assoc_name]
        end.join(', ')}"
      end
      puts "\n*** Created seeds for #{done.length} models in db/seeds.rb ***"
      if (stuck_sorted = stuck_counts.to_a.sort { |a, b| b.last <=> a.last }).length.positive?
        puts "-----------------------------------------"
        puts "Unable to create seeds for #{stuck_sorted.length} tables#{
          ".  Here's the top 5 blockers" if stuck_sorted.length > 5
        }:"
        pp stuck_sorted[0..4]
      end
    end

  private

    def brick_escape(val)
      val = val.to_s if val.is_a?(Date) || val.is_a?(Time) # Accommodate when for whatever reason a primary key is a date or time
      case val
      when String
        ret = +''
        val.each_char do |ch|
          if ch < '0' || (ch > '9' && ch < 'A') || ch > 'Z'
            ret << (ch == '_' ? ch : "x#{'K'.unpack('H*')[0]}")
          else
            ret << ch
          end
        end
        ret
      else
        val
      end
    end
  end
end
