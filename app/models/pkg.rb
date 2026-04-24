# == Schema Information
#
# Table name: pkgs
#
#  id                  :integer          not null, primary key
#  app_id              :integer
#  name                :string
#  icon                :string
#  plat_name           :string
#  bundle_id           :string
#  version             :string
#  build               :string
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  plat_id             :integer
#  file                :string
#  size                :integer          default(0)
#  uniq_key            :string
#  user_id             :integer
#  deleted_at          :datetime
#  file_nick_name      :string
#  features            :string
#  ext_info            :string
#  pkg_sha256          :string           (HarmonyOS OTA 包完整性校验 SHA-256)
#  pkg_manifest_sign   :text             (HarmonyOS OTA manifest 签名)
#

class Pkg < ApplicationRecord

  serialize :ext_info, Hash

  attr_accessor :app_icon
  include PlatAble

  belongs_to :app
  belongs_to :plat
  belongs_to :user

  validates_presence_of :user_id
  validates_presence_of :file, :file_nick_name

  mount_uploader :icon, IconUploader
  mount_uploader :file, PkgUploader

  enum plat_name: {
    ios:        'ios',
    android:    'android',
    harmonyos:  'harmonyos'
  }

  after_create :save_icon
  after_create :save_sha256
  after_create :clean_tmp

  def initialize pars
    super pars
    parsing
  end

  def uniq?
    !self.class.where({plat_id:plat_id,self.uniq_key.to_sym => self[self.uniq_key.to_sym]}).exists?
  end

  def size_mb
   '%.1f' % (size / (1024*1024.0))
  end

  def parsing
    if file.path
      parser.parse
      self.name = parser.app_name
      self.app_icon = parser.app_icon
      self.version = parser.app_version
      self.build = parser.app_build
      self.size = parser.app_size
      self.bundle_id = parser.app_bundle_id
      self.plat_name = parser.plat
      self.uniq_key = parser.app_uniq_key
      self.ext_info = parser.ext_info
    end
  end

  def parser
    @parser ||= PkgAdapter.pkg_adapter(file.path)
  end

  def save_icon
    if app_icon&.match?(/\.(png|jpg|jpeg|webp)\z/i)
      self.icon.store!(File.new(app_icon))
      self.save
    end
  end

  def save_sha256
    if harmonyos? && file.path && File.exist?(file.path)
      self.update_column(:pkg_sha256, Digest::SHA256.hexdigest(File.binread(file.path)))
    end
  end

  def clean_tmp
    if File.exist?(parser.tmp_dir)
      FileUtils.rm_rf parser.tmp_dir
    end
  end

  def install_url
    if ios?
      "itms-services://?action=download-manifest&url=#{Current.request.base_url}#{Rails.application.routes.url_helpers.manifest_pkg_path(self)}.plist"
    elsif harmonyos?
      manifest_url = "#{Current.request.base_url}#{Rails.application.routes.url_helpers.manifest_hap_pkg_path(self)}.json5"
      "store://enterprise/manifest?url=#{manifest_url}"
    else
      download_url
    end
  end

  def download_url
    "#{Current.request.base_url}#{self.file}"
  end

  def display_file_name
    File.basename(file.path,".*")
  end

  def hap_meta
    (ext_info.is_a?(Hash) ? ext_info["_meta"] : nil) || {}
  end
  
end
