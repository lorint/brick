module Brick::Rails::FormTags
  # Our super speedy grid
  def brick_grid(relation = nil, sequence = nil, inclusions = nil, exclusions = nil,
                 cols = {}, bt_descrip: nil, poly_cols: nil, bts: {}, hms_keys: [], hms_cols: {},
                 show_header: nil, show_row_count: nil, show_erd_button: nil, show_in_app_button: nil, show_new_button: nil, show_avo_button: nil, show_aa_button: nil)
    # When a relation is not provided, first see if one exists which matches the controller name or
    # something has turned up in the instance variables.
    relation ||= (instance_variable_get("@#{controller_name}".to_sym) || _brick_resource_from_iv)
    klass = relation.klass

    nfc = Brick.config.sidescroll.fetch(relation.table_name, nil)&.fetch(:num_frozen_columns, nil) ||
          Brick.config.sidescroll.fetch(:num_frozen_columns, nil) ||
          0

    out = +''
    rel = ::Brick.relations&.fetch(relation.table_name, nil)
    if show_header != false
      out << brick_header(rel, klass, show_row_count, show_erd_button, show_in_app_button, show_avo_button, show_aa_button)
    end

    # HTML for brick_grid
    out << "<table id=\"#{table_name = relation.table_name.split('.').last}\" class=\"shadow\"#{ " x-num-frozen=\"#{nfc}\"" if nfc.positive? }>
  <thead><tr>"
    pk = klass.primary_key || []
    pk = [pk] unless pk.is_a?(Array)
    if pk.present?
      out << "<th x-order=\"#{pk.join(',')}\"></th>"
    end

    col_keys = relation.columns.each_with_object([]) do |col, s|
      col_name = col.name
      next if inclusions&.exclude?(col_name) ||
              (pk.include?(col_name) && [:integer, :uuid].include?(col.type) && !bts&.key?(col_name)) ||
              ::Brick.config.metadata_columns.include?(col_name) || poly_cols&.include?(col_name)

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
             s << '<th'
             if (col = cols[col_name]).is_a?(ActiveRecord::ConnectionAdapters::Column)
               s << " title=\"#{col.comment}\"" if col.respond_to?(:comment) && !col.comment.blank?
               s << if (bt = bts[col_name])
                      # Allow sorting for any BT except polymorphics
                      x_order = " x-order=\"#{bt.first}\"" unless bt[2]
                      "#{x_order}>BT #{bt[1].map { |bt_pair| bt_pair.first.bt_link(bt.first) }.join(' ')}"
                    else # Normal column
                      col_name_humanised = klass.human_attribute_name(col_name, { default: col_name })
                      x_order = " x-order=\"#{col_name}\"" if true
                      "#{x_order}>#{col_name_humanised}"
                    end
             elsif col # HM column
               options = {}
               options[col[1].inheritance_column] = col[1].name unless col[1] == col[1].base_class
               x_order = " x-order=\"#{col_name}\"" if true
               s << "#{x_order}>#{col[2]} "
               s << ((col.first || !col[1].table_exists?) ? col[3].to_s : "#{link_to(col[3], send("#{col[1]._brick_index}_path", options))}")
             elsif cust_cols.key?(col_name) # Custom column
               x_order = " x-order=\"#{col_name}\"" if true
               s << "#{x_order}>#{col_name}"
             elsif col_name.is_a?(Symbol) && (hot = bts[col_name]) # has_one :through
               x_order = " x-order=\"#{hot.first}\"" if true
               s << "#{x_order}>HOT " +
                    hot[1].map { |hot_pair| hot_pair.first.bt_link(col_name) }.join(' ')
             elsif (bt = composite_bt_names[col_name])
               x_order = " x-order=\"#{bt.first}\"" unless bt[2]
               s << "#{x_order}>BT comp " +
                    bt[1].map { |bt_pair| bt_pair.first.bt_link(bt.first) }.join(' ')
             else # Bad column name!
               s << "title=\"<< Unknown column >>\">#{col_name}"
             end
             s << '</th>'
           end
    out << "</tr></thead>
  <tbody>"
    # %%% Have once gotten this error with MSSQL referring to http://localhost:3000/warehouse/cold_room_temperatures__archive
    #     ActiveRecord::StatementTimeout in Warehouse::ColdRoomTemperatures_Archive#index
    #     TinyTds::Error: Adaptive Server connection timed out
    #     (After restarting the server it worked fine again.)
    row_count = 0
    # if @_brick_join_array&.include?()
    begin
      enumerator = relation.each # Runs the SQL query
    rescue ActiveRecord::SubclassNotFound => e
      # If there is a missing STI class then keep the show on the road by temporarily modifying the inheritance column.
      inh_col = klass.inheritance_column
      puts "WARNING:  At least one row in the \"#{klass.table_name}\" table has an invalid value in the inheritance column \"#{inh_col}\"."
      puts e.message
      klass.inheritance_column = '^\/^' # Some impossible column name
      enumerator = relation.each
      klass.inheritance_column = inh_col
    end
    # Add proxied info for @_brick_includes
    # proxy = relation.instance_variable_get(:@proxy) || relation.instance_variable_set(:@proxy, {})
    bi = relation.instance_variable_get(:@_brick_includes)
    relation.each do |obj|
      next unless klass.table_exists?

      rid = pk.map { |pk_part| obj.send(pk_part.to_sym) }
      out << "<tr x-id=\"#{rid.join('/')}\">\n"
      out << "<td class=\"col-sticky alternating-gray\">#{link_to('⇛', send("#{klass._brick_index(:singular)}_path".to_sym, rid),
                                                                  { class: 'big-arrow' })}</td>\n" if pk.present?
      ac = obj.instance_variable_get(:@association_cache) || obj.instance_variable_set(:@association_cache, {})
      # included = 
      bi&.each do |bi_key|
        (ac[col_name.to_sym] ||= []) << val if bi&.key?(col_name) # Add to any proxy things
      end
      sequence.each_with_index do |col_name, idx|
        val = obj.attributes[col_name]
        bt = bts[col_name] || composite_bt_names[col_name]
        out << '<td'
        (classes ||= []) << 'col-sticky alternating-gray' if idx < nfc
        (classes ||= []) << 'dimmed' unless cols.key?(col_name) || (cust_col = cust_cols[col_name]) ||
                                            (col_name.is_a?(Symbol) && bts.key?(col_name)) # HOT
        (classes ||= []) << 'right' if val.is_a?(Numeric) && !bt
        out << " class=\"#{classes.join(' ')}\"" if classes&.present?
        out << '>'
        if bt
          if bt[2] && obj.respond_to?(poly_id_col = "#{bt.first}_id") # Polymorphic?
            if (poly_id = obj.send(poly_id_col))
              bt_class = obj.send(klass.brick_foreign_type(bt.first))
              base_class_underscored = (::Brick.existing_stis[bt_class] || bt_class).constantize.base_class._brick_index(:singular)
              out << link_to("#{bt_class} ##{poly_id}", send("#{base_class_underscored}_path".to_sym, poly_id))
            end
          else # BT or HOT
            bt_class = bt[1].first.first
            if bt_descrip && (this_bt_descrip = bt_descrip[bt.first])
              descrips = this_bt_descrip[bt_class]
              bt_id_col = if descrips.nil?
                            puts "Caught it in the act for obj / #{col_name}!"
                          elsif descrips.length == 1
                            [klass.reflect_on_association(bt.first)&.foreign_key]
                          else
                            descrips.last
                          end
            end
            br_descrip_args = [obj]
            # 0..62 because Postgres column names are limited to 63 characters
            br_descrip_args += [descrips[0..-2].map { |id| obj.send(id.last[0..62]) }, bt_id_col] if descrips
            bt_txt = bt_class.brick_descrip(*br_descrip_args)
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
            elsif obj.respond_to?(ct_col = hms_col[1].to_sym) && (ct = obj.send(ct_col)&.to_i)&.positive?
              predicates = hms_col[2].each_with_object({}) { |v, s| s["__#{v.first}"] = v.last.is_a?(String) ? v.last : obj.send(v.last) if v.last }
              predicates.each { |k, v| predicates[k] = klass.name if v == '[sti_type]' }
              out << "#{link_to("#{ct || 'View'} #{hms_col.first}",
                                send("#{hm_klass._brick_index}_path".to_sym, predicates))}\n"
            end
          end
        elsif (col = cols[col_name]).is_a?(ActiveRecord::ConnectionAdapters::Column)
          out << if klass._brick_monetized_attributes&.include?(col_name)
                   val ? Money.new(val.to_i).format : ''
                 elsif klass.respond_to?(:uploaders) && klass.uploaders.key?(col_name.to_sym) &&
                       (url = obj.send(col.name)&.url) && # Has a Carrierwave URL? ...
                       # ... and either not restricting Carrierwave, or under the defined Carrierwave attachment limit?
                       (!(limit_carrierwave = ::Brick.config.limit_carrierwave) ||
                         (limit_carrierwave.is_a?(Numeric) &&
                         (carrierwave_count = instance_variable_get(:@_carrierwave_count) || 0) &&
                         ((carrierwave_count += 1) < limit_carrierwave) &&
                         instance_variable_set(:@_carrierwave_count, carrierwave_count)
                         )
                       )
                   "<img class=\"thumbImg\" src=\"#{url}\" title=\"#{val}\">"
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
      row_count += 1
    end
    out << "  </tbody>
