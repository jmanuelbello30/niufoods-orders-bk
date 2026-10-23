class CreateUsersAndApiSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true
    add_check_constraint :users, "email = lower(btrim(email)) AND email <> ''", name: "users_normalized_email"

    create_table :api_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false, limit: 64
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :api_sessions, :token_digest, unique: true
    add_index :api_sessions, :expires_at
  end
end
