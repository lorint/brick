# frozen_string_literal: true

require 'spec_helper'

module Kitchen
  RSpec.describe Recipe, type: :model do
    before(:each) do
      IngredientRecipe.destroy_all
      Ingredient.destroy_all
      Recipe.destroy_all
      spag = described_class.find_or_create_by(name: 'Spaghetti Barilla with Squid ink')

      Ingredient.find_or_create_by(name: 'Spaghetti Barilla')
      tomatoes = Ingredient.find_or_create_by(name: 'San Marzano Tomatoes')
      Ingredient.find_or_create_by(name: 'Squid Ink')
      Ingredient.find_or_create_by(name: 'Extra Virgin Olive Oil')
      Ingredient.find_or_create_by(name: 'Minced Parsley')
      garlic = Ingredient.find_or_create_by(name: 'Clove of Garlic')
      Ingredient.find_or_create_by(name: 'Chilli Pepper')
      salt = Ingredient.find_or_create_by(name: 'Salt')

      Ingredient.all.each do |i|
        spag.ingredient_recipes.find_or_create_by(ingredient_id: i.id)
      end

      last_spag_ingredient_id = Ingredient.pluck(:id).max

      shrimp_pasta = described_class.find_or_create_by(name: 'Pasta with Shrimp and San Marzano Tomatoes')

      Ingredient.find_or_create_by(name: 'Medium Shell-on Shrimp')
      Ingredient.find_or_create_by(name: 'Olive Oil')
      Ingredient.find_or_create_by(name: 'Fennel Bulb')
      Ingredient.find_or_create_by(name: 'Small Onion')
      Ingredient.find_or_create_by(name: 'Celery Stalk')
      Ingredient.find_or_create_by(name: 'Tomato Paste')
      Ingredient.find_or_create_by(name: 'Sprig of Thyme')
      Ingredient.find_or_create_by(name: 'Dry White Wine')
      Ingredient.find_or_create_by(name: 'Small Jalapeño')
      Ingredient.find_or_create_by(name: 'Unsalted Butter')
      Ingredient.find_or_create_by(name: 'Calabrian Chilli Paste')
      Ingredient.find_or_create_by(name: 'Bucatini')
      Ingredient.find_or_create_by(name: 'Basil Leaves')
      Ingredient.find_or_create_by(name: 'Chives')
      Ingredient.find_or_create_by(name: 'Scallion')

      Ingredient.where("id > #{last_spag_ingredient_id}").each do |i|
        shrimp_pasta.ingredient_recipes.find_or_create_by(ingredient_id: i.id)
      end

      # Has these shared ingredients from the squid ink recipe:
      shrimp_pasta.ingredient_recipes.find_or_create_by(ingredient_id: garlic.id)
      shrimp_pasta.ingredient_recipes.find_or_create_by(ingredient_id: tomatoes.id)
      shrimp_pasta.ingredient_recipes.find_or_create_by(ingredient_id: salt.id)
    end

    describe '#suggest_template' do
      it 'properly enumerates an associative table for N:M relationships' do
        # #suggest_template does not enumerate has_many associations in older versions of Rails.
        unless ActiveRecord.version < ::Gem::Version.new('4.2')
          # rubocop:disable Layout/MultilineArrayBraceLayout
          expect(described_class.suggest_template(true, true, 2, false, false)).to eq(
            {
              uniques: [:name],
              required: [],
              all: [:name,
                { ingredient_recipes: [
                  { ingredient: [:name] }] }],
              as: {}
            }
          )
          # rubocop:enable Layout/MultilineArrayBraceLayout
        end
      end
    end

    # describe '#df_import' do
    #   it 'properly enumerates an associative table for N:M relationships' do
    #     recipe = described_class.create!
    #   end
    # end

    describe '#df_export' do
      it 'can export all related rows for data structured in an N:M relationship' do
        all_rows = described_class.df_export(true)
        expect(all_rows).to eq([['Name', 'Ingredients Name'],
                                ['Spaghetti Barilla with Squid ink', 'Spaghetti Barilla'],
                                ['Spaghetti Barilla with Squid ink', 'San Marzano Tomatoes'],
                                ['Spaghetti Barilla with Squid ink', 'Squid Ink'],
                                ['Spaghetti Barilla with Squid ink', 'Extra Virgin Olive Oil'],
                                ['Spaghetti Barilla with Squid ink', 'Minced Parsley'],
                                ['Spaghetti Barilla with Squid ink', 'Clove of Garlic'],
                                ['Spaghetti Barilla with Squid ink', 'Chilli Pepper'],
                                ['Spaghetti Barilla with Squid ink', 'Salt'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'San Marzano Tomatoes'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Clove of Garlic'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Salt'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Medium Shell-on Shrimp'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Olive Oil'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Fennel Bulb'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Small Onion'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Celery Stalk'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Tomato Paste'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Sprig of Thyme'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Dry White Wine'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Small Jalapeño'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Unsalted Butter'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Calabrian Chilli Paste'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Bucatini'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Basil Leaves'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Chives'],
                                ['Pasta with Shrimp and San Marzano Tomatoes', 'Scallion']])

        # Re-import to check it
        IngredientRecipe.destroy_all
        described_class.destroy_all
        Ingredient.destroy_all
        described_class.df_import(all_rows)
        # Check that all the ingredients are re-imported without duplicates and in the proper order
        expect(Ingredient.order(:id).pluck(:name)).to eq(['Spaghetti Barilla',
                                                          'San Marzano Tomatoes',
                                                          'Squid Ink',
                                                          'Extra Virgin Olive Oil',
                                                          'Minced Parsley',
                                                          'Clove of Garlic',
                                                          'Chilli Pepper',
                                                          'Salt',
                                                          'Medium Shell-on Shrimp',
                                                          'Olive Oil',
                                                          'Fennel Bulb',
                                                          'Small Onion',
                                                          'Celery Stalk',
                                                          'Tomato Paste',
                                                          'Sprig of Thyme',
                                                          'Dry White Wine',
                                                          'Small Jalapeño',
                                                          'Unsalted Butter',
                                                          'Calabrian Chilli Paste',
                                                          'Bucatini',
                                                          'Basil Leaves',
                                                          'Chives',
                                                          'Scallion'])
        # Check that each recipe has the appropriate number of ingredients
        # ----------------------------------------------------------------
        # Note that for AR < 4.0, the three ingredients which are part of both recipes only
        # get applied to the 'Spaghetti Barilla with Squid ink' recipe.  This is a known bug and
        # not due to be fixed, being as supporting import behaviour for such an ancient version
        # of ActiveRecord is nearly useless.  Export?  Yes, we're interested to make all of that
        # work so data can more effectively be migrated away from historic apps.  But Import?  Not
        # as import-ant for us! :)
        unless ActiveRecord.version < ::Gem::Version.new('4.0')
          expect(Recipe.joins(:ingredient_recipes).group(:name).order(:name).pluck(:name, Arel.sql('COUNT(*)'))).to eq(
            [
              ['Pasta with Shrimp and San Marzano Tomatoes', 18],
              ['Spaghetti Barilla with Squid ink', 8]
            ]
          )
        end
      end
    end

    describe '#df_export' do
      it 'can export a subset of related rows for data structured in an N:M relationship' do
        filtered_rows = described_class.df_export(true) do |relation, mapping|
          # For recipe and ingredient, even though there is an associative table, the ORDER BY is based
          # solely on Recipe and Ingredient, in that order.  (So in this case, ["recipes.id", "ingredients.id"])
          expect(relation.order_values).to eq(mapping.values.map { |m| "#{m}.id" })
          relation.dup.where("#{mapping['_']}.name" => 'Spaghetti Barilla with Squid ink')
        end
        expect(filtered_rows).to eq([['Name', 'Ingredients Name'],
                                     ['Spaghetti Barilla with Squid ink', 'Spaghetti Barilla'],
                                     ['Spaghetti Barilla with Squid ink', 'San Marzano Tomatoes'],
                                     ['Spaghetti Barilla with Squid ink', 'Squid Ink'],
                                     ['Spaghetti Barilla with Squid ink', 'Extra Virgin Olive Oil'],
                                     ['Spaghetti Barilla with Squid ink', 'Minced Parsley'],
                                     ['Spaghetti Barilla with Squid ink', 'Clove of Garlic'],
                                     ['Spaghetti Barilla with Squid ink', 'Chilli Pepper'],
                                     ['Spaghetti Barilla with Squid ink', 'Salt']])

        # Now do the export the other way around, from Ingredient back towards Recipe, and
        # filter by a couple of ingredients.
        filtered_rows = Ingredient.df_export(true) do |relation, mapping|
          # For ingredient to recipe, the ORDER BY is for Ingredient and Recipe, in that order.
          # (So in this case, ["ingredients.id", "recipes.id"])
          expect(relation.order_values).to eq(mapping.values.map { |m| "#{m}.id" })
          relation.dup.where("#{mapping['_']}.name" => ['Clove of Garlic', 'Squid Ink'])
        end
        expect(filtered_rows).to eq([['Name', 'Recipes Name'],
                                     ['Squid Ink', 'Spaghetti Barilla with Squid ink'],
                                     ['Clove of Garlic', 'Spaghetti Barilla with Squid ink'],
                                     ['Clove of Garlic', 'Pasta with Shrimp and San Marzano Tomatoes']])
      end
    end
  end
end