</table>
"
    if rel && (total_row_count = rel.fetch(:rowcount, nil))
      total_row_count = total_row_count > row_count ? " (out of #{total_row_count})" : nil
    end

    set_grid_javascript(klass, pk, show_new_button, row_count, total_row_count)
    out.html_safe
  end # brick_grid

  # -----------------------------
  # Our mega show/new/update form
  def brick_form_for(obj, options = {}, model = obj.class, bts = {}, pk = (obj.class.primary_key || []))
    pk = [pk] unless pk.is_a?(Array)
    pk.map!(&:to_s)
    form_for(obj.becomes(model.base_class), options) do |f|
      out = +'<table class="shadow">'
      has_fields = false
      # If it's a new record, set any default polymorphic types
      bts&.each do |_k, v|
        if v[2]
          obj.send("#{model.brick_foreign_type(v.first)}=", v[1].first&.first&.name)
        end
      end if obj.new_record?
      hoa, hma, rtans = model._activestorage_actiontext_fields
      (model.column_names + hoa + hma + rtans.keys).each do |k|
        pk_pos = (pk.index(k)&.+ 1)
        next if (pk_pos && pk.length == 1 && !bts.key?(k)) ||
                ::Brick.config.metadata_columns.include?(k)

        col = model.columns_hash[k]
        if !col
          kwargs = if hoa.include?(k) # has_one_attached
                     { sql_type: 'binary', type: :file }
                   elsif hma.include?(k) # has_many_attached
                     { sql_type: 'binary', type: :files }
                   elsif rtans&.key?(k) # has_rich_text
                     k = rtans[k]
                     { sql_type: 'varchar', type: :text }
                   end
          col = (ActiveRecord::ConnectionAdapters::Column.new(
                  '', nil, ActiveRecord::ConnectionAdapters::SqlTypeMetadata.new(**kwargs)
                )) if kwargs
        end
        val = obj.attributes[k]
        out << "
  <tr>
    <th class=\"show-field\"#{" title=\"#{col&.comment}\"".html_safe if col&.respond_to?(:comment) && !col&.comment.blank?}>"
        has_fields = true
        if (bt = bts[k])
          # Add a final member in this array with descriptive options to be used in <select> drop-downs
          bt_name = bt[1].map { |x| x.first.name }.join('/')
          # %%% Only do this if the user has permissions to edit this bt field
          if bt[2] # Polymorphic?
            poly_class_name = orig_poly_name = obj.send(model.brick_foreign_type(bt.first))
            bt_pair = nil
            loop do
              bt_pair = bt[1].find { |pair| pair.first.name == poly_class_name }
              # Accommodate any valid STI by going up the chain of inheritance
              break unless bt_pair.nil? && poly_class_name = ::Brick.existing_stis[poly_class_name]
            end
            table_name = model.name.split('::').last.underscore.pluralize
            puts "*** Might be missing an STI class called #{orig_poly_name} whose base class should have this:
