module Brick::Rails::FormBuilder
  DT_PICKERS = { datetime: 'datetimepicker', timestamp: 'datetimepicker', time: 'timepicker', date: 'datepicker' }

  # When this field is one of the appropriate types, will set one of these instance variables accordingly:
  #   @_text_fields_present - To include trix editor
  #   @_date_fields_present - To include flatpickr date / time editor
  #   @_json_fields_present - To include JSONEditor
  def brick_field(method, html_options = {}, val = nil, col = nil,
                  bt = nil, bt_class = nil, bt_name = nil, bt_pair = nil)
    model = self.object.class
    col ||= model.columns_hash[method]
    out = +'<table><tr><td>'
    html_options[:class] = 'dimmed' unless val
    is_revert = true
    template = instance_variable_get(:@template)
    if bt
      bt_class ||= bt[1].first.first
      bt_name ||= bt[1].map { |x| x.first.name }.join('/')
      bt_pair ||= bt[1].first

      html_options[:prompt] = "Select #{bt_name}"
      out << self.select(method.to_sym, bt[3], { value: val || '^^^brick_NULL^^^' }, html_options)
      bt_obj = nil
      begin
        bt_obj = bt_class&.find_by(bt_pair[1] => val)
      rescue ActiveRecord::SubclassNotFound => e
        # %%% Would be cool to indicate to the user that a subclass is missing.
        # Its name starts at:  e.message.index('failed to locate the subclass: ') + 31
      end
      bt_link = if bt_obj
                  bt_path = template.send(
                              "#{bt_class.base_class._brick_index(:singular)}_path".to_sym,
                              bt_obj.send(bt_class.primary_key.to_sym)
                            )
                  template.link_to('⇛', bt_path, { class: 'show-arrow' })
                elsif val
                  "<span class=\"orphan\">Orphaned ID: #{val}</span>".html_safe
                end
      out << bt_link if bt_link
    elsif @_brick_monetized_attributes&.include?(method)
      out << self.text_field(method.to_sym, html_options.merge({ value: Money.new(val.to_i).format }))
    else
      col_type = if model.json_column?(col) || val.is_a?(Array)
                   :json
                 elsif col&.sql_type == 'geography'
                   col.sql_type
                 else
                   col&.type
                 end
      case (col_type ||= col&.sql_type)
      when :string, :text, :citext
        if ::Brick::Rails::FormBuilder.is_bcrypt?(val) # || .readonly?
          is_revert = false
          out << ::Brick::Rails::FormBuilder.hide_bcrypt(val, nil, 1000)
        elsif col_type == :string
          if model.respond_to?(:enumerized_attributes) && (opts = (attr = model.enumerized_attributes[method])&.options).present?
            enum_html_options = attr.kind_of?(Enumerize::Multiple) ? html_options.merge({ multiple: true, size: opts.length + 1 }) : html_options
            out << self.select(method.to_sym, [["(No #{method} chosen)", '^^^brick_NULL^^^']] + opts, { value: val || '^^^brick_NULL^^^' }, enum_html_options)
          else
            out << self.text_field(method.to_sym, html_options)
          end
        else
          template.instance_variable_set(:@_text_fields_present, true)
          out << self.hidden_field(method.to_sym, html_options)
          out << "<trix-editor input=\"#{self.field_id(method)}\"></trix-editor>"
        end
      when :boolean
        out << self.check_box(method.to_sym)
      when :integer, :decimal, :float
        digit_pattern = col_type == :integer ? '\d*' : '\d*(?:\.\d*|)'
        # Used to do this for float / decimal:  self.number_field method.to_sym
        out << self.text_field(method.to_sym, { pattern: digit_pattern, class: 'check-validity' })
      when *DT_PICKERS.keys
        template.instance_variable_set(:@_date_fields_present, true)
        out << self.text_field(method.to_sym, { class: DT_PICKERS[col_type] })
      when :uuid
        is_revert = false
        # Postgres naturally uses the +uuid_generate_v4()+ function from the uuid-ossp extension
        # If it's not yet enabled then:  create extension \"uuid-ossp\";
        # ActiveUUID gem created a new :uuid type
        out << val if val
      when :ltree
        # In Postgres labels of data stored in a hierarchical tree-like structure
        # If it's not yet enabled then:  create extension ltree;
        out << val if val
      when :binary
        is_revert = false
        if val
          # %%% This same kind of geography check is done two other times in engine.rb ... would be great to DRY it up.
          out << if val.length < 31 && (val.length - 6) % 8 == 0 && val[0..5].bytes == [230, 16, 0, 0, 1, 12]
                   ::Brick::Rails.display_value('geography', val)
                 else
                   ::Brick::Rails.display_binary(val)
                 end
        end
      when :primary_key
        is_revert = false
      when :json, :jsonb
        template.instance_variable_set(:@_json_fields_present, true)
        if val.is_a?(String)
          val_str = val
        else
          eheij = ActiveSupport::JSON::Encoding.escape_html_entities_in_json
          ActiveSupport::JSON::Encoding.escape_html_entities_in_json = false if eheij
          val_str = val&.to_json
          ActiveSupport::JSON::Encoding.escape_html_entities_in_json = eheij
        end
        # Because there are so danged many quotes in JSON, escape them specially by converting to backticks.
        # (and previous to this, escape backticks with our own goofy code of ^^br_btick__ )
        out << (json_field = self.hidden_field(method.to_sym, { class: 'jsonpicker', value: val_str&.gsub('`', '^^br_btick__')&.tr('\"', '`')&.html_safe }))
        out << "<div id=\"_br_json_#{self.field_id(method)}\"></div>"
      else
        is_revert = false
        out << (::Brick::Rails.display_value(col_type, val)&.html_safe || '')
      end
    end
    if is_revert
      out << "</td>
