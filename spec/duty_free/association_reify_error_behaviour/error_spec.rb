# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Brick do
  it 'baseline test setup' do
    # expect(Person.new).to be_versioned
  end

  describe '#association reify error behaviour' do
    it 'association reify error behaviour = :error' do
      # ::Brick.config.association_reify_error_behaviour = :error

      person = Person.create(name: 'Frank')
      car = Car.create(name: 'BMW 325')
      bicycle = Bicycle.create(name: 'BMX 1.0')

      person.car = car
      person.bicycle = bicycle
      person.update2(name: 'Steve')

      car.update2(name: 'BMW 330')
      bicycle.update2(name: 'BMX 2.0')
      person.update2(name: 'Peter')
    end
  end
end