***   has_many :#{table_name}, as: :#{bt.first}
*** Can probably auto-configure everything using these lines in an initialiser:
***   Brick.sti_namespace_prefixes = { '::#{orig_poly_name}' => 'SomeParentModel' }
***   Brick.polymorphics = { '#{table_name}.#{bt.first}' => ['SomeParentModel'] }" if bt_pair.nil?
            # descrips = @_brick_bt_descrip[bt.first][bt_class]
            poly_id = obj.send("#{bt.first}_id")
            # bt_class.order(obj_pk = bt_class.primary_key).each { |obj| option_detail << [obj.brick_descrip(nil, obj_pk), obj.send(obj_pk)] }
          end
          bt_pair ||= bt[1].first # If there's no polymorphism (or polymorphism status is unknown), just get the first one
          bt_class = bt_pair&.first
          if bt.length < 4
            bt << (option_detail = [["(No #{bt_name} chosen)", '^^^brick_NULL^^^']])
            # %%% Accommodate composite keys for obj.pk at the end here
            collection, descrip_cols = bt_class&.order(Arel.sql("#{bt_class._br_quoted_name(bt_class.table_name)}.#{bt_class._br_quoted_name(obj_pk = bt_class.primary_key)}"))&.brick_list
            collection&.brick_(:each) do |obj|
              option_detail << [
                obj.brick_descrip(
                  descrip_cols&.first&.map { |col2| obj.send(col2.last) },
                  obj_pk
                ), obj.send(obj_pk)
              ]
            end
          end
          out << "BT #{bt_class&.bt_link(bt.first) || orig_poly_name}"
        else
          out << model.human_attribute_name(k, { default: k })
        end
        out << " (PK #{pk_pos})" if pk_pos
        out << "
    </th>
    <td>
        "
        if pk_pos
          out << val.to_s
        else
          out << f.brick_field(k, html_options = {}, val, col, bt, bt_class, bt_name, bt_pair)
        end
        out << "
    </td>
  </tr>"
      end
      if has_fields
        out << "<tr><td colspan=\"2\">#{f.submit({ class: 'update' })}</td></tr>"
      else
        out << '<tr><td colspan="2">(No displayable fields)</td></tr>'
      end
      out << '</table>'
      if model.name == 'ActiveStorage::Attachment'
        begin
          out << ::Brick::Rails.display_binary(obj&.blob&.download, 500_000)&.html_safe
        rescue
        end
      end
      out.html_safe
    end
  end # brick_form_for

  # ------------------------------------------
  # Our cool N:M checkbox constellation editor
  def brick_constellation(relation = nil, options = {}, x_axis: nil, y_axis: nil, bt_descrip: nil, bts: {},
                          show_header: nil, show_erd_button: nil, show_in_app_button: nil, show_new_button: nil, show_avo_button: nil, show_aa_button: nil)
    relation ||= (instance_variable_get("@#{controller_name}".to_sym) || _brick_resource_from_iv)
    klass = relation.klass
    if (axes = options[:axes])
      x_axis, y_axis = axes
    end
    x_axis, x_list, y_axis, y_list, existing = _n_m_prep(relation, x_axis, y_axis)

    out = +''
    rel = ::Brick.relations&.fetch(relation.table_name, nil)
    if show_header != false
      out << brick_header(rel, klass, false, show_erd_button, show_in_app_button, show_avo_button, show_aa_button)
    end

    # HTML for constellation
    prefix = options[:prefix]
    out << "<form action=\"#{"#{prefix}/" if prefix}brick_constellation\">