"
      out << '<td><svg class="revert" width="1.5em" viewBox="0 0 512 512"><use xlink:href="#revertPath" /></svg>'
    end
    out << "</td></tr></table>
"
    out.html_safe
  end # brick_field

  # --- CLASS METHODS ---

  def self.is_bcrypt?(val)
    val.is_a?(String) && val.length == 60 && val.start_with?('$2a$')
  end

  def self.hide_bcrypt(val, is_xml = nil, max_len = 200)
    if ::Brick::Rails::FormBuilder.is_bcrypt?(val)
      '(hidden)'
    else
      if val.is_a?(String)
        val = val.dup.force_encoding('UTF-8').strip
        return CGI.escapeHTML(val) if is_xml
  
        if val.length > max_len
          if val[0] == '<' # Seems to be HTML?
            cur_len = 0
            cur_idx = 0
            # Find which HTML tags we might be inside so we can apply ending tags to balance
            element_name = nil
            in_closing = nil
            elements = []
            val.each_char do |ch|
              case ch
              when '<'
                element_name = +''
              when '/' # First character of tag is '/'?
                in_closing = true if element_name == ''
              when '>'
                if element_name
                  if in_closing
                    if (idx = elements.index { |tag| tag.downcase == element_name.downcase })
                      elements.delete_at(idx)
                    end
                  elsif (tag_name = element_name.split.first).present?
                    elements.unshift(tag_name)
                  end
                  element_name = nil
                  in_closing = nil
                end
              else
                element_name << ch if element_name
              end
              cur_idx += 1
              # Unless it's inside wickets then this is real text content, and see if we're at the limit
              break if element_name.nil? && ((cur_len += 1) > max_len)
            end
            val = val[0..cur_idx]
            # Somehow still in the middle of an opening tag right at the end? (Should never happen)
            if !in_closing && (tag_name = element_name&.split&.first)&.present?
              elements.unshift(tag_name)
              val << '>'
            end
            elements.each do |closing_tag|
              val << "</#{closing_tag}>"
            end
          else # Not HTML, just cut it at the length
            val = val[0...max_len]
          end
          val = "#{val}..."
        end
        val
      else
        val.to_s
      end
    end
  end  
end
