module Urgit

  class Remote
    attr_accessor :name, :url, :head, :fetch, :push

    def initialize(attributes = {})
      # TODO: handle nested hashes read from config files
      # attributes.each do |attr, value|
      #   if value.is_a? Hash
      #     { :name => attr }.merge(value) }
      #   end
      # end
      attributes.each { |attr, value| send("#{attr}=", value) }
    end

    def branches
      @branches ||= []
    end

    # Format this remote for use as a Urgit::Config nested hash
    def to_hash
      # using strings for keys to match hashes read from a config file.
      # TODO: consider HashWithIndifferentAccess
      attributes = { 'url' => @url, 'head' => @head, 'fetch' => @fetch, 'push' => @push  }
      { "#{@name}" => attributes.reject { |k,v| v.nil? } }
    end

  end
end
