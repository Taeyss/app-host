require 'openssl'
require 'json'
require 'base64'

# 鸿蒙 OTA 内部测试 manifest.json5 构建与签名服务
#
# 签名算法与华为 internal-testing 工具保持一致：
#   - 对 manifest 的 JSON 内容（不含 sign 字段，紧凑格式）计算 SHA-256
#   - 使用 p12 中的私钥（EC / RSA）对摘要进行签名
#   - 结果 Base64（strict）编码后写入 sign 字段
class HapManifestService

  # @param pkg  [Pkg]    包记录
  # @param base_url [String]  如 "https://ota.example.com"
  def initialize(pkg, base_url)
    @pkg      = pkg
    @base_url = base_url
    @plat     = pkg.plat
  end

  # 返回最终 JSON 字符串（含 sign 字段，若证书配置正确）
  def to_json
    manifest = build_manifest
    sign     = generate_sign(manifest)
    manifest[:sign] = sign if sign.present?
    JSON.pretty_generate(manifest)
  end

  # 仅返回 manifest Hash（不含 sign），供调试
  def manifest_without_sign
    build_manifest
  end

  # 证书是否已配置
  def cert_configured?
    @plat.hap_cert.present? && @plat.hap_cert_password.present?
  end

  # 签名时的错误信息（如有）
  attr_reader :sign_error

  private

  def build_manifest
    meta        = @pkg.hap_meta
    module_name = meta["module_name"].presence || "entry"
    module_type = meta["module_type"].presence || "entry"
    icon_url    = "#{@base_url}#{@pkg.icon}"
    pkg_url     = @pkg.download_url
    pkg_hash    = @pkg.pkg_sha256.to_s

    manifest = {
      app: {
        bundleName:        @pkg.bundle_id,
        bundleType:        "app",
        versionCode:       @pkg.build.to_i,
        versionName:       @pkg.version,
        label:             @pkg.name,
        deployDomain:      URI.parse(@base_url).host,
        icons: {
          normal: icon_url,
          large:  icon_url,
        },
      },
      modules: [
        {
          name:        module_name,
          type:        module_type,
          deviceTypes: ["phone"],
          packageUrl:  pkg_url,
          packageHash: pkg_hash,
        },
      ],
    }

    min_api    = meta["min_api_version"]
    target_api = meta["target_api_version"]
    manifest[:app][:minAPIVersion]    = min_api    if min_api.present?
    manifest[:app][:targetAPIVersion] = target_api if target_api.present?

    manifest
  end

  # 使用 p12 私钥对 manifest（不含 sign）进行数字签名
  # 与 Huawei internal-testing 工具使用相同的算法：
  #   EC 私钥 → ECDSA-SHA256；RSA 私钥 → RSA-SHA256
  def generate_sign(manifest_hash)
    return @pkg.pkg_manifest_sign.presence unless cert_configured?

    cert_path = @plat.hap_cert.path
    password  = @plat.hap_cert_password

    unless File.exist?(cert_path.to_s)
      @sign_error = "p12 文件不存在：#{cert_path}"
      return @pkg.pkg_manifest_sign.presence
    end

    p12_data = File.binread(cert_path)
    p12      = OpenSSL::PKCS12.new(p12_data, password)
    key      = p12.key

    # 待签名内容：manifest 的紧凑 JSON（不含 sign 字段）
    content = JSON.generate(manifest_hash)

    digest    = OpenSSL::Digest::SHA256.new
    signature = key.sign(digest, content)
    Base64.strict_encode64(signature)

  rescue OpenSSL::PKCS12::PKCS12Error => e
    @sign_error = "p12 解析失败，请检查密码是否正确：#{e.message}"
    @pkg.pkg_manifest_sign.presence
  rescue => e
    @sign_error = "签名失败：#{e.message}"
    @pkg.pkg_manifest_sign.presence
  end
end
