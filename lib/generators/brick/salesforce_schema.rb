# frozen_string_literal: true

module Brick
  class SalesforceSchema < Nokogiri::XML::SAX::Document
    include ::Brick::MigrationsBuilder

    attr_reader :end_document_proc

    def initialize(end_doc_proc)
      @end_document_proc = end_doc_proc
    end

    def start_document
      # p [:start_document]
      @salesforce_tables = {}
      @text_stack = []
      @all_extends = {}
      puts 'Each dot is a table:'
    end

    def end_document
      puts
      end_document_proc&.call(@salesforce_tables)
    end

    def start_element_namespace(name, attrs = [], prefix = nil, uri = nil, ns = [])
      # p [:start_element, name, attrs, prefix, uri, ns]
      case name
      when 'complexType' # Table
        @last_table = attrs.find { |a| a.localname == 'name' }&.value
        @fks = {}
        # if attrs.first&.value&.end_with?('__c') # Starts as a string
      when 'extension'
        @last_extension = attrs.find { |a| a.localname == 'base' }.value
      when 'element' # Column
        # Extremely rarely this is nil!
        data_type = attrs.find { |a| a.localname == 'type' }&.value
        return if !@last_table || data_type.nil? || data_type == 'tns:QueryResult'

        # Promoted to a real SalesforceTable object
        if @last_table.is_a?(String)
          @last_table = @salesforce_tables[@last_table] = { extend: @salesforce_tables[@last_extension] }
        end

        col_name = attrs.find { |a| a.localname == 'name' }&.value

        # Foreign key reference?
        if data_type&.start_with?('ens:')
          foreign_table = data_type[4..]
          if col_name.end_with?('__r')
            @fks["#{col_name[0..-2]}c"] = foreign_table
          else # if col_name.end_with?('Id')
            @fks["#{col_name}Id"] = foreign_table
          end
          return
        end

        # Rarely this is nil
        nillable = attrs.find { |a| a.localname == 'nillable' }&.value == 'true'
        min_occurs = attrs.find { |a| a.localname == 'minOccurs' }&.value || -2
        min_occurs = -1 if min_occurs == 'unbounded'
        max_occurs = attrs.find { |a| a.localname == 'maxOccurs' }&.value || -2
        max_occurs = -1 if max_occurs == 'unbounded'
        col_options = { name: col_name, data_type: :data_type, nillable: :nillable, min_occurs: :min_occurs, max_occurs: :max_occurs }

        (@last_table[:cols] ||= []) << col_options
      end
      @text_stack.push +''
    end

    def end_element_namespace(name, prefix = nil, uri = nil)
      # p [:end_element, name, prefix, uri]
      texts = @text_stack.pop
      case name
      when 'extension'
        @last_extension = nil
      when 'complexType'
        if @last_table && !@last_table.is_a?(String)
          # Do up any foreign keys
          @fks.each do |k, v|
            # Only a few records set up like this, going to sObject
            if 
              # (k.downcase.end_with?('recordid') &&
              #   (fk_col = @last_table[:cols].find { |t| t[:name] == "#{k[0..-9]}Id" })
              #  ) ||
               (fk_col = @last_table[:cols].find { |t| t[:name] == k })
              fk_col[:fk_reference_to] = v
              # puts "Skipping #{@last_table[:name]} / #{k}"
            end
          end
        end
        print '.'
        @last_table = nil
      end
      # p [:end_element_texts, name, texts]
    end

    def characters(string)
      # p [:characters, string]
      @text_stack.each do |text|
        text << string
      end
    end
  end
end
