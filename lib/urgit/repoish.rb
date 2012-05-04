require 'urgit'

module Urgit
  # a deliberate subset of Gitrb::Repository
  # sprinkled with some methods from git_store
  module Repoish
    # attr_reader :path, :root, :branch, :head, :encoding
    include Urgit

    if RUBY_VERSION > '1.9'
      def set_encoding(s); s.force_encoding(@encoding); end
    else
      def set_encoding(s); s; end
    end

    # Initialize a repository.
    # def initialize(options = {})
    #   @bare    = options[:bare] || false
    #   @branch  = options[:branch] || 'master'
    #   @logger  = options[:logger] || Logger.new(nil)
    #   @encoding = options[:encoding] || DEFAULT_ENCODING

    #   @path = options[:path].chomp('/')
    #   @path += '/.git' if !@bare

    #   check_git_version if !options[:ignore_version]
    #   open_repository(options[:create])

    #   load_packs
    #   load
    # end

    # todo: delegate to root

    def config
      @config ||= path ? Config.new(self) : nil
    end


    # Read an object for the specified path.
    def get_object(path)
      root.get(path)
    end

    # Read a value for the specified path.
    def [](path)
      root[path]
    end

    # Write data to the specified path.
    def []=(path, data)
      root[path] = data
    end

    # Iterate over all key-values pairs found in this store.
    def each(&block)
      root.each(&block)
    end

    # def paths
    #   root.paths
    # end

    # Returns all names/paths found in this store.
    def names
      root.names
    end

    # Returns all values found in this store.
    def values
      root.values
    end

    # Remove given path from store.
    def delete(path)
      root.delete(path)
    end

    # Find or create a tree object with given path.
    def tree(path)
      root.tree(path)
    end

    # Has the tree has been modified?
    def modified?
      root.modified?
    end

    # Returns the store as a nested hash.
    def to_hash
      root.to_hash
    end

    # Return a hash consisting of leaf object values with full paths for keys
    def to_path_values
      root.to_path_values({},['']) # empty string passed for initial path_parts to obtain leading '/'
    end

    # Inspect the store.
    def inspect
      "#<Git #{path} #{branch}>"
    end

    def dup
      super.instance_eval do
        @objects = Trie.new
        load
        self
      end
    end

    # Bare repository?
    def bare?
      @bare
    end

    # Returns an array of remotes listed in the configuration file.
    # This may differ from what exists under 'refs/remotes'.
    def remotes
      # only return config_remotes
      # known_remotes = []
      # unpacked = Dir.chdir "#{path}/refs/remotes" do
      #   Dir.glob("**/*").select { |fn| File.file?(fn) }
      # end
      # packed = read_packed_refs('refs/remotes/').keys.map { |r| r }
      config.remotes
    end

    # A list of branches that already exist in the repo
    def branches
      Dir.chdir "#{path}/refs/heads" do
        Dir.glob("**/*").select { |fn| File.file?(fn) }
      end
    end

    # Set target branch
    def branch=(branch)
      @branch = branch
      load
    end

    # Switch to a new branch
    def switch_branch(branch)
      @branch = branch
      clear # which also performs load
    end

    # Has our repository been changed on disk?
    def changed?
      !head || head.id != read_head_id
    end

    # Load the repository, if it has been changed on disk.
    def refresh
      load if changed?
    end

    # Clear cached objects
    def clear
      @objects.clear
      load
    end

    # Returns an array of parent ids
    def parent_ids
      ([head] + parent_list).map(&:id)
    end

    # Set additional parent for the next commit of the current tree
    def add_parent(new_parent)
      new_parent = get(new_parent) if new_parent.is_a? String
      return false unless Commit === new_parent

      unless parent_list.include? new_parent or new_parent.id == head.id
        parent_list << new_parent
      end
    end

    # Difference between versions
    # Options:
    #   :to             - Required target commit
    #   :from           - Optional source commit (otherwise comparision with empty tree)
    #   :path           - Restrict to path/or paths
    #   :detect_renames - Detect renames O(n^2)
    #   :detect_copies  - Detect copies O(n^2), very slow
    def diff(opts)
      from, to = opts[:from], opts[:to]
      if from && !(Commit === from)
        raise ArgumentError, "Invalid sha: #{from}" if from !~ SHA_PATTERN
        from = Reference.new(:repository => self, :id => from)
      end
      if !(Commit === to)
        raise ArgumentError, "Invalid sha: #{to}" if to !~ SHA_PATTERN
        to = Reference.new(:repository => self, :id => to)
      end

      ## FIXME
      raise NotImplementedError "Sorry, we still need to reimplement diff-tree."
      # Diff.new(from, to, git_diff_tree('--root', '--full-index', '-u',
      #                                  opts[:detect_renames] ? '-M' : nil,
      #                                  opts[:detect_copies] ? '-C' : nil,
      #                                  from ? from.id : nil, to.id, '--', *opts[:path]))
    end

    # All changes made inside a transaction are atomic. If some
    # exception occurs the transaction will be rolled back.
    #
    # Example:
    #   repository.transaction { repository['a'] = 'b' }
    #
    # def transaction(message = '', author = nil, committer = nil)
    #   lock = File.open("#{head_path}.lock", 'w')
    #   lock.flock(File::LOCK_EX)
    #   refresh

    #   result = yield
    #   commit(message, author, committer)
    #   result
    # rescue
    #   @objects.clear
    #   load
    #   raise
    # ensure
    #   lock.close rescue nil
    #   File.unlink("#{head_path}.lock") rescue nil
    # end

    # Write a commit object to disk and set the head of the current branch.
    #
    # Returns the commit object
    def commit!(message = '', author = nil, committer = nil)
      author ||= default_user
      committer ||= author
      root.save

      commit = Commit.new(:repository => self,
                          :tree => root,
                          :parents => head,
                          :author => author,
                          :committer => committer,
                          :message => message)

      commit.parents.concat parent_list.slice!(0..-1)
      commit.save

      write_head_id(commit.id)
      load

      commit
    end

    # Create a new commit only if the tree has been modified
    def commit(*args)
      commit!(*args) if root.modified?
    end

    # Returns a list of commits starting from head commit.
    def commits(limit = 10, start = head)
      entries = []
      current = start

      while current and entries.size < limit
        entries << current
        current = get(current.parents.first)
      end

      entries
    end

    # Returns a log formatted list of commits starting from head commit.
    # Options:
    #   :path      - Restrict to path/or paths
    #   :max_count - Maximum count of commits
    #   :skip      - Skip n commits
    #   :start     - Commit to start from
    def log(opts = {})
      max_count = opts[:max_count]
      skip = opts[:skip]
      start = opts[:start]
      raise ArgumentError, "Invalid commit: #{start}" if start.to_s =~ /^\-/

      ## FIXME
      raise NotImplementedError "Sorry, we still need to reimplement log retrieval."

      # log = git_log('--pretty=tformat:%H%n%P%n%T%n%an%n%ae%n%at%n%cn%n%ce%n%ct%n%x00%s%n%b%x00',
      #               skip ? "--skip=#{skip.to_i}" : nil,
      #               max_count ? "--max-count=#{max_count.to_i}" : nil, start, '--', *opts[:path]).split(/\n*\x00\n*/)
      # ...
      commits = []
      log.each_slice(2) do |data, message|
        data = data.split("\n")
        parents = data[1].empty? ? nil : data[1].split(' ').map {|id| Reference.new(:repository => self, :id => id) }
        commits << Commit.new(:repository => self,
                              :id => data[0],
                              :parents => parents,
                              :tree => Reference.new(:repository => self, :id => data[2]),
                              :author => User.new(data[3], data[4], Time.at(data[5].to_i)),
                              :committer => User.new(data[6], data[7], Time.at(data[8].to_i)),
                              :message => message.strip)
      end
      commits
    rescue CommandError => ex
      return [] if ex.output =~ /bad default revision 'HEAD'/i
      raise
    end

    # Create a 'simple tag' at the current head.
    def simple_tag(tag_name)
      write_simple_tag(head.id, tag_name)
    end

    # Create a 'simple tag' at the current head replacing any that may already exist with the same name.
    def simple_tag!(tag_name)
      write_simple_tag(head.id, tag_name, true)
    end

    # Get an object by its id.
    #
    # Returns a tree, blob, commit or tag object.
    def get(id)
      return nil if id.nil?
      return id if (GitObject === id || Reference === id)

      raise ArgumentError, "Invalid id given: #{id} (#{id.class.to_s})" if !(String === id)

      if id =~ SHA_PATTERN
        raise ArgumentError, "Sha too short: #{id}" if id.length < 5

        trie = @objects.find(id)
        raise NotFound, "Sha is ambiguous: #{id}" if trie.size > 1
        return trie.value if !trie.empty?
      elsif id =~ REVISION_PATTERN
        # FIXME: rev-parse in ruby needed!
        # list = git_rev_parse(id).split("\n") rescue nil
        # raise NotFound, "Revision not found: #{id}" if !list || list.empty?
        # raise NotFound, "Revision is ambiguous: #{id}" if list.size > 1
        # id = list.first

        # ok, if we don't have rev-parse, let's at least get the easy ones manually
        if id == 'HEAD'
          id = read_head_id
        else
          branch_head = read_branch_id(id)
          id = branch_head if branch_head
        end

        trie = @objects.find(id)
        raise NotFound, "Sha is ambiguous: #{id}" if trie.size > 1
        return trie.value if !trie.empty?

        raise NotFound, "Sorry, rev-parse hasn't been completely reimplemented yet."
      else
        raise ArgumentError, "Invalid id given: #{id}"
      end

      @logger.debug "urgit: Loading #{id}"

      path = object_path(id)
      if File.exists?(path) || (glob = Dir.glob(path + '*')).size >= 1
        if glob
          raise NotFound, "Sha is ambiguous: #{id}" if glob.size > 1
          path = glob.first
          id = path[-41..-40] + path[-38..-1]
        end

        buf = File.open(path, 'rb') { |f| f.read }

        raise NotFound, "Not a loose object: #{id}" if !legacy_loose_object?(buf)

        header, content = Zlib::Inflate.inflate(buf).split("\0", 2)
        type, size = header.split(' ', 2)

        raise NotFound, "Bad object: #{id}" if content.length != size.to_i
      else
        trie = @packs.find(id)
	raise NotFound, "Object not found: #{id}" if trie.empty?
	raise NotFound, "Sha is ambiguous: #{id}" if trie.size > 1
        id = trie.key
        pack, offset = trie.value
        content, type = pack.get_object(offset)
      end

      @logger.debug "urgit: Loaded #{type} #{id}"

      set_encoding(id)
      object = GitObject.factory(type, :repository => self, :id => id, :data => content)
      @objects.insert(id, object)
      object
    end

    def get_tree(id)   get_type(id, :tree) end
    def get_blob(id)   get_type(id, :blob) end
    def get_commit(id) get_type(id, :commit) end

    # Write a raw object to the repository.
    #
    # Returns the object.
    def put(object)
      raise ArgumentError unless object
      object = Blob.new(object) unless object.is_a? GitObject #  === GitObject

      content = object.dump
      data = "#{object.type} #{content.bytesize rescue content.length}\0#{content}"
      id = Digest::SHA1.hexdigest(data)
      path = object_path(id)

      @logger.debug "urgit: Storing #{id}"

      if !File.exists?(path)
        FileUtils.mkpath(File.dirname(path))
        File.open(path, 'wb') do |f|
          f.write Zlib::Deflate.deflate(data)
        end
      end

      @logger.debug "urgit: Stored #{id}"

      set_encoding(id)
      object.repository = self
      object.id = id
      @objects.insert(id, object)

      object
    end

    # def method_missing(name, *args)
    #   cmd = name.to_s
    #   if cmd[0..3] == 'git_'
    #     cmd = cmd[4..-1].tr('_', '-')
    #     args = args.flatten.compact.map {|a| a.to_s }

    #     @logger.debug "urgit: #{self.class.git_path} #{cmd} #{args.inspect}"

    #     out = IO.popen('-', 'rb') do |io|
    #       if io
    #         # Read in binary mode (ascii-8bit) and convert afterwards
    #         block_given? ? yield(io) : set_encoding(io.read)
    #       else
    #         # child's stderr goes to stdout
    #         STDERR.reopen(STDOUT)
    #         ENV['GIT_DIR'] = path
    #         exec(self.class.git_path, cmd, *args)
    #       end
    #     end

    #     if $?.exitstatus > 0
    #       return '' if $?.exitstatus == 1 && out == ''
    #       raise CommandError.new("git #{cmd}", args, out)
    #     end

    #     out
    #   else
    #     super
    #   end
    # end

    def default_user
      @default_user ||= begin
        name = git_config('user.name').chomp
        email = git_config('user.email').chomp
        name = ENV['USER'] if name.empty?
        email = ENV['USER'] + '@' + `hostname -f`.chomp if email.empty?
        User.new(name, email)
      end
    end

    private

    # def check_git_version
    #   version = git_version
    #   raise "Invalid git version: #{version}" if version !~ /^git version ([\d\.]+)$/
    #   a = $1.split('.').map {|s| s.to_i }
    #   b = MIN_GIT_VERSION.split('.').map {|s| s.to_i }
    #   while !a.empty? && !b.empty? && a.first == b.first
    #     a.shift
    #     b.shift
    #   end
    #   raise "Minimum required git version is #{MIN_GIT_VERSION}" if a.first.to_i < b.first.to_i
    # end

    # def open_repository(create)
    #   if create && !File.exists?("#{@path}/objects")
    #     FileUtils.mkpath(@path) if !File.exists?(@path)
    #     raise ArgumentError, "Not a valid Git repository: '#{@path}'" if !File.directory?(@path)
    #     git_init(@bare ? '--bare' : nil)
    #   else
    #     raise ArgumentError, "Not a valid Git repository: '#{@path}'" if !File.directory?("#{@path}/objects")
    #   end
    # end

    def parent_list
      @parent_list ||= []
    end

    def get_type(id, expected)
      object = get(id)
      raise NotFound, "Wrong type #{object.type}, expected #{expected}" if object && object.type != expected
      object
    end

    def load_packs
      @packs   = Trie.new
      @objects = Trie.new

      packs_path = "#{@path}/objects/pack"
      if File.directory?(packs_path)
        Dir.open(packs_path) do |dir|
          entries = dir.select { |entry| entry =~ /\.pack$/i }
          entries.each do |entry|
            @logger.debug "urgit: Loading pack #{entry}"
            pack = Pack.new(File.join(packs_path, entry))
            pack.each_object {|id, offset| @packs.insert(id, [pack, offset]) }
          end
        end
      end
    end

    def load
      if id = read_head_id
        @head = get_commit(id)
        @root = @head.tree
      else
        @head = nil
        @root = Tree.new(:repository => self)
      end
      @logger.debug "urgit: Reloaded, head is #{@head ? @head.id : 'nil'}"
    end

    # Returns the path to the current head file.
    def head_path
      "#{path}/refs/heads/#{branch}"
    end

    # Returns the path to the object file for given id.
    def object_path(id)
      "#{path}/objects/#{id[0...2]}/#{id[2..39]}"
    end

    # Read the id of the head commit.
    #
    # Returns the object id of the last commit.
    def read_head_id
      File.exists?(head_path) ? File.read(head_path).strip : read_one_packed_refs_id("refs/heads/#{branch}")
    end

    def write_head_id(id)
      write_refs_id(id, 'heads', @branch)
    end

    def write_branch_id(id, branch_name = @branch)
      write_refs_id(id, 'heads', branch_name)
    end

    def write_simple_tag(id, tag_name, force=nil)
      return if !force && File.exists?("#{path}/refs/tags/#{tag_name}")
      write_refs_id(id, 'tags', tag_name)
    end

    def write_refs_id(id, type, name)
      ref_path = "#{path}/refs/#{type}/#{name}"
      FileUtils.mkdir_p(File.dirname(ref_path))
      File.open(ref_path, 'wb') {|file| file.write(id) }
    end

    def legacy_loose_object?(buf)
      buf[0].ord == 0x78 && ((buf[0].ord << 8) | buf[1].ord) % 31 == 0
    end

    def read_branch_id(branch_name = @branch)
      branch_ref = "refs/heads/#{branch_name}"
      heads_path = "#{path}/#{branch_ref}"
      File.exists?(heads_path) ? File.read(heads_path).strip : read_one_packed_refs_id(branch_ref)
    end

    def read_packed_refs(filter = nil)
      return nil unless File.exists?("#{path}/packed-refs")
      refs = {}
      File.open("#{path}/packed-refs", 'rb') do |io|
        io.each do |line|
          line.strip!
          next if line[0..0] == '#'
          (sha, name) = line.split(' ')
          refs[name] = sha if filter.nil? || name[filter]
        end
      end
      refs
    end

    def read_one_packed_refs_id(filter, exact = true)
      return nil unless File.exists?("#{path}/packed-refs")
      File.open("#{path}/packed-refs", 'rb') do |io|
        io.each do |line|
          line.strip!
          next if line[0..0] == '#'
          (sha, name) = line.split(' ')
          return sha if (exact ? name == filter : name[filter])
        end
      end
      nil # nothing found, so return nil instead of a closed file handle
    end

  end
end
