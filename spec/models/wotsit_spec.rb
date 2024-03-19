# frozen_string_literal: true

# This example shows has_one and has_many working together

require 'spec_helper'
require 'csv'

# Examples
# ========

RSpec.describe 'Wotsit', type: :model do
  before(:each) do
    ::Widget.destroy_all
  end

  it 'should be able to import from CSV data' do
    csv_in = <<~CSV
      Name,Widget Name,Widget A Text,Widget An Integer,Widget A Float,Widget A Decimal,Widget A Datetime,Widget A Time,Widget A Date,Widget A Boolean,Widget Fluxors Name
      Mr. Wotsit,Squidget Widget,Widge Text,42,0.7734,847.63,2020-04-01 23:59,04:20:00 AM,2020-12-02,T,Flux Capacitor
      Mr. Budgit,Budget Widget,Budge Text,100,7.734,243.26,2019-04-01 23:59,16:20:00 PM,2019-12-02,F,Flex Resistor
      Mr. Fixit,Budget Widget,Budge Text,100,7.734,243.26,2019-04-01 23:59,16:20:00 PM,2019-12-02,F,Flex Resistor
      Mr. Budgit,Budget Widget,Budge Text,420,7.734,243.26,2019-04-01 23:59,16:20:00 PM,2019-12-02,F,Nix Resistor
    CSV
    child_info_csv = CSV.new(csv_in)

    # Import CSV data
    # ---------------
    expect { Wotsit.df_import(child_info_csv) }.not_to raise_error

    expect([Wotsit.count, Widget.count, Fluxor.count]).to eq([3, 2, 3])

    widgets = Widget.order(:id).pluck(:name, :a_text, :an_integer, :a_float, :a_decimal, :a_datetime, :a_time, :a_date, :a_boolean)

    # Take out just the time column and test it
    expect(widgets.map do |w|
      t = w.slice!(6)
      [t.hour, t.min]
    end).to eq([[4, 20], [16, 20]])

    # Now test all the rest
    expect(widgets).to eq(
      [
        ['Squidget Widget', 'Widge Text', 42, 0.7734, BigDecimal(847.63, 5),
         DateTime.new(2020, 4, 1, 23, 59).in_time_zone - widgets.first[5].utc_offset.seconds,
         Date.new(2020, 12, 2), true],
        ['Budget Widget', 'Budge Text', 420, 7.734, BigDecimal(243.26, 5),
         DateTime.new(2019, 4, 1, 23, 59).in_time_zone - widgets.first[5].utc_offset.seconds,
         Date.new(2019, 12, 2), false]
      ]
    )

    widg_flux = Widget.joins(:fluxors)
                      .order('widgets.id', 'fluxors.id')
                      .pluck('widgets.name', Arel.sql('fluxors.name AS name2'))
    wots_widg = Wotsit.joins(:widget)
                      .order('wotsits.id', 'widgets.id')
                      .pluck('wotsits.name', Arel.sql('widgets.name AS name2'))

    expect(widg_flux).to eq([['Squidget Widget', 'Flux Capacitor'],
                             ['Budget Widget', 'Flex Resistor'],
                             ['Budget Widget', 'Nix Resistor']])
    expect(wots_widg).to eq([['Mr. Wotsit', 'Squidget Widget'],
                             ['Mr. Budgit', 'Budget Widget'],
                             ['Mr. Fixit', 'Budget Widget']])
  end
end
