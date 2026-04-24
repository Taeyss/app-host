module PkgAdapter

  # HarmonyOS HAP 包解析器
  # 支持 Stage 模型（module.json + app.json）和旧 FA 模型（config.json）
  class Hap < BaseAdapter

    require 'zip'
    require 'json'

    MODULE_JSON = 'module.json'
    APP_JSON    = 'app.json'
    CONFIG_JSON = 'config.json'

    def parse
      Zip::File.open(@path) do |zip|
        if (entry = zip.glob(MODULE_JSON).first)
          parse_stage_model(zip, entry)
        elsif (entry = zip.glob(CONFIG_JSON).first)
          parse_fa_model(zip, entry)
        else
          raise "未找到有效的鸿蒙包配置文件（module.json / config.json）"
        end
      end
    end

    def plat
      'harmonyos'
    end

    def app_uniq_key
      :build
    end

    def app_name
      @app_name
    end

    def app_version
      @app_version
    end

    def app_build
      @app_build
    end

    def app_icon
      @app_icon
    end

    def app_size
      File.size(@path)
    end

    def app_bundle_id
      @bundle_id
    end

    def min_api_version
      @min_api_version
    end

    def target_api_version
      @target_api_version
    end

    def module_name
      @module_name
    end

    def module_type
      @module_type
    end

    def pkg_sha256
      @pkg_sha256 ||= Digest::SHA256.hexdigest(File.binread(@path))
    end

    def ext_info
      {
        "包信息" => [
          "包名: #{app_bundle_id}",
          "体积: #{app_size_mb}MB",
          "MD5: #{pkg_mb5}",
          "模型: #{@hap_model || '未知'}",
          "模块类型: #{@module_type || '未知'}",
        ].compact,
        "SDK信息" => [
          ("最低兼容API: #{@min_api_version}" if @min_api_version),
          ("目标API: #{@target_api_version}" if @target_api_version),
        ].compact,
        "_meta" => {
          "min_api_version"    => @min_api_version,
          "target_api_version" => @target_api_version,
          "module_name"        => @module_name,
          "module_type"        => @module_type,
          "hap_model"          => @hap_model,
        }.compact,
      }
    end

    private

    # HarmonyOS Next Stage 模型：module.json + 可选的 app.json
    def parse_stage_model(zip, module_entry)
      @hap_model = 'Stage'
      @string_table = load_string_table(zip)
      module_json = JSON.parse(module_entry.get_input_stream.read)
      mod  = module_json['module'] || {}
      app  = module_json['app']    || {}

      # app.json 单独存在时优先读取
      if app.empty? && (app_entry = zip.glob(APP_JSON).first)
        app = JSON.parse(app_entry.get_input_stream.read)['app'] || {}
      end

      @bundle_id          = app['bundleName']  || mod['bundleName']
      @app_version        = resolve_string(app['versionName']  || mod['versionName'])
      @app_build          = (app['versionCode'] || mod['versionCode']).to_s
      raw_name            = app['label']        || mod['label']
      @app_name           = resolve_string(raw_name) || @bundle_id
      @module_name        = mod['name']
      @module_type        = mod['type']
      @min_api_version    = app['minAPIVersion']    || mod['minAPIVersion']
      @target_api_version = app['targetAPIVersion'] || mod['targetAPIVersion']

      extract_icon(zip, app['icon'] || mod['icon'])
    end

    # 旧 FA 模型：config.json
    def parse_fa_model(zip, config_entry)
      @hap_model = 'FA'
      @string_table = load_string_table(zip)
      config = JSON.parse(config_entry.get_input_stream.read)
      app    = config['app']    || {}
      module_cfg = (config['module'] || {})

      @bundle_id          = app['bundleName']
      version             = app['version']  || {}
      @app_version        = version['name'].to_s
      @app_build          = version['code'].to_s
      raw_name            = app['name'] || module_cfg.dig('abilities', 0, 'label')
      @app_name           = resolve_string(raw_name) || @bundle_id
      @module_name        = module_cfg['distro']&.dig('moduleName') || module_cfg['name']
      @module_type        = module_cfg['distro']&.dig('moduleType')
      api_ver             = app['apiVersion'] || {}
      @min_api_version    = api_ver['compatible']
      @target_api_version = api_ver['target']

      icon_ref = app['icon'] || module_cfg.dig('abilities', 0, 'icon')
      extract_icon(zip, icon_ref)
    end

    # 将 "$media:xxx" 解析为实际图片文件并提取到临时目录
    # 处理三种情况：直接图片文件、layered-image JSON（前景+背景合成）、icon.png 兜底
    def extract_icon(zip, icon_ref)
      return unless icon_ref.is_a?(String)

      icon_name = icon_ref =~ /^\$media:(.+)$/ ? $1 : File.basename(icon_ref, '.*')

      entry = find_media_entry(zip, icon_name)

      if entry&.name&.end_with?('.json')
        # layered-image：提取前景+背景并合成
        composite_path = extract_layered_icon(zip, entry)
        if composite_path
          @app_icon = composite_path
          return
        end
        # JSON 里是数字 ID 无法解析时，直接用命名规范的图层文件合成
        bg_entry = find_media_entry(zip, 'background_app_icon')
        fg_entry = find_media_entry(zip, 'foreground_app_icon')
        if bg_entry && fg_entry
          composite_path = composite_two_entries(zip, bg_entry, fg_entry)
          if composite_path
            @app_icon = composite_path
            return
          end
        end
        # 最终降级：单张图
        entry = fg_entry || find_media_entry(zip, 'icon') || bg_entry
      end

      return unless entry && !entry.name.end_with?('.json')

      icon_path = "#{tmp_dir}/#{File.basename(entry.name)}"
      FileUtils.mkdir_p(tmp_dir)
      entry.extract(icon_path) { true }
      @app_icon = icon_path
    end

    # 在 zip 中按名称查找图片文件（优先 png，其次 webp/jpg，最后通配符）
    def find_media_entry(zip, name)
      %w[png webp jpg jpeg].each do |ext|
        %W[resources/base/media/#{name}.#{ext}
           entry/resources/base/media/#{name}.#{ext}].each do |path|
          e = zip.glob(path).first
          return e if e
        end
      end
      %W[resources/base/media/#{name}.json
         entry/resources/base/media/#{name}.json].each do |path|
        e = zip.glob(path).first
        return e if e
      end
      %w[png webp jpg jpeg].lazy.map { |ext|
        zip.glob("**/#{name}.#{ext}").first
      }.reject(&:nil?).first
    end

    # 解析 layered-image JSON，将背景+前景合成为一张 PNG
    def extract_layered_icon(zip, json_entry)
      begin
        data = JSON.parse(json_entry.get_input_stream.read)
      rescue
        return nil
      end
      li = data['layered-image'] || {}
      return nil if li.empty?

      bg_entry = resolve_media_ref(zip, li['background'])
      fg_entry = resolve_media_ref(zip, li['foreground'])
      return nil unless bg_entry || fg_entry

      # 只有其中一张时直接用
      if bg_entry && !fg_entry
        path = "#{tmp_dir}/#{File.basename(bg_entry.name)}"
        FileUtils.mkdir_p(tmp_dir)
        bg_entry.extract(path) { true }
        return path
      end
      if fg_entry && !bg_entry
        path = "#{tmp_dir}/#{File.basename(fg_entry.name)}"
        FileUtils.mkdir_p(tmp_dir)
        fg_entry.extract(path) { true }
        return path
      end

      # 两张都有：合成
      composite_two_entries(zip, bg_entry, fg_entry) || bg_path
    end

    # 将两个 zip entry（背景+前景）解压后用 MiniMagick 合成为一张 PNG
    def composite_two_entries(zip, bg_entry, fg_entry)
      FileUtils.mkdir_p(tmp_dir)
      bg_path = "#{tmp_dir}/bg_#{File.basename(bg_entry.name)}"
      fg_path = "#{tmp_dir}/fg_#{File.basename(fg_entry.name)}"
      bg_entry.extract(bg_path) { true }
      fg_entry.extract(fg_path) { true }

      out_path = "#{tmp_dir}/icon_composed.png"
      begin
        require 'mini_magick'
        bg = MiniMagick::Image.open(bg_path)
        fg = MiniMagick::Image.open(fg_path)
        fg.resize "#{bg.width}x#{bg.height}!"
        result = bg.composite(fg) do |c|
          c.compose 'Over'
          c.geometry '+0+0'
        end
        result.format 'png'
        result.write out_path
        out_path
      rescue
        nil
      end
    end

    # 将 layered-image 中的 "$media:xxx" 或数字 ID 解析为 zip entry
    def resolve_media_ref(zip, ref)
      return nil unless ref.is_a?(String)
      return nil unless ref =~ /^\$media:(.+)$/
      candidate = $1
      # 数字 resource ID 无法直接对应文件名，返回 nil 让上层走 fallback
      return nil if candidate =~ /^\d+$/
      find_media_entry(zip, candidate)
    end

    # 解析 "$string:key" 资源引用
    def resolve_string(val)
      return nil unless val.is_a?(String)
      return val unless val =~ /^\$string:(.+)$/
      key = $1
      @string_table ? (@string_table[key] || key) : key
    end

    # 构建字符串查找表：先尝试 string.json（开发包），再解析 resources.index（编译包）
    def load_string_table(zip)
      table = load_string_json(zip)
      return table unless table.empty?
      parse_resources_index(zip)
    end

    # 从 string.json 构建表（适用于未编译的开发包）
    def load_string_json(zip)
      table = {}
      %w[
        resources/base/element/string.json
        entry/resources/base/element/string.json
        resources/zh_CN/element/string.json
        entry/resources/zh_CN/element/string.json
        resources/en_US/element/string.json
        entry/resources/en_US/element/string.json
      ].each do |path|
        entry = zip.glob(path).first
        next unless entry
        data = JSON.parse(entry.get_input_stream.read) rescue next
        (data['string'] || []).each do |item|
          table[item['name']] = item['value'] if item['name'] && item['value']
        end
      end
      # 通配符兜底
      if table.empty?
        zip.glob('**/element/string.json').each do |entry|
          data = JSON.parse(entry.get_input_stream.read) rescue next
          (data['string'] || []).each do |item|
            table[item['name']] = item['value'] if item['name'] && item['value']
          end
        end
      end
      table
    end

    # 解析编译后的 resources.index 二进制文件，构建字符串查找表
    # 二进制结构（每条 STRING 资源）：
    #   [resource_id 4B][type=0x09 4B][flags 3B][0x1b][value_len 2B][value_bytes+null][key_len 2B][key_bytes+null]
    def parse_resources_index(zip)
      # 用多种方式查找 resources.index（兼容 zip 内路径差异）
      entry = zip.find_entry('resources.index') ||
              zip.glob('resources.index').first ||
              zip.glob('**/resources.index').first
      return {} unless entry

      raw  = entry.get_input_stream.read
      data = raw.respond_to?(:b) ? raw.b : raw.force_encoding('BINARY')
      table = {}
      offset = 0
      len = data.bytesize

      while offset + 16 <= len
        # 特征：bytes[4..7] = type=9 (STRING)，byte[11] = 0x1b（未签名包）或 0x1a（签名包）
        b11 = data.getbyte(offset + 11)
        if data.getbyte(offset + 4) == 0x09 &&
           data.getbyte(offset + 5) == 0x00 &&
           data.getbyte(offset + 6) == 0x00 &&
           data.getbyte(offset + 7) == 0x00 &&
           (b11 == 0x1b || b11 == 0x1a)

          value_len = data[offset + 12, 2].unpack1('v')
          val_end   = offset + 14 + value_len

          if value_len > 0 && value_len < 1024 && val_end + 2 <= len
            # 提取 value，去掉末尾 null 字节
            val_bytes = data[offset + 14, value_len]
            null_pos  = val_bytes.index("\x00".b)
            val_bytes = null_pos ? val_bytes[0, null_pos] : val_bytes
            value = val_bytes.dup.force_encoding('UTF-8')

            key_len = data[val_end, 2].unpack1('v')
            key_end = val_end + 2 + key_len

            if key_len > 0 && key_len < 256 && key_end <= len
              key_bytes = data[val_end + 2, key_len]
              null_pos  = key_bytes.index("\x00".b)
              key_bytes = null_pos ? key_bytes[0, null_pos] : key_bytes
              key = key_bytes.dup.force_encoding('UTF-8')

              if value.valid_encoding? && key.valid_encoding? &&
                 !value.empty? && key =~ /\A[\w.\-\/]+\z/
                table[key] = value
                offset = key_end
                next
              end
            end
          end
        end

        offset += 1
      end

      table
    end

  end
end