<table id=\"#{table_name = relation.table_name.split('.').last}\" class=\"shadow\">
  <thead><tr><td class=\"brick-note\">Checkbox changes are saved immediately</td>"
    # Header row with X axis values
    # (In order for grid highlighting to function, these TH elements must have no whitespace between them.
    # In this way the Javascript headerCols array will be set properly.)
    x_list.each do |x_item|
      out << "<th>#{x_item.first}</th>"
    end
    out << "</tr></thead>
  <tbody>
"
    obj_path = "#{klass._brick_index(:singular)}_path".to_sym
    link_arrow = link_to('⇛', send(obj_path, '____'), { class: 'big-arrow' })
    y_list.each do |y_item|
      out << "  <tr><th class=\"col-sticky\">#{y_item.first}</th>
"
      x_list.each do |x_item|
        checked = existing.find { |e| e[1] == x_item.last && e[2] == y_item.last }
        item_id = checked.first.join('%2F') if checked
        out << "    <td><input type=\"checkbox\" name=\"#{table_name}\" #{"x-id=\"#{item_id}\" " if checked
                           }\" value=\"#{x_item.last}_#{y_item.last}\"#{' checked' if checked}>
    #{link_arrow.gsub('____', item_id) if checked}</td>
"
      end
      out << "  </tr>
"
    end
    out << "  </tbody>
