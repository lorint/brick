# frozen_string_literal: true

class SetUpTestTables < (
  if ::ActiveRecord::VERSION::MAJOR >= 5
    ::ActiveRecord::Migration::Current
  else
    ::ActiveRecord::Migration
  end
)
  TEXT_BYTES = 1_073_741_823

  def up
    create_table :on_create, force: true do |t|
      t.string :name, null: false
    end

    create_table :on_destroy, force: true do |t|
      t.string :name, null: false
    end

    create_table :on_empty_array, force: true do |t|
      t.string :name, null: false
    end

    create_table :on_touch, force: true do |t|
      t.string :name, null: false
    end

    create_table :on_update, force: true do |t|
      t.string :name, null: false
    end

    # Classes: Vehicle, Car, Truck
    create_table :vehicles, force: true do |t|
      t.string :name, null: false
      t.string :type, null: false
      t.integer :owner_id
      t.timestamps null: false, limit: 6
    end

    create_table :skippers, force: true do |t|
      t.string     :name
      t.datetime   :another_timestamp, limit: 6
      t.timestamps null: true, limit: 6
    end

    # Widgets and friends
    create_table :widgets, force: true do |t|
      t.string    :name
      t.text      :a_text
      t.integer   :an_integer
      t.float     :a_float
      t.decimal   :a_decimal, precision: 7, scale: 4
      t.datetime  :a_datetime, limit: 6
      t.time      :a_time
      t.date      :a_date
      t.boolean   :a_boolean
      t.string    :type
      t.timestamps null: true, limit: 6
    end
    create_table :wotsits, force: true do |t|
      t.integer :widget_id
      t.string  :name
      t.timestamps null: true, limit: 6
    end
    create_table :fluxors, force: true do |t|
      t.integer :widget_id
      t.string  :name
    end
    create_table :whatchamajiggers, force: true do |t|
      t.string  :jig_type
      t.integer :jig_id
      t.string  :name
    end

    # HABTM
    create_table :foo_habtms, force: true do |t|
      t.string :name
    end
    create_table :foo_habtms_widgets, force: true, id: false do |t|
      t.references :foo_habtm
      t.references :widget
    end

    # HMT
    create_table :foo_hmts, force: true do |t|
      t.string :name
    end
    create_table :foo_hmt_widgets, force: true, id: false do |t|
      t.references :foo_hmt
      t.references :widget
    end

    if ENV['DB'] == 'postgres'
      create_table :postgres_users, force: true do |t|
        t.string     :name
        t.integer    :post_ids,    array: true
        t.datetime   :login_times, array: true, limit: 6
        t.timestamps null: true, limit: 6
      end
    end

    create_table :not_on_updates, force: true do |t|
      t.timestamps null: true, limit: 6
    end

    create_table :articles, force: true do |t|
      t.string :title
      t.string :content
      t.string :abstract
      t.string :file_upload
    end

    create_table :books, force: true do |t|
      t.string :title
    end

    create_table :authorships, force: true do |t|
      t.integer :book_id
      t.integer :author_id
    end

    create_table :people, force: true do |t|
      t.string :name
      t.string :time_zone
      t.integer :mentor_id
    end

    create_table :editorships, force: true do |t|
      t.integer :book_id
      t.integer :editor_id
    end

    create_table :editors, force: true do |t|
      t.string :name
    end

    create_table :songs, force: true do |t|
      t.integer :length
    end

    create_table :posts, force: true do |t|
      t.string :title
      t.string :content
    end

    create_table :post_with_statuses, force: true do |t|
      t.integer :status
      t.timestamps null: false, limit: 6
    end

    create_table :animals, force: true do |t|
      t.string :name
      t.string :species # single table inheritance column
    end

    create_table :pets, force: true do |t|
      t.integer :owner_id
      t.integer :animal_id
    end

    create_table :documents, force: true do |t|
      t.string :name
    end

    create_table :legacy_widgets, force: true do |t|
      t.string    :name
      t.integer   :version
    end

    create_table :things, force: true do |t|
      t.string    :name
      t.references :person
    end

    create_table :translations, force: true do |t|
      t.string    :headline
      t.string    :content
      t.string    :language_code
      t.string    :type
    end

    create_table :gadgets, force: true do |t|
      t.string    :name
      t.string    :brand
      t.timestamps null: true, limit: 6
    end

    # create_table :customers, force: true do |t|
    #   t.string :name
    # end

    # create_table :orders, force: true do |t|
    #   t.integer :customer_id
    #   t.string  :order_date
    # end

    # create_table :line_items, force: true do |t|
    #   t.integer :order_id
    #   t.string  :product
    # end

    create_table :fruits, force: true do |t|
      t.string :name
      t.string :color
    end

    create_table :boolits, force: true do |t|
      t.string :name
      t.boolean :scoped, default: true
    end

    create_table :callback_modifiers, force: true do |t|
      t.string  :some_content
      t.boolean :deleted, default: false
    end

    create_table :chapters, force: true do |t|
      t.string :name
    end

    create_table :sections, force: true do |t|
      t.integer :chapter_id
      t.string :name
    end

    create_table :paragraphs, force: true do |t|
      t.integer :section_id
      t.string :name
    end

    create_table :quotations, force: true do |t|
      t.integer :chapter_id
    end

    create_table :citations, force: true do |t|
      t.integer :quotation_id
    end

    # has_many :through
    create_table :recipes, force: true do |t|
      t.string :name
    end
    create_table :ingredients, force: true do |t|
      t.string :name
    end
    create_table :ingredient_recipes, force: true do |t|
      t.references :ingredient
      t.references :recipe
    end

    # Northwind tables
    is_mysql = ActiveRecord::Base.connection.class.name.end_with?('::Mysql2Adapter')
    # Self-referencing table
    create_table :employees do |t|
      t.string :first_name
      t.string :last_name
      t.string :title
      t.string :title_of_courtesy
      t.date :birth_date
      t.date :hire_date
      t.string :address
      t.string :city
      t.string :region
      t.string :postal_code
      t.string :country
      t.string :home_phone
      t.string :extension
      t.text :notes
      t.references :reports_to
    end
    create_table :customers do |t|
      t.string :company_code
      t.string :company_name
      t.string :contact_name
      t.string :contact_title
      t.string :address
      t.string :city
      t.string :region
      t.string :postal_code
      t.string :country
      t.string :phone
      t.string :fax
    end
    create_table :orders do |t|
      t.date :order_date
      t.date :required_date
      t.date :shipped_date
      t.references :ship_via, index: true
      if is_mysql
        t.decimal :freight, precision: 10, scale: 2
      else
        t.decimal :freight
      end
      t.string :ship_name
      t.string :ship_address
      t.string :ship_city
      t.string :ship_region
      t.string :ship_postal_code
      t.string :ship_country
      t.string :customer_code
      t.references :customer, index: true
      t.references :employee, index: true
    end
    create_table :categories do |t|
      t.string :category_name
      t.string :description
    end
    create_table :products do |t|
      t.string :product_name
      t.string :quantity_per_unit
      if is_mysql
        t.decimal :unit_price, precision: 10, scale: 2
      else
        t.decimal :unit_price
      end
      t.integer :units_in_stock
      t.integer :units_on_order
      t.integer :reorder_level
      t.boolean :discontinued
      t.references :supplier, index: true
      t.references :category, index: true
    end
    create_table :order_details do |t|
      if is_mysql
        t.decimal :unit_price, precision: 10, scale: 2
        t.integer :quantity
        t.decimal :discount, precision: 10, scale: 2
      else
        t.decimal :unit_price
        t.integer :quantity
        t.decimal :discount
      end
      t.references :order, index: true
      t.references :product, index: true
    end

    create_table :restaurant_categories do |t|
      t.string :name
      t.references :parent, index: true
    end
    create_table :restaurants do |t|
      t.string :name
      t.string :address
      t.references :category, index: true
    end

    # custom_primary_key_records use a uuid column (string)
    create_table :custom_primary_key_records, id: false, force: true do |t|
      t.column :uuid, :string, primary_key: true
      t.string :name
      t.timestamps null: true, limit: 6
    end

    create_table :family_lines do |t|
      t.integer :parent_id
      t.integer :grandson_id
    end

    create_table :families do |t|
      t.string :name
      t.string :type            # For STI support
      t.string :path_to_stardom # Only used for celebrity families
      t.integer :parent_id
      t.integer :partner_id
    end

    # For these two examples from Stack Overflow questions:
    # https://stackoverflow.com/questions/51955217/import-data-from-csv-into-two-tables-in-rails
    # https://stackoverflow.com/questions/52411407/csv-upload-in-rails
    create_table :parents do |t|
      t.string :firstname
      t.string :lastname
      t.string :address
      t.string :address_line_2
      t.string :city
      t.string :province
      t.string :postal_code
      t.string :telephone_number
      t.string :email
      t.string :admin_notes
      t.integer :gross_income
      t.boolean :created_by_admin
      t.string :status
    end
    create_table :children do |t|
      t.references :parent
      t.string :firstname
      t.string :lastname
      t.date :dateofbirth
      t.string :gender
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

private

  def item_type_options
    opt = { null: false }
    opt[:limit] = 191 if mysql?
    opt
  end

  def mysql?
    [
      'ActiveRecord::ConnectionAdapters::MysqlAdapter',
      'ActiveRecord::ConnectionAdapters::Mysql2Adapter'
    ].freeze.include?(connection.class.name)
  end
end
