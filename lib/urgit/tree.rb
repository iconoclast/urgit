module Urgit

  class Tree < GitObject
    include Enumerable

    attr_accessor :repository, :data
    attr_reader :mode

    # Initialize a tree
    def initialize(options = {})
      super(options)
      @children = {}
      @mode = options[:mode] || 040000
      parse(options[:data]) if options[:data]
      @modified = true if !id
    end

    def type
      :tree
    end

    # Set mode
    def mode=(mode)
      if mode != @mode
        @mode = mode
        @modified = true
      end
    end

    # Set new repository (modified flag is reset)
    def id=(id)
      @modified = false
      super
    end

    # Has this tree been modified?
    def modified?
      @modified || @children.values.any? {|child| (!(Reference === child) || child.resolved?) && child.modified? }
    end

    # Find or create a subtree with specified name.
    #def tree(name)
    #  get(name) or put(name, Tree.new(store))
    #end

    # Find or create a subtree with specified name.
    def subtree(name)
      get(name) or sprout(name)
    end

    # Convenience method for producing new empty subtree entries in the repo
    def sprout(name)  # :nodoc:
      @modified = true
      @children[name] = repository.put(Tree.new(:repository => repository))
    end

    def dump
      sorted_children.map do |name, child|
	child.save if !(Reference === child) || child.resolved?
        "#{child.mode.to_s(8)} #{name}\0#{repository.set_encoding [child.id].pack("H*")}"
      end.join
    end

    # Save this tree back to the git repository.
    #
    # Returns the object id of the tree.
    def save
      repository.put(self) if modified?
      id
    end

    # Are there no children?
    def empty?
      @children.empty?
    end

    # Number of children
    def size
      @children.size
    end

    # Does this key exist in the children?
    def exists?(name)
      self[name] != nil
    end

    # Read a value on specified path.
    # def [](path)
    #   normalize_path(path).inject(self) do |tree, key|
    #     tree.get(key) or return nil
    #   end
    # end

    # Read an entry and return it's object
    def get(path)
      path = normalize_path(path)
      return self if path.empty?
      entry = @children[path.first]
      if path.size == 1
        entry
      elsif entry
        raise 'Not a tree' if entry.type != :tree
        # entry[path[1..-1]]
        entry.get(path[1..-1])
      end
    end

    # Read entry and return it's value
    def [](name)

      entry = normalize_path(name).inject(self) do |tree, key|
        tree.get(key) or return nil
      end
      # entry = @children[name]

      case entry
      when Blob
        # entry.object ||= handler_for(name).read(entry.data)
        entry.object ||= entry.data
      when Tree
        entry
      end
    end

    # Write an entry on specified path.
    # def []=(path, value)
    #  list = normalize_path(path)
    #  tree = list[0..-2].to_a.inject(self) { |tree, name| tree.subtree(name) }
    #  tree.put(list.last, value)
    #end

    def []=(path, entry)
      raise ArgumentError unless entry #  && (Reference === entry || GitObject === entry)
      unless (Reference === entry || GitObject === entry)
        if entry.is_a?(Hash)
          # TODO: warn about keys that contain '/'
          entry.each { |key,value| self["#{path}/#{key}"] = value }
          return self[path]
        else
          entry = Blob.new(entry)
        end
      end

      path = normalize_path(path)
      if path.empty?
        raise 'Empty path'
      elsif path.size == 1
        raise 'No blob or tree' if entry.type != :tree && entry.type != :blob
        entry.repository = repository
        @modified = true
        @children[path.first] = entry
      else
        tree = @children[path.first]
        if !tree
          tree = @children[path.first] = Tree.new(:repository => repository)
          @modified = true
        end
        raise "Not a tree, #{tree.type.to_s}" if tree.type != :tree
        tree[path[1..-1]] = entry
      end
    end

    # Delete an entry on specified path.
    def delete(path)
      path = normalize_path(path)
      if path.empty?
        raise 'Empty path'
      elsif path.size == 1
        child = @children.delete(path.first)
        @modified = true if child
        child
      else
        tree = @children[path.first]
        return if tree.nil?
        raise 'Not a tree' if tree.type != :tree
        tree.delete(path[1..-1])
      end
    end

    # Move a entry
    def move(path, dest)
      self[dest] = delete(path)
    end

    # Iterate over all children
    def each(&block)
      sorted_children.each do |name, child|
        yield(name, child)
      end
    end

    # Iterate over all objects stored in this tree
    #def each_blob(&block)
    #  sorted_children.each do |name, child|
    #    yield(name, child)
    #  end
    #end


    def names
      map {|name, child| name }
    end

    def values
      map {|name, child| child }
    end

    alias children values

    # Convert this tree into a nested hash object.
    def to_hash
      @children.inject({}) do |hash, (name, entry)|
        if entry.is_a?(Tree)
          hash[name] = entry.to_hash
        else
          hash[name] = entry.object ||= entry.data
        end
        hash
      end
    end

    # Return a hash consisting of leaf object values with full paths for keys
    def to_path_values(collector = {}, path_parts = [])
      @children.each do |name, entry|
        path_parts << name
        case entry
        when Tree
          entry.to_path_values(collector, path_parts)
        else
          collector[path_parts.join('/')] = entry.object ||= entry.data
          path_parts.pop
        end
      end
      path_parts.pop
      collector
    end

    # Walks the children and returns a list of object ids
    def object_ids
      @children.inject([self.id]) do |list, (name, entry)|
        if entry.is_a?(Tree)
          list.concat entry.object_ids
        else
          list << entry.id
        end
        list
      end
    end

    private

    def sorted_children
      @children.map do |name, child|
        [name + (child.type == :tree ? '/' : "\0"), name, child]
      end.sort.map {|_, name, child| [name, child] }
    end

    def normalize_path(path)
      return path if Array === path
      path = path.to_s.gsub(%r{//}, '/')
      (path[0, 1] == '/' ? path[1..-1] : path).split('/')
    end

    # Read the contents of a raw git object.
    def parse(data)
      @children.clear
      data = StringIO.new(data)
      while !data.eof?
        mode = Util.read_bytes_until(data, ' ').to_i(8)
        name = repository.set_encoding Util.read_bytes_until(data, "\0")
        id   = repository.set_encoding data.read(20).unpack("H*").first
        # @children[name] = Reference.new(:repository => repository, :id => id, :mode => mode)
        @children[name] = repository.get(id)
      end
    end

  end

end