</table>
<script>
  var constellation = document.getElementById(\"#{table_name}\");
  var nextSib,
      _this;
  [... constellation.getElementsByTagName(\"INPUT\")].forEach(function (x) {
    x.addEventListener(\"change\", function (y) {
      _this = this;
      if (this.checked) {
        var ids = this.value.split(\"_\");
        doFetch(\"POST\", {modelName: \"#{klass.name}\",
                           args: [#{x_axis[1].inspect}, ids[0], #{y_axis[1].inspect}, ids[1]],
                           _brick_action: \"/#{prefix}brick_associate\"},
          function (p) { // If it returns successfully, create an <a> element
            p.text().then(function (response) {
              var recordId = JSON.parse(response).data;
              if (recordId) {
                // console.log(_this.getAttribute(\"x-id\"));
                var tmp = document.createElement(\"DIV\");
                tmp.innerHTML = \"#{link_arrow.gsub('"', '\"')}\".replace(\"____\", recordId);
                _this.parentElement.append(tmp.firstChild);
              }
            });
          }
        );
      } else if (nextSib = this.nextElementSibling) {
        doFetch(\"DELETE\", {modelName: \"#{klass.name}\",
                id: this.getAttribute(\"x-id\"),
                _brick_action: \"/#{prefix}brick_associate\"},
          function (p) { // If it returns successfully, remove the an <a> element
            _this.parentElement.removeChild(nextSib);
          }
        );
      }
    });
  });
</script>
</form>
"
    set_grid_javascript(klass, klass._pk_as_array, false)
    out.html_safe
  end # brick_constellation

  # ---------------------------------
  # Our cool N:M bezier visualisation
  # (...... work in progress .......)
  def brick_bezier(relation = nil, options = {}, x_axis: nil, y_axis: nil, bt_descrip: nil, bts: {})
    relation ||= (instance_variable_get("@#{controller_name}".to_sym) || _brick_resource_from_iv)
    x_axis, x_list, y_axis, y_list, existing = _n_m_prep(relation, x_axis, y_axis)
    rel = ::Brick.relations&.fetch(relation.table_name, nil)
    # HTML for constellation
    # X axis (List on left side)
    out = +"<table id=\"#{x_axis.first}\" class=\"shadow\">
  <tbody>
"
    x_list.each_with_index { |x_item, idx| out << "    <tr>#{"<th rowspan=\"#{x_list.length}\">#{x_axis.first}</th>" if idx.zero?}<td>#{x_item.first}</td></tr>" }
    out << "  </tbody>
</table>
"

    # Y axis (List on right side)
    out << "<table id=\"#{y_axis.first}\" class=\"shadow\">
  <tbody>
"
    y_list.each_with_index { |y_item, idx| out << "    <tr><td>#{y_item.first}</td>#{"<th rowspan=\"#{y_list.length}\">#{y_axis.first}</th>" if idx.zero?}</tr>" }
    out << "  </tbody>
</table>
"

    out.html_safe
  end # brick_bezier

  # ---------------------------------------------------------------------------------------------------------
  def brick_header(rel, klass, show_row_count, show_erd_button, show_in_app_button, show_avo_button, show_aa_button)
    out = +"<div id=\"headerTopContainer\"><table id=\"headerTop\"></table>
  <div id=\"headerTopAddNew\">
    <div id=\"headerButtonBox\">
"
    unless show_row_count == false
      out << "      <div id=\"rowCount\"></div>
"
    end
    unless show_erd_button == false
      out << "      <div id=\"imgErd\" title=\"Show ERD\"></div>
"
    end
    if rel && show_in_app_button != false && (in_app = rel.fetch(:existing, nil)&.fetch(:index, nil))
      begin
        in_app = send("#{in_app}_path") if in_app.is_a?(Symbol)
        out << "      <td title=\"Show in app\">#{link_to(::Brick::Rails::IN_APP.html_safe, in_app)}</td>
"
      rescue ActionController::UrlGenerationError # Avoid snags like "No route matches {:action=>"index", :controller=>"categories/products"}, missing required keys: [:category_id]"
      end
    end
    if show_avo_button != false && Object.const_defined?('Avo') && ::Avo.respond_to?(:railtie_namespace) && klass.name.exclude?('::')
      out << "
        <td>#{link_to_brick(
            ::Brick::Rails::AVO_SVG.html_safe,
            { index_proc: Proc.new do |_avo_model, relation|
                            path_helper = "resources_#{relation.fetch(:auto_prefixed_schema, nil)}#{klass.model_name.route_key}_path".to_sym
                            ::Avo.railtie_routes_url_helpers.send(path_helper) if ::Avo.railtie_routes_url_helpers.respond_to?(path_helper)
                          end,
              title: "#{klass.name} in Avo" }
        )}</td>
"
    end

    if show_aa_button != false && Object.const_defined?('ActiveAdmin')
      ActiveAdmin.application.namespaces.names.each do |ns|
        out << "
        <td>#{link_to_brick(
            ::Brick::Rails::AA_PNG.html_safe,
            { index_proc: Proc.new do |aa_model, relation|
                            path_helper = "#{ns}_#{relation.fetch(:auto_prefixed_schema, nil)}#{aa_model.model_name.route_key}_path".to_sym
                            send(path_helper) if respond_to?(path_helper)
                          end,
              title: "#{rel[:class_name]} in ActiveAdmin" }
        )}</td>
"
      end
    end
    out << "    </div>
  </div>
</div>
"
    out
  end # brick_header

  # All the standard CSS with teal colouration for use with Brick
  def brick_css(theme = nil)
    "<style>#{::Brick::Rails::BRICK_CSS}</style>".html_safe
  end

  # -----------------------------------------------------------------------------------------------
  def set_grid_javascript(klass, pk, show_new_button = nil, row_count = nil, total_row_count = nil)
    table_name = klass.table_name.split('.').last

    # Javascript for brick_grid and brick_constellation
    grid_scripts = (@_brick_javascripts ||= {})[:grid_scripts] = +''

    grid_scripts << "
