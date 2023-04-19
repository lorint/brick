module Brick::Rails::FormTags
  # Our super speedy grid
  def brick_grid(relation, bt_descrip, sequence = nil, inclusions, exclusions,
                 cols, poly_cols, bts, hms_keys, hms_cols)
    out = "<table id=\"headerTop\"></table>
<table id=\"#{relation.table_name.split('.').last}\" class=\"shadow\">
  <thead><tr>"
    pk = (klass = relation.klass).primary_key || []
    pk = [pk] unless pk.is_a?(Array)
    if pk.present?
      out << "<th x-order=\"#{pk.join(',')}\"></th>"
    end

    col_keys = relation.columns.each_with_object([]) do |col, s|
      col_name = col.name
      next if inclusions&.exclude?(col_name) ||
              (pk.include?(col_name) && [:integer, :uuid].include?(col.type) && !bts.key?(col_name)) ||
              ::Brick.config.metadata_columns.include?(col_name) || poly_cols.include?(col_name)

      s << col_name
      cols[col_name] = col
    end
    composite_bts = bts.select { |k, _v| k.is_a?(Array) }
    composite_bt_names = {}
    composite_bt_cols = composite_bts.each_with_object([]) do |bt, s|
      composite_bt_names[bt.first.join('__')] = bt.last
      bt.first.each { |bt_col| s << bt_col unless s.include?(bt_col.first) }
    end
    unless sequence # If no sequence is defined, start with all inclusions
      cust_cols = klass._br_cust_cols
      # HOT columns, kept as symbols
      hots = klass._br_bt_descrip.keys.select { |k| bts.key?(k) }
      sequence = (col_keys - composite_bt_cols) +
                 composite_bt_names.keys + cust_cols.keys + hots +
                 hms_keys.reject { |assoc_name| inclusions&.exclude?(assoc_name) }
    end
    sequence.reject! { |nm| exclusions.include?(nm) } if exclusions
    out << sequence.each_with_object(+'') do |col_name, s|
             if (col = cols[col_name]).is_a?(ActiveRecord::ConnectionAdapters::Column)
               s << '<th '
               s << "title=\"#{col.comment}\"" if col.respond_to?(:comment) && !col.comment.blank?
               s << if (bt = bts[col_name])
                      # Allow sorting for any BT except polymorphics
                      "x-order=\"#{bt.first.to_s + '"' unless bt[2]}>BT " +
                      bt[1].map { |bt_pair| bt_pair.first.bt_link(bt.first) }.join(' ')
                    else # Normal column
                      "x-order=\"#{col_name + '"' if true}>#{col_name}"
                    end
             elsif col # HM column
               options = {}
               options[col[1].inheritance_column] = col[1].name unless col[1] == col[1].base_class
               s << "<th x-order=\"#{col_name + '"' if true}>#{col[2]} "
               s << (col.first ? "#{col[3]}" : "#{link_to(col[3], send("#{col[1]._brick_index}_path", options))}")
             elsif cust_cols.key?(col_name) # Custom column
               s << "<th x-order=\"#{col_name}\">#{col_name}"
             elsif col_name.is_a?(Symbol) && (hot = bts[col_name]) # has_one :through
               s << "<th x-order=\"#{hot.first.to_s}\">HOT " +
                    hot[1].map { |hot_pair| hot_pair.first.bt_link(col_name) }.join(' ')
             elsif (bt = composite_bt_names[col_name])
               s << "<th x-order=\"#{bt.first.to_s + '"' unless bt[2]}>BT comp " +
                    bt[1].map { |bt_pair| bt_pair.first.bt_link(bt.first) }.join(' ')
             else # Bad column name!
               s << "<th title=\"<< Unknown column >>\">#{col_name}"
             end
             s << '</th>'
           end
    out << "</tr></thead>
  <tbody>"
    # %%% Have once gotten this error with MSSQL referring to http://localhost:3000/warehouse/cold_room_temperatures__archive
    #     ActiveRecord::StatementTimeout in Warehouse::ColdRoomTemperatures_Archive#index
    #     TinyTds::Error: Adaptive Server connection timed out
    #     (After restarting the server it worked fine again.)
    relation.each do |obj|
      out << "<tr>\n"
      out << "<td>#{link_to('⇛', send("#{klass._brick_index(:singular)}_path".to_sym,
                                      pk.map { |pk_part| obj.send(pk_part.to_sym) }), { class: 'big-arrow' })}</td>\n" if pk.present?
      sequence.each do |col_name|
        val = obj.attributes[col_name]
        out << '<td'
        out << ' class=\"dimmed\"' unless cols.key?(col_name) || (cust_col = cust_cols[col_name]) ||
                                          (col_name.is_a?(Symbol) && bts.key?(col_name)) # HOT
        out << '>'
        if (bt = bts[col_name] || composite_bt_names[col_name])
          if bt[2] # Polymorphic?
            if (poly_id = obj.send("#{bt.first}_id"))
              # Was:  obj.send("#{bt.first}_type")
              bt_class = obj.send(obj.class.reflect_on_association(bt.first).foreign_type)
              base_class_underscored = (::Brick.existing_stis[bt_class] || bt_class).constantize.base_class._brick_index(:singular)
              out << link_to("#{bt_class} ##{poly_id}", send("#{base_class_underscored}_path".to_sym, poly_id))
            end
          else # BT or HOT
            bt_class = bt[1].first.first
            descrips = bt_descrip[bt.first][bt_class]
            bt_id_col = if descrips.nil?
                          puts "Caught it in the act for obj / #{col_name}!"
                        elsif descrips.length == 1
                          [obj.class.reflect_on_association(bt.first)&.foreign_key]
                        else
                          descrips.last
                        end
            bt_txt = bt_class.brick_descrip(
              # 0..62 because Postgres column names are limited to 63 characters
              obj, descrips[0..-2].map { |id| obj.send(id.last[0..62]) }, bt_id_col
            )
            bt_txt = ::Brick::Rails.display_binary(bt_txt).html_safe if bt_txt&.encoding&.name == 'ASCII-8BIT'
            bt_txt ||= "<span class=\"orphan\">&lt;&lt; Orphaned ID: #{val} >></span>" if val
            bt_id = bt_id_col&.map { |id_col| obj.respond_to?(id_sym = id_col.to_sym) ? obj.send(id_sym) : id_col }
            out << (bt_id&.first ? link_to(bt_txt, send("#{bt_class.base_class._brick_index(:singular)}_path".to_sym, bt_id)) : bt_txt || '')
          end
        elsif (hms_col = hms_cols[col_name])
          if hms_col.length == 1
            out << hms_col.first
          else
            hm_klass = (col = cols[col_name])[1]
            if col[2] == 'HO'
              descrips = bt_descrip[col_name.to_sym][hm_klass]
              if (ho_id = (ho_id_col = descrips.last).map { |id_col| obj.send(id_col.to_sym) })&.first
                ho_txt = if hm_klass.name == 'ActiveStorage::Attachment'
                           begin
                             ::Brick::Rails.display_binary(obj.send(col[3])&.blob&.download)&.html_safe
                           rescue
                           end
                         else
                           hm_klass.brick_descrip(obj, descrips[0..-2].map { |id| obj.send(id.last[0..62]) }, ho_id_col)
                         end
                out << link_to(ho_txt, send("#{hm_klass.base_class._brick_index(:singular)}_path".to_sym, ho_id))
              end
            else
              if (ct = obj.send(hms_col[1].to_sym)&.to_i)&.positive?
                predicates = hms_col[2].each_with_object({}) { |v, s| s[v.first] = v.last.is_a?(String) ? v.last : obj.send(v.last) }
                predicates.each { |k, v| predicates[k] = obj.class.name if v == '[sti_type]' }
                out << "#{link_to("#{ct || 'View'} #{hms_col.first}",
                                  send("#{hm_klass._brick_index}_path".to_sym, predicates))}\n"
              end
            end
          end
        elsif (col = cols[col_name]).is_a?(ActiveRecord::ConnectionAdapters::Column)
          # binding.pry if col.is_a?(Array)
          out << if @_brick_monetized_attributes&.include?(col_name)
                   val ? Money.new(val.to_i).format : ''
                 else
                   lat_lng = if [:float, :decimal].include?(col.type) &&
                                (
                                  ((col_name == 'latitude' && obj.respond_to?('longitude') && (lng = obj.send('longitude')) && lng.is_a?(Numeric) && (lat = val)) ||
                                   (col_name == 'longitude' && obj.respond_to?('latitude') && (lat = obj.send('latitude')) && lat.is_a?(Numeric) && (lng = val))
                                  ) ||
                                  ((col_name == 'lat' && obj.respond_to?('lng') && (lng = obj.send('lng')) && lng.is_a?(Numeric) && (lat = val)) ||
                                   (col_name == 'lng' && obj.respond_to?('lat') && (lat = obj.send('lat')) && lat.is_a?(Numeric) && (lng = val))
                                  )
                                )
                               [lat, lng]
                             end
                   col_type = col&.sql_type == 'geography' ? col.sql_type : col&.type
                   ::Brick::Rails.display_value(col_type || col&.sql_type, val, lat_lng).to_s
                 end
        elsif cust_col
          data = cust_col.first.map { |cc_part| obj.send(cc_part.last) }
          cust_txt = klass.brick_descrip(cust_col[-2], data)
          if (link_id = obj.send(cust_col.last[1]) if cust_col.last)
            out << link_to(cust_txt, send("#{cust_col.last.first._brick_index(:singular)}_path", link_id))
          else
            out << (cust_txt || '')
          end
        else # Bad column name!
          out << '?'
        end
        out << '</td>'
      end
      out << '</tr>'
    end
    out << "  </tbody>
