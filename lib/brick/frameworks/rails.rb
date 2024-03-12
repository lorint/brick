# frozen_string_literal: true

# require 'brick/frameworks/rails/controller'
require 'brick/frameworks/rails/engine'

module ::Brick::Rails
  class << self
    # Low-level way to render read-only data for a field based on its data type.
    # Used by both brick_grid and brick_form_for (which gets down to this low-level
    # implementation from brick_field).
    def display_value(col_type, val, lat_lng = nil)
      is_mssql_geography = nil
      # Some binary thing that really looks like a Microsoft-encoded WGS84 point?  (With the first two bytes, E6 10, indicating an EPSG code of 4326)
      if col_type == :binary && val && ::Brick.is_geography?(val)
        col_type = 'geography'
        is_mssql_geography = true
      end
      case col_type
      when 'geometry', 'geography'
        if Object.const_defined?('RGeo')
          @is_mysql = ['Mysql2', 'Trilogy'].include?(ActiveRecord::Base.connection.adapter_name) if @is_mysql.nil?
          @is_mssql = ActiveRecord::Base.connection.adapter_name == 'SQLServer' if @is_mssql.nil?
          val_err = nil

          if @is_mysql || (is_mssql_geography ||=
                            (@is_mssql ||
                              (val && ::Brick.is_geography?(val))
                            )
                          )
            # MySQL's \"Internal Geometry Format\" and MSSQL's Geography are like WKB, but with an initial 4 bytes that indicates the SRID.
            if (srid = val&.[](0..3)&.unpack('I'))
              val = val.dup.force_encoding('BINARY')[4..-1].bytes

              # MSSQL spatial bitwise flags, often 0C for a point:
              # xxxx xxx1 = HasZValues
              # xxxx xx1x = HasMValues
              # xxxx x1xx = IsValid
              # xxxx 1xxx = IsSinglePoint
              # xxx1 xxxx = IsSingleLineSegment
              # xx1x xxxx = IsWholeGlobe
              # Convert Microsoft's unique geography binary to standard WKB
              # (MSSQL point usually has two doubles, lng / lat, and can also have Z)
              if is_mssql_geography
                if val[0] == 1 && (val[1] & 8 > 0) && # Single point?
                   (val.length - 2) % 8 == 0 && val.length < 27 # And containing up to three 8-byte values?
                  val = [0, 0, 0, 0, 1] + val[2..-1].reverse
                else
                  val_err = '(Microsoft internal SQL geography type)'
                end
              end
            end
          end
          unless val_err || val.nil?
            val = if ((geometry = RGeo::WKRep::WKBParser.new.parse(val.pack('c*'))).is_a?(RGeo::Cartesian::PointImpl) ||
                      geometry.is_a?(RGeo::Geos::CAPIPointImpl)) &&
                     !(geometry.y == 0.0 && geometry.x == 0.0)
                    # Create a POINT link to this style of Google maps URL:  https://www.google.com/maps/place/38.7071296+-121.2810649/@38.7071296,-121.2810649,12z
                    "<a href=\"https://www.google.com/maps/place/#{geometry.y}+#{geometry.x}/@#{geometry.y},#{geometry.x},12z\" target=\"blank\">#{geometry.to_s}</a>"
                  end
          end
          val_err || val
        else
          '(Add RGeo gem to parse geometry detail)'
        end
      when :binary
        ::Brick::Rails.display_binary(val)
      else
        if col_type
          if lat_lng && !(lat_lng.first.zero? && lat_lng.last.zero?)
            # Create a link to this style of Google maps URL:  https://www.google.com/maps/place/38.7071296+-121.2810649/@38.7071296,-121.2810649,12z
            "<a href=\"https://www.google.com/maps/place/#{lat_lng.first}+#{lat_lng.last}/@#{lat_lng.first},#{lat_lng.last},12z\" target=\"blank\">#{val}</a>"
          elsif val.is_a?(Numeric) && ::ActiveSupport.const_defined?(:NumberHelper)
            ::ActiveSupport::NumberHelper.number_to_delimited(val, delimiter: ',')
          else # Text or HTML based content
            ::Brick::Rails.hide_bcrypt(val, col_type == :xml)
          end
        else # Don't take chances if we can't figure out the data type
          '?'
        end
      end
    end

    def display_binary(val, max_size = 100_000)
      return unless val

      @image_signatures ||= { (+"\xFF\xD8\xFF\xEE").force_encoding('ASCII-8BIT') => 'jpeg',
                              (+"\xFF\xD8\xFF\xE0\x00\x10\x4A\x46\x49\x46\x00\x01").force_encoding('ASCII-8BIT') => 'jpeg',
                              (+"\xFF\xD8\xFF\xDB").force_encoding('ASCII-8BIT') => 'jpeg',
                              (+"\xFF\xD8\xFF\xE1").force_encoding('ASCII-8BIT') => 'jpeg',
                              (+"\x89PNG\r\n\x1A\n").force_encoding('ASCII-8BIT') => 'png',
                              '<svg' => 'svg+xml', # %%% Not yet very good detection for SVG
                              (+'BM').force_encoding('ASCII-8BIT') => 'bmp',
                              (+'GIF87a').force_encoding('ASCII-8BIT') => 'gif',
                              (+'GIF89a').force_encoding('ASCII-8BIT') => 'gif' }

      if val[0..1] == "\x15\x1C" # One of those goofy Microsoft OLE containers?
        package_header_length = val[2..3].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
        # This will often be just FF FF FF FF
        # object_size = val[16..19].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
        friendly_and_class_names = val[20...package_header_length].split("\0")
        object_type_name_length = val[package_header_length + 8..package_header_length+11].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
        friendly_and_class_names << val[package_header_length + 12...package_header_length + 12 + object_type_name_length].strip
        # friendly_and_class_names will now be something like:  ['Bitmap Image', 'Paint.Picture', 'PBrush']
        real_object_size = val[package_header_length + 20 + object_type_name_length..package_header_length + 23 + object_type_name_length].bytes.reverse.inject(0) {|m, b| (m << 8) + b }
        object_start = package_header_length + 24 + object_type_name_length
        val = val[object_start...object_start + real_object_size]
      end

      if ((signature = @image_signatures.find { |k, _v| val[0...k.length] == k }&.last) ||
          (val[0..3] == 'RIFF' && val[8..11] == 'WEBP' && binding.local_variable_set(:signature, 'webp'))) &&
         val.length < max_size
        "<img src=\"data:image/#{signature.last};base64,#{Base64.encode64(val)}\">"
      else
        "&lt;&nbsp;#{signature ? "#{signature} image" : 'Binary'}, #{val.length} bytes&nbsp;>"
      end
    end

    # Generate MermaidJS markup to create a partial ERD for this model
    def erd_markup(model, prefix)
      model_short_name = model.name.split('::').last
      "<div id=\"mermaidErd\">
  <div id=\"mermaidDiagram\" class=\"mermaid\">
