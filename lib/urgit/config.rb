require 'urgit'
require 'urgit/remote'

module Urgit
  class Config

    def initialize(repo = nil)
      repo = repo.path if repo.respond_to?(:path)
      @config_file_path = File.join(repo, 'config') if repo
      # TODO: handle global and system configs
      @global_config = {}
      @system_config = {}
      @repo_config = parse_file(@config_file_path)
      @config = @system_config.merge(@global_config).merge(@repo_config)
    end

    def parse_file(config_file)
      FileTest.readable?(config_file) ? parse_lines(File.readlines(config_file)) : {}
    end

    def parse_lines(lines)
      # TODO: some config file features are not yet implemented, such as
      #       values that span lines by using trailing '\'
      #       un-escaping \" and \\
      #       comment characters (';' and '#') contained in quoted values
      #       filtering only allowed characters in values
      #       options with multiple values
      #       boolean handling for 'yes/no', '1/0', 'true/false', 'on/off'
      #       other type conversions and validations

      options = {}
      depth = options[:unparsed_config]

      lines = Array(lines).map{|line| line.split("\n")}.flatten
      lines.each do |line|
        line.strip!
        ['#', ';'].each do |comment|
          line.gsub!(Regexp.new(Regexp.escape(comment) + '.*'), '')
          # TODO: properly handle comment characters between quotes
        end
        next if line =~ /^\s*$/

        case line
        when /^\[([\w-]+)\s+\"(.+)\"\s*\]$/  # [foo "bar"]
          sub_sec = options[$1.strip.downcase] ||= {}
          depth = sub_sec[$2] ||= {}
        when /^\[([\w-]+)\.([\w-]+)\]$/       # [foo.bar]
          sub_sec = options[$1.strip.downcase] ||= {}
          depth = sub_sec[$2.strip.downcase] ||= {}
        when /^\[([\w-]+)\]$/                # [foo]
          depth = options[$1.strip.downcase] ||= {}
        when /^([^=]+?)=/                    # key = value
          key, value = $1.strip, $'.strip
          depth[key] = value
        else
          depth[line] = true
        end
      end
      options.delete(:unparsed_config) if options[:unparsed_config] && options[:unparsed_config].empty?

      options
    end

    def options_hash
      @config
    end

    def options
      # TODO:  return dotted-string format of config hash
    end

    def save
      return nil unless @config_file_path
      File.open(@config_file_path, 'wb') { |file| file.write(file_style) }
    end

    # Format the config for writing to a file
    def file_style
      buffer = ''
      @config.each do |section, values|
        no_subs = values.select { |k,v| !v.is_a?(Hash) }
        if no_subs.any?
          buffer << "[#{section}]\n\t"
          buffer << no_subs.map { |pair| pair.join(' = ') }.join("\n\t")
          buffer << "\n"
        end

        subs = values.select { |k,v| v.is_a?(Hash) }
        if subs.any?
          subs.each do |subsection, pair|
            buffer << "[#{section} \"#{subsection}\"]\n\t"
            buffer << pair.map { |k,v| "#{k} = #{v}" }.join("\n\t")
            buffer << "\n"
          end
        end

      end
      buffer
    end

    def remotes
      @remotes ||= create_remotes_handler
    end

    private

    def create_remotes_handler
      @config['remote'] ||= {}
      collection = @config['remote'].map { |key, val| Remote.new(val.merge({ :name => "#{key}"})) }
      collection.instance_variable_set(:@owner_config, @config)
      def collection.<<(rem)
        # TODO: handle nested hash input
        rem_obj = rem.is_a?(Remote) ? rem : Remote.new(rem)
        @owner_config['remote'].merge!(rem_obj.to_hash)
        super(rem_obj)
      end

      collection
    end

  end
end
