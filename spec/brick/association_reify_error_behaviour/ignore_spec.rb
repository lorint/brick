# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Brick do
  it 'baseline test setup' do
  end

  describe '#association reify error behaviour' do
    it 'association reify error behaviour = :ignore' do
      person = Person.create(name: 'Frank')
      thing = Thing.create(name: 'BMW 325')
      thing2 = Thing.create(name: 'BMX 1.0')

      person.thing = thing
      person.thing_2 = thing2
      person.update2(name: 'Steve')

      thing.update2(name: 'BMW 330')
      thing.update2(name: 'BMX 2.0')
      person.update2(name: 'Peter')
    end
  end
end
