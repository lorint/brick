# frozen_string_literal: true

require 'spec_helper'
require 'brick/join_array'

module Brick
  ::RSpec.describe ::Brick::JoinArray do
    it 'should add just a symbol when only one value is requested' do
      employee_joins = JoinArray.new
      employee_joins[:orders] = nil
      expect(employee_joins).to eq([:orders])
    end

    it 'should upgrade a lone symbol into being a hash when an additional nested value is requested' do
      employee_joins = JoinArray.new
      employee_joins[:orders] = nil
      expect(employee_joins).to eq([:orders])
      employee_joins[:orders] = :order_details
      expect(employee_joins).to eq([{ orders: [:order_details] }])
    end

    it 'should create a nested set of hashes when assigning multiple layers at once' do
      employee_joins = JoinArray.new
      employee_joins[:orders][:order_details][:product] = :category
      expect(employee_joins).to eq(
        [{ orders: { order_details: { product: [:category] } } }]
      )
    end

    it 'should create the nested set of hashes when setting the final member to nil' do
      employee_joins = JoinArray.new
      employee_joins[:orders][:order_details][:product][:category] = nil
      expect(employee_joins).to eq(
        [{ orders: { order_details: { product: [:category] } } }]
      )
    end

    it 'should create an empty JoinHash pointing to a parent hash when referencing layers' do
      employee_joins = JoinArray.new
      nested_reference = employee_joins[:orders][:order_details][:product]
      # At first the nested reference is a loose object
      expect(employee_joins).to eq([])
      expect(nested_reference).to eq({})
      # The loose nested_reference JoinHash knows about its ancestry through "parent", and from that parent its
      # grandparent, and finally to the great-grandparent which is the original employee_joins object
      expect(nested_reference.parent_key).to eq(:product)
      expect(nested_reference.parent.parent_key).to eq(:order_details)
      expect(nested_reference.parent.parent.parent_key).to eq(:orders)
      expect(nested_reference.parent.parent.parent).to be(employee_joins) # Back to the JoinArray where we started this from

      # Using []= on that final leaf layer should "hydrate" the whole linked set into existence
      nested_reference[:category] = nil
      expect(employee_joins).to eq(
        [{ orders: { order_details: { product: [:category] } } }]
      )
    end

    it 'should not create duplicates when nodes are set multiple times' do
      employee_joins = JoinArray.new
      employee_joins[:orders][:order_details][:product] = :category
      # A couple ways to set it exactly the same
      employee_joins[:orders][:order_details][:product] = :category
      employee_joins[:orders][:order_details][:product][:category] = nil
      # Still just one set in total
      expect(employee_joins).to eq(
        [{ orders: { order_details: { product: [:category] } } }]
      )
    end

    it 'should add new members to an array in the leaf node when the last member is set to different values' do
      category_joins = JoinArray.new
      category_joins[:products][:order_details][:order] = :employee
      category_joins[:products][:order_details][:order] = :customer
      expect(category_joins).to eq(
        [{ products: { order_details: { order: [:employee, :customer] } } }]
      )
    end

    it 'should "graduate" a middle node into being part of an array when two different branches of JOINs are referenced' do
      category_joins = JoinArray.new
      # Start with a simple nested set
      category_joins[:products][:order_details][:order] = :employee
      expect(category_joins).to eq(
        [{ products: { order_details: { order: [:employee] } } }]
      )

      # This wedges in an additional array so that the loose symbol :discount gets included
      category_joins[:products][:order_details][:discount] = nil
      expect(category_joins).to eq(
        [{ products: { order_details: [{ order: [:employee] }, :discount] } }]
      )

      # An alternate way to wedge in an additional array -- here the loose symbol :shipper gets included in a new array
      # built out under :products
      category_joins[:products] = :shipper
      expect(category_joins).to eq(
        [{ products: [{ order_details: [{ order: [:employee] }, :discount] }, :shipper] }]
      )
    end
  end
end
