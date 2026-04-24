class AddHapFieldsToPkgs < ActiveRecord::Migration[5.1]
  def change
    add_column :pkgs, :pkg_sha256, :string
    add_column :pkgs, :pkg_manifest_sign, :text
  end
end