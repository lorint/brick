module Brick
  # JoinArray and JoinHash
  #
  # These JOIN-related collection classes -- JoinArray and its related "partner in crime" JoinHash -- both interact to
  # more easily build out nested sets of hashes and arrays to be used with ActiveRecord's .joins() method.  For example,
  # if there is an Order, Customer, and Employee model, and Order belongs_to :customer and :employee, then from the
  # perspective of Order all these three could be JOINed together by referencing the two belongs_to association names:
  #
  #  Order.joins([:customer, :employee])
  #
  # and from the perspective of Employee it would instead use a hash like this, using the has_many :orders association
  # and the :customer belongs_to:
  #
  #  Employee.joins({ orders: :customer })
  #
  # (in both cases the same three tables are being JOINed, the two approaches differ just based on their starting standpoint.)
  # These utility classes are designed to make building out any goofy linkages like this pretty simple in a few ways:
  # ** if the same association is requested more than once then no duplicates.
  # ** If a bunch of intermediary associations are referenced leading up to a final one then all of them get automatically built
  #    out and added along the way, without any having to previously exist.
  # ** If one reference was made previously and now another neighbouring one is called for, then what used to be a simple symbol
  #    is automatically graduated into an array so that both members can be held.  For instance, if with the Order example above
  #    there was also a LineItem model that belongs_to Order, then let's say you start from LineItem and want to now get all 4
  #    related models.  You could start by going through :order to :employee like this:
  #
  # line_item_joins = JoinArray.new
  # line_item_joins[:order] = :employee
  # => { order: :employee }
  #
  #    and then add in the reference to :customer like this:
  #
  # line_item_joins[:order] = :customer
  # => { order: [:employee, :customer] }
  #
  #    and then carry on incrementally building out more JOINs in whatever sequence makes the best sense.  This bundle of nested
  #    stuff can then be used to query ActiveRecord like this:
  #
  # LineItem.joins(line_item_joins)

  class JoinArray < Array
    attr_reader :parent, :orig_parent, :parent_key
    alias _brick_set []=

    def [](*args)
      if !(key = args[0]).is_a?(Symbol)
        super
      else
        idx = -1
        # Whenever a JoinHash has a value of a JoinArray with a single member then it is a wrapper, usually for a Symbol
        matching = find { |x| idx += 1; (x.is_a?(::Brick::JoinArray) && x.first == key) || (x.is_a?(::Brick::JoinHash) && x.key?(key)) || x == key }
        case matching
        when ::Brick::JoinHash
          matching[key]
        when ::Brick::JoinArray
          matching.first
        else
          ::Brick::JoinHash.new.tap do |child|
            child.instance_variable_set(:@parent, self)
            child.instance_variable_set(:@parent_key, key) # %%% Use idx instead of key?
          end
        end
      end
    end

    def []=(*args)
      ::Brick::JoinArray.attach_back_to_root(self, args[0], args[1])

      if (key = args[0]).is_a?(Symbol) && ((value = args[1]).is_a?(::Brick::JoinHash) || value.is_a?(Symbol) || value.nil?)
        # %%% This is for the first symbol added to a JoinArray, cleaning out the leftover {} that is temporarily built out
        # when doing my_join_array[:value1][:value2] = nil.
        idx = -1
        delete_at(idx) if value.nil? && any? { |x| idx += 1; x.is_a?(::Brick::JoinHash) && x.empty? }

        set_matching(key, value)
      else
        super
      end
    end

    def self.attach_back_to_root(collection, key = nil, value = nil)
      # Create a list of layers which start at the root
      layers = []
      layer = collection
      while layer.parent
        layers << layer
        layer = layer.parent
      end
      # Go through the layers from root down to child, attaching everything
      layers.each do |layer|
        if (prnt = layer.remove_instance_variable(:@parent))
          layer.instance_variable_set(:@orig_parent, prnt)
        end
        case prnt
        when ::Brick::JoinHash
          value = if prnt.key?(layer.parent_key)
                    if layer.is_a?(Hash)
                      layer
                    else
                      ::Brick::JoinArray.new.replace([prnt.fetch(layer.parent_key, nil), layer])
                    end
                  else
                    layer
                  end
          # This is as if we did:  prnt[layer.parent_key] = value
          # but calling it that way would attempt to infinitely recurse back onto this overridden version of the []= method,
          # so we go directly to ._brick_store() instead.
          prnt._brick_store(layer.parent_key, value)
        when ::Brick::JoinArray
          if (key)
            puts "X1"
            prnt[layer.parent_key][key] = value
          else
            prnt[layer.parent_key] = layer
          end
        end
      end
    end

    def set_matching(key, value)
      idx = -1
      matching = find { |x| idx += 1; (x.is_a?(::Brick::JoinArray) && x.first == key) || (x.is_a?(::Brick::JoinHash) && x.key?(key)) || x == key }
      case matching
      when ::Brick::JoinHash
        matching[key] = value
      when Symbol
        if value.nil? # If it already exists then no worries
          matching
        else
          # Not yet there, so we will "graduate" this single value into being a key / value pair found in a JoinHash.  The
          # destination hash to be used will be either an existing one if there is a neighbouring JoinHash available, or a
          # newly-built one placed in the "new_hash" variable if none yet exists.
          hash = find { |x| x.is_a?(::Brick::JoinHash) } || (new_hash = ::Brick::JoinHash.new)
          hash._brick_store(key, ::Brick::JoinArray.new.tap { |val_array| val_array.replace([value]) })
          # hash.instance_variable_set(:@parent, matching.parent) if matching.parent
          # hash.instance_variable_set(:@parent_key, matching.parent_key) if matching.parent_key

          # When a new JoinHash was created, we place it at the same index where the original lone symbol value was pulled from.
          # If instead we used an existing JoinHash then since that symbol has now been graduated into a new key / value pair in
          # the existing JoinHash then we delete the original symbol by its index.
          new_hash ? _brick_set(idx, new_hash) : delete_at(idx)
        end
      when ::Brick::JoinArray # Replace this single thing (usually a Symbol found as a value in a JoinHash)
        (hash = ::Brick::JoinHash.new)._brick_store(key, value)
        if matching.parent
          hash.instance_variable_set(:@parent, matching.parent)
          hash.instance_variable_set(:@parent_key, matching.parent_key)
        end
        _brick_set(idx, hash)
      else # Doesn't already exist anywhere, so add it to the end of this JoinArray and return the new member
        if value
          ::Brick::JoinHash.new.tap do |hash|
            val_collection = if value.is_a?(::Brick::JoinHash)
                               value
                             else
                               ::Brick::JoinArray.new.tap { |array| array.replace([value]) }
                             end
            val_collection.instance_variable_set(:@parent, hash)
            val_collection.instance_variable_set(:@parent_key, key)
            hash._brick_store(key, val_collection)
            hash.instance_variable_set(:@parent, self)
            hash.instance_variable_set(:@parent_key, length)
          end
        else
          key
        end.tap { |member| push(member) }
      end
    end

    def add_parts(parts)
      s = self
      parts[0..-3].each { |part| s = s[part.to_sym] }
      s[parts[-2].to_sym] = nil # unless parts[-2].empty? # Using []= will "hydrate" any missing part(s) in our whole series
    end
  end

  class JoinHash < Hash
    attr_reader :parent, :orig_parent, :parent_key
    alias _brick_store []=

    def [](*args)
      if (current = super)
        current
      elsif (key = args[0]).is_a?(Symbol)
        ::Brick::JoinHash.new.tap do |child|
          child.instance_variable_set(:@parent, self)
          child.instance_variable_set(:@parent_key, key)
        end
      end
    end

    def []=(*args)
      ::Brick::JoinArray.attach_back_to_root(self)

      if !(key = args[0]).is_a?(Symbol) || (!(value = args[1]).is_a?(Symbol) && !value.nil?)
        super # Revert to normal hash behaviour when we're not passed symbols
      else
        case (current = fetch(key, nil))
        when value
          if value.nil? # Setting a single value where nothing yet exists
            case orig_parent
            when ::Brick::JoinHash
              if self.empty? # Convert this empty hash into a JoinArray
                orig_parent._brick_store(parent_key, ::Brick::JoinArray.new.replace([key]))
              else # Call back into []= to use our own logic, this time setting this value from the context of the parent
                orig_parent[parent_key] = key
              end
            when ::Brick::JoinArray
              orig_parent[parent_key][key] = nil
            else # No knowledge of any parent, so all we can do is add this single value right here as { key => nil }
              super
            end
            key
          else # Setting a key / value pair where nothing yet exists
            puts "X2"
            super(key, ::Brick::JoinArray.new.replace([value]))
            value
          end
        when Symbol # Upgrade an existing symbol to be a part of our special JoinArray
          puts "X3"
          super(key, ::Brick::JoinArray.new.replace([current, value]))
        when ::Brick::JoinArray # Concatenate new stuff onto any existing JoinArray
          current.set_matching(value, nil) if value
        when ::Brick::JoinHash # Graduate an existing hash into being in an array if things are dissimilar
          super(key, ::Brick::JoinArray.new.replace([current, value]))
          value
        else # Perhaps this is part of some hybrid thing
          super(key, ::Brick::JoinArray.new.replace([value]))
          value
        end
      end
    end
  end
end