erDiagram
<% shown_classes = {}

   def erd_sidelinks(shown_classes, klass)
     links = []
     # %%% Not yet showing these as they can get just a bit intense!
     # klass.reflect_on_all_associations.select { |a| shown_classes.key?(a.klass) }.each do |assoc|
     #   unless shown_classes[assoc.klass].key?(klass.name)
     #     links << \"    #\{klass.name.split('::').last} #\{assoc.macro == :belongs_to ? '}o--||' : '||--o{'} #\{assoc.klass.name.split('::').last} : \\\"\\\"\"n\"
     #     shown_classes[assoc.klass][klass.name] = nil
     #   end
     # end
     # shown_classes[klass] ||= {}
     links.join
   end

   @_brick_bt_descrip&.each do |bt|
     bt_class = bt[1].first.first
     callbacks[bt_name = bt_class.name.split('::').last] = bt_class
     is_has_one = #{model.name}.reflect_on_association(bt.first)&.inverse_of&.macro == :has_one ||
                  ::Brick.config.has_ones&.fetch('#{model.name}', nil)&.key?(bt.first.to_s)
    %>  <%= \"#{model_short_name} #\{is_has_one ? '||' : '}o'}--|| #\{bt_name} : \\\"#\{
        bt_underscored = bt[1].first.first.name.underscore.singularize
        bt.first unless bt.first.to_s == bt_underscored.split('/').last # Was:  bt_underscored.tr('/', '_')
        }\\\"\".html_safe %>
<%=  erd_sidelinks(shown_classes, bt_class).html_safe %>
<% end
   last_hm = nil
   @_brick_hm_counts&.each do |hm|
     # Skip showing self-referencing HM links since they would have already been drawn while evaluating the BT side
     next if (hm_class = hm.last&.klass) == #{model.name}

     callbacks[hm_name = hm_class.name.split('::').last] = hm_class
     if (through = hm.last.options[:through]&.to_s) # has_many :through  (HMT)
       through_name = (through_assoc = hm.last.source_reflection).active_record.name.split('::').last
       callbacks[through_name] = through_assoc.active_record
       if last_hm == through # Same HM, so no need to build it again, and for clarity just put in a blank line
