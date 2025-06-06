# frozen_string_literal: true

# This example is based on this question:
# https://stackoverflow.com/questions/25990136/importing-csv-file-on-ruby-on-rails

require 'spec_helper'
require 'csv'

# This example demonstrates functionality available by using the delayed object
# save approach first established in DF 1.0.6.  In this example, each incoming
# row first builds a restaurant with its name and address using the first two
# columns of data.  Not saving Restaurant yet, it is placed it in the
# to_be_saved array.  Then still on the same row and starting with the third
# column it builds a subcategory and also places it at the end of the
# to_be_saved array.  Still with nothing yet saved, finally a category is built,
# and at that point the set of all three objects is saved in reverse order by
# popping off the array -- category, then subcategory so its forign key can
# relate to category, and finally the restaurant with its foreign key that
# references the subcategory.

# (Note that category and subcategory are both held by RestaurantCategory, and
# establish their hierarchy through a self-join.  In this way it allows n number
# of layers of categories and subcategories to exist, even though this sample
# only demonstrates the use of two layers.)

# Examples
# ========

RSpec.describe 'Restaurant', type: :model do
  before(:all) do
    # Set up Models
    # =============
    unload_class('RestaurantCategory')
    class RestaurantCategory < ActiveRecord::Base
      if ActiveRecord.version >= Gem::Version.new('5.0')
        belongs_to :parent, class_name: name, optional: true
      else
        belongs_to :parent, class_name: name
      end
      has_many :subcategories, class_name: name, foreign_key: :parent_id, dependent: :destroy
      has_many :restaurants, foreign_key: :category_id, inverse_of: :category
    end

    unload_class('Restaurant')
    class Restaurant < ActiveRecord::Base
      belongs_to :category, class_name: 'RestaurantCategory', foreign_key: :category_id, inverse_of: :restaurants

      # Generated by first running:  Restaurant.suggest_template(2, false, true)
      # And then just added :address, :category_name and :category_parent_name to the uniques,
      # and the two column aliases in the :as portion.
      IMPORT_TEMPLATE = {
        uniques: [:name, :address, :category_name, :category_parent_name],
        required: [],
        all: [:name, :address,
          { category: [:name,
            { parent: [:name] }] }],
        # An alias for incoming columns
        as: {
              'Subcategory' => 'Category Name',
              'Category' => 'Category Parent Name'
            }
      }.freeze
    end
  end

  before(:each) do
    Restaurant.destroy_all
    RestaurantCategory.destroy_all
  end

  it 'should be able to import from CSV data' do
    csv_in = <<~CSV
      Name,Address,Subcategory,Category
      Gajeongsik Bakban,"1555-6, Seocho-dong, Seocho-gu, Seoul (서울특별시 서초구 서초대로46길 19-7)",Bakban,Korean
      Sakunja,"17-1 jalan 26a-70a prismaville desa sri hartamas 50480 Kuala Lumpur, Malaysia",Bakban,Korean
      Kalbi Korean BBQ & Sushi,"36 Rosebery Avenue, London EC1R 5HP England",Galbi,Korean
      Gombawie,"151-4, Samseong-dong, Gangnam-gu, Seoul South Korea",Gopchang,Korean
      Samsung Wonjo Yang Gobchang (삼성원조양곱창),"133-6, Cheongdam-dong, Gangnam-gu, Seoul (서울특별시 강남구 청담동 133-6)",Gopchang,Korean
      Hamji Gopchang (함지곱창),"144-5, Nonhyeon-dong, Gangnam-gu, Seoul (서울특별시 강남구 학동로2길 33)",Gopchang,Korean
      Kkott Dolge Jang 1 Beonga,"210-2, Bongsan-dong, Yeosu-si, Jeollanam-do",Hanjeongsik,Korean
      Chaegeundam,"983, Daechi-dong, Gangnam-gu, Seoul",Hanjeongsik,Korean
      Sun Ha Jang,"4032 W Olympic Blvd, Los Angeles, CA 90019",Haejang,Korean
      Sarangchae Korean Restaurant,"278-280 Huntingdon Street, Nottingham NG1 3NA England",Dolsot,Korean
      Gimnejip,"322-38, Sinjang-dong, Pyeongtaek-si, Gyeonggi-do",Budae-jjigae,Korean
      Daewoo Budaejjigae,"641-18, Yeoksam-dong, Gangnam-gu, Seoul",Budae-jjigae,Korean
      Jang Choong Dong Wong Jokbal,"425 S Western Ave. Los Angeles, CA 90020",Jokbal,Korean
      Uchon Dolsot Seolleongtang,"24, Eulji-ro 12-gil, Jung-gu, Seoul 04550",Seolleongtang,Korean
      GAAE Ssambab,"No. 6, Lane 40, Section 2, Zhongcheng Road, Shilin District, Taipei City (台北市士林區忠誠路二段40巷6號)",Ssambab,Chinese
      Tofu Tofu,"96 Bowery, New York, NY 10013",Dubu,Chinese
      Shanghai Hong Kong Noodle Shop,"29 Jardine's Bazaar, Causeway Bay, Hong Kong",Cífàntuán,Chinese
      Madang,"Gneisenaustr. 8, 10961 Berlin Germany",Pajeon,Chinese
      FOMO Pancake,"No.333 Huaihai Middle Road Xintiandi Plaza B2-17, Shanghai 200000 China",Pajeon,Chinese
    CSV
    restaurant_info_csv = CSV.new(csv_in)

    # Import CSV data
    # ---------------
    expect { Restaurant.df_import(restaurant_info_csv) }.not_to raise_error

    expect(Restaurant.count).to eq(19)
    expect(Restaurant.joins(:category).order('restaurants.id').pluck('restaurants.address', 'restaurant_categories.name')).to eq(
      [
        ['1555-6, Seocho-dong, Seocho-gu, Seoul (서울특별시 서초구 서초대로46길 19-7)', 'Bakban'],
        ['17-1 jalan 26a-70a prismaville desa sri hartamas 50480 Kuala Lumpur, Malaysia', 'Bakban'],
        ['36 Rosebery Avenue, London EC1R 5HP England', 'Galbi'],
        ['151-4, Samseong-dong, Gangnam-gu, Seoul South Korea', 'Gopchang'],
        ['133-6, Cheongdam-dong, Gangnam-gu, Seoul (서울특별시 강남구 청담동 133-6)', 'Gopchang'],
        ['144-5, Nonhyeon-dong, Gangnam-gu, Seoul (서울특별시 강남구 학동로2길 33)', 'Gopchang'],
        ['210-2, Bongsan-dong, Yeosu-si, Jeollanam-do', 'Hanjeongsik'],
        ['983, Daechi-dong, Gangnam-gu, Seoul', 'Hanjeongsik'],
        ['4032 W Olympic Blvd, Los Angeles, CA 90019', 'Haejang'],
        ['278-280 Huntingdon Street, Nottingham NG1 3NA England', 'Dolsot'],
        ['322-38, Sinjang-dong, Pyeongtaek-si, Gyeonggi-do', 'Budae-jjigae'],
        ['641-18, Yeoksam-dong, Gangnam-gu, Seoul', 'Budae-jjigae'],
        ['425 S Western Ave. Los Angeles, CA 90020', 'Jokbal'],
        ['24, Eulji-ro 12-gil, Jung-gu, Seoul 04550', 'Seolleongtang'],
        ['No. 6, Lane 40, Section 2, Zhongcheng Road, Shilin District, Taipei City (台北市士林區忠誠路二段40巷6號)', 'Ssambab'],
        ['96 Bowery, New York, NY 10013', 'Dubu'],
        ["29 Jardine's Bazaar, Causeway Bay, Hong Kong", 'Cífàntuán'],
        ['Gneisenaustr. 8, 10961 Berlin Germany', 'Pajeon'],
        ['No.333 Huaihai Middle Road Xintiandi Plaza B2-17, Shanghai 200000 China', 'Pajeon']
      ]
    )

    categories = RestaurantCategory.order(:id).pluck(:name, :parent_id)
    expect(categories.count).to eq(15)
    korean_cat = RestaurantCategory.find_by(name: 'Korean')
    chinese_cat = RestaurantCategory.find_by(name: 'Chinese')
    expect(categories).to eq(
      [
        ['Korean', nil],
        ['Bakban', korean_cat.id],
        ['Galbi', korean_cat.id],
        ['Gopchang', korean_cat.id],
        ['Hanjeongsik', korean_cat.id],
        ['Haejang', korean_cat.id],
        ['Dolsot', korean_cat.id],
        ['Budae-jjigae', korean_cat.id],
        ['Jokbal', korean_cat.id],
        ['Seolleongtang', korean_cat.id],
        ['Chinese', nil],
        ['Ssambab', chinese_cat.id],
        ['Dubu', chinese_cat.id],
        ['Cífàntuán', chinese_cat.id],
        ['Pajeon', chinese_cat.id]
      ]
    )

    # Export current data to CSV
    # --------------------------
    # Using #df_export, an array is returned, which is easily converted back to CSV
    exported_csv = CSV.generate(force_quotes: false) do |csv_out|
      Restaurant.df_export.each { |row| csv_out << row }
    end
    # The generated CSV exactly matches the original which we started with
    expect(exported_csv).to eq(csv_in)
  end
end
