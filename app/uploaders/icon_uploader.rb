class IconUploader < CarrierWave::Uploader::Base

  # Include RMagick or MiniMagick support:
  # include CarrierWave::RMagick
  include CarrierWave::MiniMagick

  # Choose what kind of storage to use for this uploader:
  storage :file
  # storage :fog

  # Override the directory where uploaded files will be stored.
  # This is a sensible default for uploaders that are meant to be mounted:
  def store_dir
    "uploads/#{model.class.to_s.underscore}/#{mounted_as}/#{model.id}"
  end
 
  def default_url(*args)
    "/default_app_icon.png"
  end

  # webp 转 png，统一存储为 png
  process :convert_to_png

  def convert_to_png
    return unless file && %w[webp jpg jpeg].include?(file.extension.to_s.downcase)
    manipulate! do |img|
      img.format('png')
      img
    end
  end

  def filename
    "#{File.basename(super, '.*')}.png" if original_filename
  end

  def extension_whitelist
    %w(png jpg jpeg webp)
  end


end