%><%=    \"\n\"
%><%   else
%>  <%= \"#{model_short_name} ||--o{ #\{through_name}\".html_safe %> : \"\"
<%=      erd_sidelinks(shown_classes, through_assoc.active_record).html_safe %>
<%       last_hm = through
       end
%>    <%= \"#\{through_name} }o--|| #\{hm_name}\".html_safe %> : \"\"
    <%= \"#{model_short_name} }o..o{ #\{hm_name} : \\\"#\{hm.first}\\\"\".html_safe %><%
     else # has_many
%>  <%= \"#{model_short_name} ||--o{ #\{hm_name} : \\\"#\{
            hm.first.to_s unless (last_hm = hm.first.to_s).downcase == hm_class.name.underscore.pluralize.tr('/', '_')
          }\\\"\".html_safe %><%
     end %>
<%=  erd_sidelinks(shown_classes, hm_class).html_safe %>
<% end
   def dt_lookup(dt)
     { 'integer' => 'int', }[dt] || dt&.tr(' ', '_') || 'int'
   end
   callbacks.merge({#{model_short_name.inspect} => #{model.name}}).each do |cb_k, cb_class|
     cb_relation = ::Brick.relations[cb_class.table_name]
     pkeys = cb_relation[:pkey]&.first&.last
     fkeys = cb_relation[:fks]&.values&.each_with_object([]) { |fk, s| s << fk[:fk] if fk.fetch(:is_bt, nil) }
     cols = cb_relation[:cols]
 %>  <%= cb_k %> {<%
     pkeys&.each do |pk| %>
    <%= \"#\{dt_lookup(cols[pk].first)} #\{pk} \\\"PK#\{' fk' if fkeys&.include?(pk)}\\\"\".html_safe %><%
     end %><%
     fkeys&.each do |fk|
       if fk.is_a?(Array)
         fk.each do |fk_part| %>
    <%= \"#\{dt_lookup(cols[fk_part].first)} #\{fk_part} \\\"&nbsp;&nbsp;&nbsp;&nbsp;fk\\\"\".html_safe unless pkeys&.include?(fk_part) %><%
         end
       else # %%% Does not yet accommodate polymorphic BTs
    %>
    <%= \"#\{dt_lookup(cols[fk]&.first)} #\{fk} \\\"&nbsp;&nbsp;&nbsp;&nbsp;fk\\\"\".html_safe unless pkeys&.include?(fk) %><%
       end
     end %>
  }
<% end
 # callback < %= cb_k % > erdClick
 %>
  </div>#{
 add_column = false # For the moment, disable all schema modification things
 "<%= brick_add_column(#{model.name}, #{prefix.inspect}).html_safe %>" unless add_column == false}
</div>
"
    end

    # Render text or HTML without exposing password details
    def hide_bcrypt(val, is_xml = nil, max_len = 200)
      if ::Brick::Rails.is_bcrypt?(val)
        '(hidden)'
      else
        if val.is_a?(String)
          return ::Brick::Rails.display_binary(val) unless (val_utf8 = val.dup.force_encoding('UTF-8')).valid_encoding?

          val = val_utf8.strip
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

    # Password type data?
    def is_bcrypt?(val)
      val.is_a?(String) && val.length == 60 && val.start_with?('$2a$')
    end
  end

  # CONSTANTS

  AVO_SVG = "<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 84 90\" height=\"30\" fill=\"#3096F7\">
  <path d=\"M83.8304 81.0201C83.8343 82.9343 83.2216 84.7996 82.0822 86.3423C80.9427 87.8851 79.3363 89.0244 77.4984 89.5931C75.6606 90.1618 73.6878 90.1302 71.8694 89.5027C70.0509 88.8753 68.4823 87.6851 67.3935 86.1065L67.0796 85.6029C66.9412 85.378 66.8146 85.1463 66.6998 84.9079L66.8821 85.3007C64.1347 81.223 60.419 77.8817 56.0639 75.5723C51.7087 73.263 46.8484 72.057 41.9129 72.0609C31.75 72.0609 22.372 77.6459 16.9336 85.336C17.1412 84.7518 17.7185 83.6137 17.9463 83.0446L19.1059 80.5265L19.1414 80.456C25.2533 68.3694 37.7252 59.9541 52.0555 59.9541C53.1949 59.9541 54.3241 60.0095 55.433 60.1102C60.748 60.6134 65.8887 62.2627 70.4974 64.9433C75.1061 67.6238 79.0719 71.2712 82.1188 75.6314C82.1188 75.6314 82.1441 75.6717 82.1593 75.6868C82.1808 75.717 82.1995 75.749 82.215 75.7825C82.2821 75.8717 82.3446 75.9641 82.4024 76.0595C82.4682 76.1653 82.534 76.4221 82.5999 76.5279C82.6657 76.6336 82.772 76.82 82.848 76.9711L83.1822 77.7063C83.6094 78.7595 83.8294 79.8844 83.8304 81.0201V81.0201Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path opacity=\"0.25\" d=\"M83.8303 81.015C83.8354 82.9297 83.2235 84.7956 82.0844 86.3393C80.9453 87.8829 79.339 89.0229 77.5008 89.5923C75.6627 90.1617 73.6895 90.1304 71.8706 89.5031C70.0516 88.8758 68.4826 87.6854 67.3935 86.1065L67.0796 85.6029C66.9412 85.3746 66.8146 85.1429 66.6998 84.9079L66.8821 85.3007C64.1353 81.222 60.4199 77.8797 56.0647 75.5695C51.7095 73.2593 46.8488 72.0524 41.9129 72.0558C31.75 72.0558 22.372 77.6408 16.9336 85.3309C17.1412 84.7467 17.7185 83.6086 17.9463 83.0395L19.1059 80.5214L19.1414 80.4509C22.1906 74.357 26.8837 69.2264 32.6961 65.6326C38.5086 62.0387 45.2114 60.1232 52.0555 60.1001C53.1949 60.1001 54.3241 60.1555 55.433 60.2562C60.7479 60.7594 65.8887 62.4087 70.4974 65.0893C75.1061 67.7698 79.0719 71.4172 82.1188 75.7775C82.1188 75.7775 82.1441 75.8177 82.1593 75.8328C82.1808 75.863 82.1995 75.895 82.215 75.9285C82.2821 76.0177 82.3446 76.1101 82.4024 76.2055L82.5999 76.5228C82.6859 76.6638 82.772 76.8149 82.848 76.966L83.1822 77.7012C83.6093 78.7544 83.8294 79.8793 83.8303 81.015Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path d=\"M42.1155 30.2056L35.3453 45.0218C35.2161 45.302 35.0189 45.5458 34.7714 45.7313C34.5239 45.9168 34.2338 46.0382 33.9274 46.0844C27.3926 47.1694 21.1567 49.5963 15.617 53.2105C15.279 53.4302 14.8783 53.5347 14.4753 53.5083C14.0723 53.4819 13.6889 53.326 13.3827 53.0641C13.0765 52.8022 12.8642 52.4485 12.7777 52.0562C12.6911 51.6638 12.7351 51.2542 12.9029 50.8889L32.2311 8.55046L33.6894 5.35254C32.8713 7.50748 32.9166 9.89263 33.816 12.0153L33.9983 12.4131L42.1155 30.2056Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path d=\"M82.812 76.8753C82.6905 76.694 82.3715 76.2207 82.2449 76.0444C82.2044 75.9739 82.2044 75.8782 82.1588 75.8127C82.1132 75.7473 82.1335 75.7724 82.1183 75.7573C79.0714 71.3971 75.1056 67.7497 70.4969 65.0692C65.8882 62.3886 60.7474 60.7393 55.4325 60.2361C54.3236 60.1354 53.1943 60.08 52.055 60.08C45.2173 60.1051 38.5214 62.022 32.7166 65.6161C26.9118 69.2102 22.2271 74.3397 19.1864 80.4308L19.151 80.5013C18.7358 81.3323 18.3458 82.1784 17.9914 83.0194L16.9786 85.2655C16.9077 85.3662 16.8419 85.472 16.771 85.5828C16.6647 85.7389 16.5584 85.9 16.4621 86.0612C15.3778 87.6439 13.8123 88.8397 11.995 89.4732C10.1776 90.1068 8.20406 90.1448 6.36344 89.5817C4.52281 89.0186 2.9119 87.884 1.76676 86.3442C0.621625 84.8044 0.00246102 82.9403 0 81.0251C0.00604053 80.0402 0.177178 79.0632 0.506372 78.1344L1.22036 76.5681C1.25084 76.5034 1.28639 76.4411 1.32669 76.3818C1.40265 76.2559 1.47861 76.135 1.56469 76.0192C1.58531 75.9789 1.60901 75.9401 1.63558 75.9034C7.06401 67.6054 14.947 61.1866 24.1977 57.5317C33.4485 53.8768 43.6114 53.166 53.2855 55.4971L48.9155 45.9286L41.9276 30.6188L33.8256 12.8263L33.6433 12.4285C32.7439 10.3058 32.6986 7.92067 33.5167 5.76573L34.0231 4.69304C34.8148 3.24136 35.9941 2.03525 37.431 1.20762C38.868 0.379997 40.5068 -0.0370045 42.1668 0.0025773C43.8268 0.0421591 45.4436 0.536787 46.839 1.43195C48.2345 2.32711 49.3543 3.58804 50.0751 5.07578L50.2523 5.47363L51.8474 8.96365L74.0974 57.708L82.812 76.8753Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
  <path opacity=\"0.25\" d=\"M41.9129 30.649L35.3301 45.0422C35.2023 45.3204 35.0074 45.563 34.7627 45.7484C34.518 45.9337 34.2311 46.0562 33.9274 46.1048C27.3926 47.1897 21.1567 49.6166 15.617 53.2308C15.279 53.4505 14.8783 53.555 14.4753 53.5286C14.0723 53.5022 13.6889 53.3463 13.3827 53.0844C13.0765 52.8225 12.8642 52.4688 12.7777 52.0765C12.6911 51.6842 12.7351 51.2745 12.9029 50.9092L32.0285 8.99382L33.4869 5.7959C32.6687 7.95084 32.7141 10.336 33.6135 12.4586L33.7958 12.8565L41.9129 30.649Z\" fill=\"currentColor\" fill-opacity=\"0.22\"></path>
</svg>
"

  AA_PNG = "<img src=\"data:image/png;base64,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\">
"

  IN_APP = "<svg height=\"36px\" viewBox=\"0 0 214 274\" xmlns=\"http://www.w3.org/2000/svg\">
    <g transform=\"matrix(4.16667,0,0,4.16667,-1049.47,-789.371)\">
      <path d=\"M281.386,193.134L287.086,193.134C287.433,193.134 287.716,193.417 287.716,193.764C287.716,194.11 287.433,194.394 287.086,194.394L281.386,194.394C281.04,194.394 280.756,194.11 280.756,193.764C280.756,193.417 281.04,193.134 281.386,193.134ZM284.252,245.638C282.456,245.638 281.008,247.086 281.008,248.851C281.008,250.645 282.456,252.094 284.252,252.094C286.047,252.094 287.496,250.645 287.496,248.851C287.496,247.086 286.047,245.638 284.252,245.638ZM284.252,246.331C282.835,246.331 281.701,247.465 281.701,248.851C281.701,250.268 282.835,251.401 284.252,251.401C285.638,251.401 286.803,250.268 286.803,248.851C286.803,247.465 285.638,246.331 284.252,246.331ZM275.843,208.63L287.559,218.11L275.843,227.622L275.843,221.858L251.874,221.858L251.874,214.394L275.843,214.394L275.843,208.63ZM278.866,239.906L278.866,233.102C278.866,232.851 278.677,232.693 278.456,232.693L271.622,232.693C271.401,232.693 271.212,232.851 271.212,233.102L271.212,239.906C271.212,240.157 271.401,240.314 271.622,240.314L278.456,240.314C278.677,240.314 278.866,240.157 278.866,239.906ZM280.41,233.102L280.41,239.906C280.41,240.157 280.599,240.314 280.819,240.314L287.653,240.314C287.874,240.314 288.063,240.157 288.063,239.906L288.063,233.102C288.063,232.851 287.874,232.693 287.653,232.693L280.819,232.693C280.599,232.693 280.41,232.851 280.41,233.102ZM289.606,233.102L289.606,239.906C289.606,240.157 289.795,240.314 290.047,240.314L296.851,240.314C297.071,240.314 297.26,240.157 297.26,239.906L297.26,233.102C297.26,232.851 297.071,232.693 296.851,232.693L290.047,232.693C289.795,232.693 289.606,232.851 289.606,233.102ZM269.197,189.449L299.276,189.449C301.354,189.449 303.055,191.149 303.055,193.197L303.055,251.275C303.055,253.355 301.354,255.055 299.276,255.055L269.197,255.055C267.118,255.055 265.449,253.355 265.449,251.275L265.449,223.496L267.842,223.496L267.842,242.488L300.63,242.488L300.63,198.394L267.842,198.394L267.842,212.725L265.449,212.725L265.449,193.197C265.449,191.149 267.118,189.449 269.197,189.449Z\" style=\"fill:rgb(31,147,209);\"/>
    </g>
</svg>"
end
