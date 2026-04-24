class AddHapCertToPlats < ActiveRecord::Migration[5.1]
  def change
    add_column :plats, :hap_cert, :string
    add_column :plats, :hap_cert_password, :string
  end
end