// Plunk the row count in now that we know it
var rowCount = document.getElementById(\"rowCount\");
if (rowCount) rowCount.innerHTML = \"#{pluralize(row_count, "row")}#{total_row_count} &nbsp;\";
var #{table_name}HtColumns;
" unless row_count.nil?

    grid_scripts << "
// Snag first TR for sticky header
var grid = document.getElementById(\"#{table_name}\");
#{table_name}HtColumns = grid && [grid.getElementsByTagName(\"TR\")[0]];
var headerTop = document.getElementById(\"headerTop\");
var headerCols;
if (grid) {
  // COLUMN HEADER AND TABLE CELL HIGHLIGHTING
  var gridHighHeader = null,
      gridHighCell = null;
  grid.addEventListener(\"mouseenter\", gridMove);
  grid.addEventListener(\"mousemove\", gridMove);
  grid.addEventListener(\"mouseleave\", function (evt) {
    if (gridHighCell) gridHighCell.classList.remove(\"highlight\");
    gridHighCell = null;
    if (gridHighHeader) gridHighHeader.classList.remove(\"highlight\");
    gridHighHeader = null;
  });
  function gridMove(evt) {
    var lastHighCell = gridHighCell;
    gridHighCell = document.elementFromPoint(evt.x, evt.y);
    while (gridHighCell && gridHighCell.tagName !== \"TD\" && gridHighCell.tagName !== \"TH\")
      gridHighCell = gridHighCell.parentElement;
    if (gridHighCell) {
      if (lastHighCell !== gridHighCell) {
        gridHighCell.classList.add(\"highlight\");
        if (lastHighCell) lastHighCell.classList.remove(\"highlight\");
      }
      var lastHighHeader = gridHighHeader;
      if ((gridHighHeader = headerCols[gridHighCell.cellIndex]) && lastHighHeader !== gridHighHeader) {
        if (gridHighHeader) gridHighHeader.classList.add(\"highlight\");
        if (lastHighHeader) lastHighHeader.classList.remove(\"highlight\");
      }
    }
  }
  // // Less touchy navigation back or forward in history when using mouse wheel
  // grid.addEventListener(\"wheel\", function (evt) {
  //   grid.scrollLeft += evt.deltaX;
  //   document.body.scrollTop += (evt.deltaY * 0.6);
  //   evt.preventDefault();
  //   return false;
  // });
}
function setHeaderSizes() {
  if (grid.clientWidth > window.outerWidth)
    document.getElementById(\"titleBox\").style.width = grid.clientWidth;
  // console.log(\"start\");
  // See if the headerTop is already populated
  // %%% Grab the TRs from headerTop, clear it out, do this stuff, add them back
  headerTop.innerHTML = \"\"; // %%% Would love to not have to clear it out like this every time!  (Currently doing this to support resize events.)
  var isEmpty = headerTop.childElementCount === 0;
  var numFixed = parseInt(grid.getAttribute(\"x-num-frozen\")) || 0;
  var fixedColLefts = [0];

  // Set up proper sizings of sticky column header
  var node;
  for (var j = 0; j < #{table_name}HtColumns.length; ++j) {
    var row = #{table_name}HtColumns[j];
    var tr = isEmpty ? document.createElement(\"TR\") : headerTop.childNodes[j];
    tr.innerHTML = row.innerHTML.trim();
    var curLeft = 0.0;
    // Match up widths from the original column headers
    for (var i = 0; i < row.childNodes.length; ++i) {
      node = row.childNodes[i];
      if (node.nodeType === 1) {
        var th = tr.childNodes[i];
        th.style.minWidth = th.style.maxWidth = getComputedStyle(node).width;
        // Add \"left: __px\" style to the fixed-width column THs
        if (i <= numFixed) {
          th.style.position = \"sticky\";
          th.style.backgroundColor = \"#008061\";
          th.style.zIndex = \"1\";
          th.style.left = curLeft + \"px\";
          fixedColLefts.push(curLeft += node.clientWidth);
        }
        if (#{pk&.present? ? 'i > 0' : 'true'}) {
          // Add <span> at the end
          var span = document.createElement(\"SPAN\");
          span.className = \"exclude\";
          span.innerHTML = \"X\";
          span.addEventListener(\"click\", function (e) {
            e.stopPropagation();
            doFetch(\"POST\", {_brick_exclude: this.parentElement.getAttribute(\"x-order\")});
          });
          th.appendChild(span);
        }
      }
    }
    headerCols = tr.childNodes;
    if (isEmpty) headerTop.appendChild(tr);
  }
  // Add \"left: __px\" style to all fixed-width column TDs
  [...grid.children[1].children].forEach(function (row) {
    for (var j = 1; j <= numFixed; ++j) {
      row.children[j].style.left = fixedColLefts[j] + 'px';
    }
  });
  grid.style.marginTop = \"-\" + getComputedStyle(headerTop).height;
  // console.log(\"end\");
}

if (headerTop) {
  onImagesLoaded(function() {
    setHeaderSizes();
  });
  window.addEventListener(\"resize\", function(event) {
    setHeaderSizes();
  }, true);#{
    "
    var headerButtonBox = document.getElementById(\"headerButtonBox\");
    if (headerButtonBox) {
      var addNew = document.createElement(\"A\");
      addNew.id = \"addNew\";
      addNew.href = \"#{link_to_brick(klass, new: true, path_only: true)}\";
      addNew.title = \"New #{table_name.singularize}\";
      addNew.innerHTML = '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\"><path fill=\"#fff\" d=\"M24 10h-10v-10h-4v10h-10v4h10v10h4v-10h10z\"/></svg>';
      headerButtonBox.append(addNew);
    }
" unless klass.is_view? || show_new_button == false
  }
}

function onImagesLoaded(event) {
  var images = document.getElementsByTagName(\"IMG\");
  var numLoaded = images.length;
  for (var i = 0; i < images.length; ++i) {
    if (images[i].complete)
      --numLoaded;
    else {
      images[i].addEventListener(\"load\", function() {
        if (--numLoaded <= 0)
          event();
      });
    }
  }
  if (numLoaded <= 0)
    event();
}
"
  end

  # -------------------------------------
  def _n_m_prep(relation, x_axis, y_axis)
    # Just find the first two BT things at this point

    klass = relation.klass
    fk_assocs = klass.reflect_on_all_associations.each_with_object([]) do |assoc, s|
      s << [assoc.name.to_s, assoc.foreign_key, assoc.klass] if assoc.belongs_to?
    end

    if (x_axis = fk_assocs.find { |assoc| assoc.include?(x_axis) })
      fk_assocs -= x_axis
    end
    if (y_axis = fk_assocs.find { |assoc| assoc.include?(y_axis) })
      fk_assocs -= y_axis
    end
    y_axis = fk_assocs.shift unless y_axis
    x_axis = fk_assocs.shift unless x_axis
    puts "FK Leftovers: #{fk_assocs.join(', ')}" unless fk_assocs.empty?

    pk_as_array = klass._pk_as_array
    existing = relation.each_with_object([]) do |row, s|
                 row_id = pk_as_array.map { |pk_part| row.send(pk_part) }
                 if (x_id = row.send(x_axis[1])) && (y_id = row.send(y_axis[1]))
                   s << [row_id, x_id, y_id]
                 end
               end
    x_list = _expand_collection(x_axis.last.all)
    y_list = _expand_collection(y_axis.last.all)
    [x_axis, x_list, y_axis, y_list, existing]
  end

  def _expand_collection(relation)
    collection, descrip_cols = relation.brick_list
    details = []
    obj_pk = relation.klass.primary_key
    collection&.brick_(:each) do |obj|
      details << [
        obj.brick_descrip(
          descrip_cols&.first&.map { |col2| obj.send(col2.last) },
          obj_pk
        ), obj.send(obj_pk)
      ]
    end
    details
  end

  # --------------------------------
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

    unless (is_path_only = kwargs.delete(:path_only))
      text = ((args.first.is_a?(String) || args.first.is_a?(Proc)) && args.shift) || args[1]
      text = text.call if text.is_a?(Proc)
    end
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
      end
      klass = klass_or_obj.is_a?(ActiveRecord::Base) ? klass_or_obj.class : klass_or_obj
      return unless klass.table_exists?

      if klass_or_obj.is_a?(Class) && klass_or_obj <= ActiveRecord::Base
        type_col = klass_or_obj.inheritance_column
        if klass_or_obj.column_names.include?(type_col) && klass_or_obj.name != klass_or_obj.base_class.name
          filter_parts << "#{type_col}=#{klass_or_obj.name}"
        end
      end
      filter = "?#{filter_parts.join('&')}" if filter_parts.present?
      app_routes = Rails.application.routes # In case we're operating in another engine, reference the application since Brick routes are placed there.
      relation = ::Brick.relations.fetch(rel_name || klass.table_name, nil)
      if (klass_or_obj&.is_a?(Class) && klass_or_obj < ActiveRecord::Base) ||
         (klass_or_obj&.is_a?(ActiveRecord::Base) && klass_or_obj.new_record? && (klass_or_obj = klass_or_obj.class))
        if kwargs.delete(:new)
          path = (proc = kwargs[:new_proc]) ? proc.call(klass_or_obj, relation) : "#{app_routes.path_for(controller: klass_or_obj.base_class._brick_index(:singular, '/', relation, true), action: :new)}#{filter}"
          return path if is_path_only

          lt_args = [text || "New #{klass_or_obj.name}", path]
        else
          path = (proc = kwargs[:index_proc]) ? proc.call(klass_or_obj, relation) : "#{app_routes.path_for(controller: klass_or_obj.base_class._brick_index(nil, '/', relation, true), action: :index)}#{filter}"
          return path if is_path_only

          lt_args = [text || "Index for #{klass_or_obj.name.pluralize}", path]
        end
      else
        # If there are multiple incoming parameters then last one is probably the actual ID, and first few might be some nested tree of stuff leading up to it
        path = (proc = kwargs[:show_proc]) ? proc.call(klass_or_obj, relation) : "#{app_routes.path_for(controller: klass_or_obj.class.base_class._brick_index(nil, '/', relation, true), action: :show, id: klass_or_obj)}#{filter}"
        return path if is_path_only

        lt_args = [text || "Show this #{klass_or_obj.class.name}", path]
      end
      kwargs.delete(:visited)
      link_to(*lt_args, **kwargs)
    else
      # puts "Warning:  link_to_brick could not find a class for \"#{controller_path}\" -- consider setting @_brick_model within that controller."
      # if (hits = res_names.keys & instance_variables.map { |v| v.to_s[1..-1] }).present?
      if (links = _brick_relation_from_iv(true)).length == 1 # If there's only one match then use any text that was supplied
        link_to_brick(text || links.first.last.join('/'), links.first.first, **kwargs)
      else
        links.each_with_object([]) do |v, s|
          if (link = link_to_brick(v.join('/'), v, **kwargs))
            s << link
          end
        end.join(' &nbsp; ').html_safe
      end
    end
  end # link_to_brick

  # ---------------------------------
  def brick_add_column(model, prefix)
    # TODO: Make a server control architecture that has separate javascript snippets
    # Have post back go to a common "brick_schema" endpoint, this one for add_column
"
<table id=\"tblAddCol\"><tr>
  <td rowspan=\"2\">Add<br>Column</td>
  <td class=\"paddingBottomZero\">Type</td><td class=\"paddingBottomZero\">Name</td>
  <td rowspan=\"2\"><input type=\"button\" id=\"btnAddCol\" value=\"+\"></td>
</tr><tr><td class=\"paddingTopZero\">
  <select id=\"ddlColType\">
 <option value=\"string\">String</option>
 <option value=\"text\">Text</option>
 <option value=\"integer\">Integer</option>
 <option value=\"bool\">Boolean</option>
</select></td>
<td class=\"paddingTopZero\"><input id=\"txtColName\"></td>
</tr></table>
<script>
var btnAddCol = document.getElementById(\"btnAddCol\");
btnAddCol.addEventListener(\"click\", function () {
 var txtColName = document.getElementById(\"txtColName\");
 var ddlColType = document.getElementById(\"ddlColType\");
 doFetch(\"POST\", {modelName: \"#{model.name}\",
                    colName: txtColName.value, colType: ddlColType.value,
                    _brick_action: \"/#{prefix}brick_schema\"},
   function () { // If it returns successfully, do a page refresh
     location.href = location.href;
   }
 );
});
</script>
"
  end

private

  # Dig through all instance variables with hopes to find any that appear related to ActiveRecord
  def _brick_relation_from_iv(trim_ampersand = false)
    instance_variables.each_with_object(Hash.new { |h, k| h[k] = [] }) do |name, s|
      iv_name = trim_ampersand ? name.to_s[1..-1] : name
      case (val = instance_variable_get(name))
      when ActiveRecord::Relation
        s[val.klass] << iv_name
      when ActiveRecord::Base
        s[val] << iv_name
      end
    end
  end

  def _brick_resource_from_iv
    # Failing that, dig through the instance variables with hopes to find something that is an ActiveRecord::Relation
    case (collections = _brick_relation_from_iv).length
    when 0
      puts '#brick_grid:  Not having been provided with a collection to work from, searched through all instance variables to find an ActiveRecord::Relation.  None could be found.'
      return
    when 1 # If there's only one type match then simply get the first one, hoping that this is what they intended
      relation = instance_variable_get(iv = (chosen = collections.first).last.first)
      puts "#brick_grid:  Not having been provided with a collection to work from, first tried @#{controller_name}.
            Failing that, have searched through instance variables and found #{iv} of type #{chosen.first.name}.
            Running with it!"
      relation
    else
      myriad = collections.each_with_object([]) { |c, s| c.last.each { |iv| s << "#{iv} (#{c.first.name})" } }
      puts "#brick_grid:  Not having been provided with a collection to work from, first tried @#{controller_name}, and then searched through all instance variables.
            Found ActiveRecord::Relation objects of multiple types:
              #{myriad.inspect}
            Not knowing which of these to render, have erred on the side of caution and simply provided this warning message."
      return
    end
  end
end
