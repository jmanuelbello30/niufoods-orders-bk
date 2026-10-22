products = [
  [ 1, "Niu Roll Salmón", "SKU-001", 8990 ],
  [ 2, "California Ebi", "SKU-002", 7490 ],
  [ 3, "Avocado Roll", "SKU-003", 6990 ],
  [ 4, "Nigiri Salmón x2", "SKU-004", 3990 ],
  [ 5, "Gyozas de Pollo x5", "SKU-005", 4490 ],
  [ 6, "Edamame", "SKU-006", 3290 ],
  [ 7, "Bowl Salmón Teriyaki", "SKU-007", 9990 ],
  [ 8, "Bowl Pollo Teriyaki", "SKU-008", 8990 ],
  [ 9, "Bebida 350 ml", "SKU-009", 1990 ],
  [ 10, "Agua Mineral 500 ml", "SKU-010", 1590 ]
].map do |id, name, sku, price|
  { id: id, name: name, sku: sku, price: price }
end

restaurants = [
  [ 1, "Niu Foods Providencia", "PROV" ],
  [ 2, "Niu Foods Las Condes", "LCON" ],
  [ 3, "Niu Foods Ñuñoa", "NUNO" ]
].map do |id, name, code|
  { id: id, name: name, code: code, dispatch_url: "http://localhost:4567/restaurants/#{code}/orders" }
end

ActiveRecord::Base.transaction(requires_new: true) do
  [ [ Product, :sku, products ], [ Restaurant, :code, restaurants ] ].each do |model, key, records|
    records.each do |attributes|
      matches = model.where(id: attributes[:id]).or(model.where(key => attributes.fetch(key))).to_a

      if matches.any? && (matches.size != 1 || attributes.any? { |attribute, value| matches.first[attribute] != value })
        raise ArgumentError,
          "Seed conflict for #{model.name}: id=#{attributes[:id]}, #{key}=#{attributes.fetch(key)}; existing records do not match the reference data"
      end

      record = matches.first || model.new(attributes)
      record.save!
    end
  end

  [ Product, Restaurant ].each do |model|
    model.connection.reset_pk_sequence!(model.table_name)
  end
end