</table>
"
    out.html_safe
  end # brick_grid

  def link_to_brick(*args, **kwargs)
    return unless ::Brick.config.mode == :on

    kwargs.merge!(args.pop) if args.last.is_a?(Hash)
    # Avoid infinite recursion
    if (visited = kwargs.fetch(:visited, nil))
      return if visited.key?(object_id)

      kwargs[:visited][object_id] = nil
    else
      kwargs[:visited] = {}
    end

    text = ((args.first.is_a?(String) || args.first.is_a?(Proc)) && args.shift) || args[1]
    text = text.call if text.is_a?(Proc)
    klass_or_obj = ((args.first.is_a?(ActiveRecord::Relation) ||
                     args.first.is_a?(ActiveRecord::Base) ||
                     args.first.is_a?(Class)) &&
                    args.first) ||
                   @_brick_model
    # If not provided, do a best-effort to automatically determine the resource class or object
    filter_parts = []
    rel_name = nil
    klass_or_obj ||= begin
                       klass, sti_type, rel_name = ::Brick.ctrl_to_klass(controller_path)
                       if klass
                         type_col = klass.inheritance_column # Usually 'type'
                         filter_parts << "#{type_col}=#{sti_type}" if sti_type && klass.column_names.include?(type_col)
                         path_params = request.path_parameters
                         pk = (klass.primary_key || ActiveRecord::Base.primary_key).to_sym
                         if ((id = (path_params[pk] || path_params[:id] || path_params["#{klass.name.underscore}_id".to_sym])) && (obj = klass.find_by(pk => id))) ||
                            (['show', 'edit', 'update', 'destroy'].include?(action_name) && (obj = klass.first))
                           obj
                         else
                           # %%% If there is a HMT that refers to some ___id then try to identify an appropriate filter
                           # %%% If there is a polymorphic association that might relate to stuff in the path_params,
                           # try to identify an appropriate ___able_id and ___able_type filter
                           ((klass.column_names - [pk.to_s]) & path_params.keys.map(&:to_s)).each do |path_param|
                             next if [:controller, :action].include?(path_param)

                             foreign_id = path_params[path_param.to_sym]
                             # Need to convert a friendly_id slug to a real ID?
                             if Object.const_defined?('FriendlyId') &&
                                (assoc = klass.reflect_on_all_associations.find { |a| a.belongs_to? && a.foreign_key == path_param }) &&
                                (assoc_klass = assoc.klass).instance_variable_get(:@friendly_id_config) &&
                                (new_id = assoc_klass.where(assoc_klass.friendly_id_config.query_field => foreign_id)
                                                     .pluck(assoc_klass.primary_key).first)
                               foreign_id = new_id
                             end
                             filter_parts << "#{path_param}=#{foreign_id}"
                           end
                           klass
                         end
                       end
                     rescue
                     end
    if klass_or_obj
      if klass_or_obj.is_a?(ActiveRecord::Relation)
        klass_or_obj.where_values_hash.each do |whr|
          filter_parts << "#{whr.first}=#{whr.last}" if whr.last && !whr.last.is_a?(Array)
        end
        klass_or_obj = klass_or_obj.klass
        type_col = klass_or_obj.inheritance_column
        if klass_or_obj.column_names.include?(type_col) && klass_or_obj.name != klass_or_obj.base_class.name
          filter_parts << "#{type_col}=#{klass_or_obj.name}"
        end
      end
      filter = "?#{filter_parts.join('&')}" if filter_parts.present?
      app_routes = Rails.application.routes # In case we're operating in another engine, reference the application since Brick routes are placed there.
      klass = klass_or_obj.is_a?(ActiveRecord::Base) ? klass_or_obj.class : klass_or_obj
      relation = ::Brick.relations.fetch(rel_name || klass.table_name, nil)
      if (klass_or_obj&.is_a?(Class) && klass_or_obj < ActiveRecord::Base) ||
         (klass_or_obj&.is_a?(ActiveRecord::Base) && klass_or_obj.new_record? && (klass_or_obj = klass_or_obj.class))
        path = (proc = kwargs[:index_proc]) ? proc.call(klass_or_obj, relation) : "#{app_routes.path_for(controller: klass_or_obj.base_class._brick_index(nil, '/', relation), action: :index)}#{filter}"
        lt_args = [text || "Index for #{klass_or_obj.name.pluralize}", path]
      else
        # If there are multiple incoming parameters then last one is probably the actual ID, and first few might be some nested tree of stuff leading up to it
        path = (proc = kwargs[:show_proc]) ? proc.call(klass_or_obj, relation) : "#{app_routes.path_for(controller: klass_or_obj.class.base_class._brick_index(nil, '/', relation), action: :show, id: klass_or_obj)}#{filter}"
        lt_args = [text || "Show this #{klass_or_obj.class.name}", path]
      end
      kwargs.delete(:visited)
      link_to(*lt_args, **kwargs)
    else
      # puts "Warning:  link_to_brick could not find a class for \"#{controller_path}\" -- consider setting @_brick_model within that controller."
      # if (hits = res_names.keys & instance_variables.map { |v| v.to_s[1..-1] }).present?
      links = instance_variables.each_with_object(Hash.new { |h, k| h[k] = [] }) do |name, s|
                iv_name = name.to_s[1..-1]
                case (val = instance_variable_get(name))
                when ActiveRecord::Relation
                  s[val.klass] << iv_name
                when ActiveRecord::Base
                  s[val] << iv_name
                end
              end
      if links.length == 1 # If there's only one match then use any text that was supplied
        link_to_brick(text || links.first.last.join('/'), links.first.first, **kwargs)
      else
        links.each_with_object([]) { |v, s| s << link if link = link_to_brick(v.join('/'), v, **kwargs) }.join(' &nbsp; ').html_safe
      end
    end
  end # link_to_brick

end
