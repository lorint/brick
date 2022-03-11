# frozen_string_literal: true

require 'spec_helper'
require 'csv'

# Two without IMPORT_TEMPLATEs
# Examples
# ========

RSpec.describe 'Parent', type: :model do
  # Set up Models
  # =============
  before(:all) do
    unload_class('Parent')
    class Parent < ActiveRecord::Base
      if ActiveRecord.version >= ::Gem::Version.new('4.2')
        has_many :children, dependent: :destroy
      else
        # Rails before 4.2 didn't automatically create inverse_of entries on associations,
        # so we'll need to do that dirty work ourselves
        has_many :children, inverse_of: :parent, dependent: :destroy
      end

      def self.import(file)
        df_import(file)
      end
    end

    unload_class('Child')
    class Child < ActiveRecord::Base
      if ActiveRecord.version >= ::Gem::Version.new('4.2')
        belongs_to :parent
      else
        # Rails before 4.2 didn't automatically create inverse_of entries on associations,
        # so we'll need to do that dirty work ourselves
        belongs_to :parent, inverse_of: :children
      end
    end
  end

  before(:each) do
    Parent.destroy_all
  end

  context 'with valid attributes' do
    it 'should be able to suggest a template that relates Parent and Child' do
      # Default template has only Parent information
      # This is as if you had simply run:  Parent.suggest_template
      template = Parent.suggest_template(false, true, 0, false, false)
      # All columns includes the three string columns in the parents table
      expect(template[:all]).to eq(
        [:firstname, :lastname, :address, :address_line_2, :city, :province, :postal_code,
         :telephone_number, :email, :admin_notes, :gross_income, :created_by_admin, :status]
      )
      # Uniques finds the first available string column
      expect(template[:uniques]).to eq([:firstname])

      # ----------------------------------------------------
      # Now including tables directly linked by any has_many
      template_has_many_children = Parent.suggest_template(true, true, 0, false, false)
      # All columns should include the three string columns in the parents table,
      # plus the first column in children
      expect(template_has_many_children[:all]).to eq(
        [:firstname, :lastname, :address, :address_line_2, :city, :province, :postal_code,
         :telephone_number, :email, :admin_notes, :gross_income, :created_by_admin, :status,
          { children: [:firstname] }]
      )
      # # Uniques should now also include the first available string column in the children table
      # expect(template_has_many_children[:uniques]).to eq ([:firstname, :children_firstname])

      # Using this template should generate column headers
      column_headers = Parent.df_export(false, template_has_many_children).first
      expect(column_headers).to eq(['Firstname', 'Lastname',
        'Address', 'Address Line 2', 'City', 'Province', 'Postal Code',
        'Telephone Number', 'Email', 'Admin Notes', 'Gross Income', 'Created By Admin', 'Status',
        'Children Firstname'])

      # ------------------------------------------------------------------------------
      # Now including one full hop away of tables, and directly linked by any has_many
      template_with_children = Parent.suggest_template(true, true, 1, false, false)
      # All columns should include the three string columns in the parents table,
      # plus the first column in children
      expect(template_with_children[:all]).to eq(
        [:firstname, :lastname, :address, :address_line_2, :city, :province, :postal_code,
         :telephone_number, :email, :admin_notes, :gross_income, :created_by_admin, :status,
          { children: [:firstname, :lastname, :dateofbirth, :gender] }]
      )
      # # Uniques should still include the first available string column in the children table
      # expect(template_with_children[:uniques]).to eq ([:firstname, :children_firstname])

      # Using this template should generate column headers
      column_headers = Parent.df_export(false, template_with_children).first
      expect(column_headers).to eq(
        ['Firstname', 'Lastname',
          'Address', 'Address Line 2', 'City', 'Province', 'Postal Code',
          'Telephone Number', 'Email', 'Admin Notes', 'Gross Income', 'Created By Admin', 'Status',
          'Children Firstname', 'Children Lastname', 'Children Dateofbirth', 'Children Gender']
      )
      # Adding aliases to the template using :as allows for six custom column headings to work
      template_with_children[:as] = {
        'parent_1_firstname' => 'Firstname',
        'parent_1_lastname' => 'Lastname',
        'address' => 'Address',
        'childfirstname' => 'Children Firstname',
        'childlastname' => 'Children Lastname',
        'childdateofbirth' => 'Children Dateofbirth'
      }
      column_headers = Parent.df_export(false, template_with_children).first
      expect(column_headers).to eq(
        ['parent_1_firstname', 'parent_1_lastname', 'address',
         # Although Address Line 2 wasn't specified in the :as list, because it begins with something
         # that was in the list -- Address -- then its first part gets changed out, so this changed the
         # first word here from Address down to address.  If you wanted it to have a different custom
         # name then an entry must be placed BEFORE the more generic "Address" entry that changed it.
         'address Line 2',
         'City', 'Province', 'Postal Code', 'Telephone Number', 'Email', 'Admin Notes', 'Gross Income', 'Created By Admin', 'Status',
         'childfirstname', 'childlastname', 'childdateofbirth',
         # Children Gender wasn't specified in the :as list, so it retains its titleized naming
         'Children Gender']
      )
    end

    it 'should be able to import from an array' do
      child_info = [
        ['Firstname', 'Lastname', 'Address', 'Children Firstname', 'Children Lastname', 'Children Dateofbirth'],
        ['Homer', 'Simpson', '742 Evergreen Terrace', 'Bart', 'Simpson', '2002-11-11'],
        ['Homer', 'Simpson', '742 Evergreen Terrace', 'Lisa', 'Simpson', '2006-10-01'],
        ['Marge', 'Simpson', '742 Evergreen Terrace', 'Bart', 'Simpson', '2002-11-11'],
        ['Marge', 'Simpson', '742 Evergreen Terrace', 'Lisa', 'Simpson', '2006-10-01'],
        ['Clancey', 'Wiggum', '732 Evergreen Terrace', 'Ralph', 'Wiggum', '2005-04-01']
      ]

      # Perform the import on CSV data
      # Get the suggested default import template for the Parent model
      template_with_children = Parent.suggest_template(true, true, 1, false, false)
      # Initially we only force uniqueness on the first string column of Parent
      expect(template_with_children[:uniques]).to eq([:firstname])
      # Add in uniqueness for the Child portion of each incoming row.  (Without this then
      # the import would end up with three children stored instead of five -- one for each
      # of the parents -- and in both cases Bart would be updated with Lisa, so there
      # would be two Lisa entries and no Bart entries.)
      # Note that the prefix "children_" comes from the name of the has_many association
      # found in the Parent model.
      template_with_children[:uniques] << :children_firstname

      # Do the import
      expect { Parent.df_import(child_info, template_with_children) }.not_to raise_error

      parents = Parent.order(:id).pluck(:firstname, :lastname, :address)
      expect(parents.count).to eq(3)
      expect(parents).to eq(
        [
          ['Homer', 'Simpson', '742 Evergreen Terrace'],
          ['Marge', 'Simpson', '742 Evergreen Terrace'],
          ['Clancey', 'Wiggum', '732 Evergreen Terrace']
        ]
      )

      parent_ids = Parent.order(:id).pluck(:id)
      children = Child.order(:id).pluck(:firstname, :lastname, :dateofbirth, :parent_id)
      expect(children.count).to eq(5)
      expect(children).to eq(
        [
          ['Bart', 'Simpson', Date.new(2002, 11, 11), parent_ids.first], # Homer
          ['Lisa', 'Simpson', Date.new(2006, 10, 1), parent_ids.first], # Homer
          ['Bart', 'Simpson', Date.new(2002, 11, 11), parent_ids.second], # Marge
          ['Lisa', 'Simpson', Date.new(2006, 10, 1), parent_ids.second], # Marge
          ['Ralph', 'Wiggum', Date.new(2005, 4, 1), parent_ids.third] # Clancey
        ]
      )
      # As an aside -- if you feel that seeing these four entries is inappropriate repetition
      # then consider that having only this one to many relationship means that for two parents
      # that have the same children, being as each Child object has just one foreign key then
      # it is impossible to have them relate to multiple parents.  If you want to be able to
      # properly represent Bart and Lisa just once each then what's really appropriate here is
      # a different data structure, a many to many relationship that uses 3 tables.  This setup
      # would have a central associative table in the middle that belongs to both Parent and
      # Child, like this:
      #
      # .    Parent --> ChildParent <-- Child
      #
      # To see an example import with this many-to-many setup in action, check out
      # recipe_spec.rb.
    end

    it 'should be able to update a foreign key during import' do
      child_info = [
        ['Firstname', 'Lastname', 'Dateofbirth', 'Parent Firstname', 'Parent Lastname', 'Parent Address'],
        ['Bart', 'Simpson', '2002-11-11', 'Homer', 'Simpson', '742 Evergreen Terrace'],
        ['Lisa', 'Simpson', '2002-11-11', 'Marge', 'Simpson', '742 Evergreen Terrace'],
        # For Ralph, at first we associate the incorrect parent
        ['Ralph', 'Wiggum', '2005-04-01', 'Homer', 'Simpson', '742 Evergreen Terrace'],
        # And then we get it right later with this updated row, which updates the foreign key
        ['Ralph', "NOT IN UNIQUE SO DOESN'T MATTER", '9999-01-01', 'Clancey', 'Wiggum', '732 Evergreen Terrace']
      ]

      # Perform the import on CSV data
      # Get the suggested default import template for the Parent model
      template_with_parents = Child.suggest_template(false, true, 1, false, false)
      # Initially we only force uniqueness on the first string column of Child
      expect(template_with_parents[:uniques]).to eq([:firstname])
      # Add in uniqueness for the Parent portion of each incoming row.
      template_with_parents[:uniques] << :parent_firstname

      # Do the import
      expect { Child.df_import(child_info, template_with_parents) }.not_to raise_error

      parents = Parent.order(:id).pluck(:firstname)
      expect(parents).to eq(%w[Homer Marge Clancey])

      parent_ids = Parent.order(:id).pluck(:id)
      children = Child.order(:id).pluck(:firstname, :lastname, :dateofbirth, :parent_id)
      expect(children.count).to eq(3)
      expect(children).to eq(
        [
          ['Bart', 'Simpson', Date.new(2002, 11, 11), parent_ids.first], # Homer
          ['Lisa', 'Simpson', Date.new(2002, 11, 11), parent_ids.second], # Marge
          ['Ralph', "NOT IN UNIQUE SO DOESN'T MATTER", Date.new(9999, 1, 1), parent_ids.third] # Clancey
        ]
      )
    end

    it 'should be able to import from CSV data' do
      # Set the import template for the Parent model to a suggested default
      # Parent::IMPORT_TEMPLATE = Parent.suggest_template(1, true, false)

      # Firstname,Lastname,Address,Children Firstname,Children Lastname,Children Dateofbirth
      child_info_csv = CSV.new(
        <<~CSV
          parent_1_firstname,parent_1_lastname,address,address_line_2,city,province,postal_code,telephone_number,email,admin_notes,gross_income, created_by_admin ,status,firstname,lastname,dateofbirth,gender
          Nav,Deo,College Road,,Alliston,BC,N4c 6u9,500 000 0000,nav@prw.com,"HAPPY",13917, TRUE , Approved ,Sami,Kidane,2009-10-10,Male
        CSV
      )

      # Perform the import on CSV data, overriding the default generated template
      expect do
        Parent.df_import(
          child_info_csv,
          {
            uniques: [:firstname, :children_firstname],
            required: [],
            all: [:firstname, :lastname, :address, :address_line_2, :city, :province, :postal_code,
                  :telephone_number, :email, :admin_notes, :gross_income, :created_by_admin, :status,
              { children: [:firstname, :lastname, :dateofbirth, :gender] }],
            # An alias for each incoming column
            as: {
                  'parent_1_firstname' => 'Firstname',
                  'parent_1_lastname' => 'Lastname',
                  'address' => 'Address',
                  'address_line_2' => 'Address Line 2',
                  'city' => 'City',
                  'province' => 'Province',
                  'postal_code' => 'Postal Code',
                  'telephone_number' => 'Telephone Number',
                  'email' => 'Email',
                  'admin_notes' => 'Admin Notes',
                  'gross_income' => 'Gross Income',
                  'created_by_admin' => 'Created By Admin',
                  'status' => 'Status',

                  'firstname' => 'Children Firstname',
                  'lastname' => 'Children Lastname',
                  'dateofbirth' => 'Children Dateofbirth',
                  'gender' => 'Children Gender'
                }
          }.freeze
        )
      end.not_to raise_error

      parents = Parent.order(:id)
                      .pluck(:firstname, :lastname, :address, :address_line_2, :city, :province, :postal_code,
                             :telephone_number, :email, :admin_notes, :gross_income, :created_by_admin, :status)
      expect(parents.count).to eq(1)
      expect(parents).to eq([['Nav', 'Deo',
        'College Road', nil, 'Alliston', 'BC', 'N4c 6u9',
        '500 000 0000', 'nav@prw.com', 'HAPPY', 13_917, true, ' Approved ']])

      children = Child.order(:id).pluck(:firstname, :lastname, :dateofbirth, :gender)
      expect(children.count).to eq(1)
      expect(children).to eq([['Sami', 'Kidane', Date.new(2009, 10, 10), 'Male']])
    end
  end
end
