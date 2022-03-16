# frozen_string_literal: true

require 'spec_helper'
require 'csv'

# Two without IMPORT_TEMPLATEs
# Examples
# ========

RSpec.describe 'Parent', type: :model do
  before(:each) do
    Parent.destroy_all
  end

  context 'with valid attributes' do
    it 'should auto-create models that relate Parent and Child' do
      parent_children = Parent.reflect_on_association(:children)
      expect(parent_children.macro).to eq(:has_many)
      expect(parent_children.klass).to eq(Child)

      child_parent = Child.reflect_on_association(:parent)
      expect(child_parent.macro).to eq(:belongs_to)
      expect(child_parent.klass).to eq(Parent)
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
