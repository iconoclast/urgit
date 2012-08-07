#!/usr/bin/env ruby
# -*- mode: ruby; coding: utf-8 -*-

## urgit - a micro ruby git (partial) implementation

require 'urgit'
require 'urgit/util'

require 'fileutils'
require 'net/ssh'
require 'net/scp'
require 'uri/scp'

module Urgit

  ## Utility functions used by other classes for dealing with
  ## remote repositories and various push/pull related features.
  module PushMiPullYu

    # collect updates from a remote repository and bring them to this one
    def fetch(repository, remote_name, options = {})
      case repository
      when /^http:\/\//
        options[:ssl] = false
        fetch_over_http(repository, remote_name, options)
      when /^https:\/\//
        options[:ssl] = true
        fetch_over_http(repository, remote_name, options)
      when /^git:\/\//
        fetch_over_native_git(repository, remote_name, options)
      when /^file:\/\//
        fetch_over_filesystem(repository, remote_name, options)
      when /^([\w]+)\@([\w]+):([\S]+)/
        # todo: improve that regex
        options[:url] = repository
        options[:remote_name] = remote_name if remote_name
        fetch_over_ssh(options)
      when /^([^\s\@]+)\@([^\s\:]+):([\S]+)/
        # logger.warn "Sloppy regex caught what is assumed to be an ssh url."
        # raise?
        options[:url] = repository
        options[:remote_name] = remote_name if remote_name
        fetch_over_ssh(options)
      else
        raise "unknown or unsupported transport specified in fetch url (#{repository})"
      end
    end

    def fetch_over_http(repo_url, remote_name, options)
      raise "Sorry, http urls are not currently supported for fetch"
    end

    def fetch_over_native_git(repo_url, remote_name, options)
      raise "Sorry, native git urls are not currently supported for fetch"
    end

    def fetch_over_filesystem(repo_url, remote_name, options)
      # TODO: refactor this out from the ssh version
      raise "Sorry, file urls are not currently supported for fetch"
    end

    def fetch_over_ssh(remote)
      success = true

      # # parse the url for details
      # begin
      #   url = URI.parse repo_url
      # rescue URI::InvalidURIError
      #   url = URI.parse('ssh://' + repo_url)
      # end

      # user ||= url.user
      # host ||= url.host
      # path ||= url.path

      # unless pass
      #   (_, pass) = url.userinfo.split(':', 2) if url.userinfo
      # end

      # ssh_opts[:password] = pass if pass && !pass.empty?

      # TODO: parse remote[:fetch]

      # Net::SSH.start(host, user, ssh_opts) do |ssh|
      Net::SSH.start(*parse_ssh_options(remote)) do |ssh|

        refs = fetch_refs = nil
        sio = StringIO.new

        downloaded = scp_download!(ssh, "#{remote[:path]}/info/refs", sio)
        refs = sio.string.dup if downloaded

        unless refs
          # poor-mans info/refs via shell (unix only currently)
          cmd_results = ssh_exec!(ssh, "grep -r . #{remote[:path]}/refs")
          refs = cmd_results[:stdout] if cmd_results[:success]
        end

        fetch_refs = map_refs(refs) if refs

        raise NotFound "Could not fetch refs from the remote #{remote[:url]}" unless fetch_refs

        # TODO: write FETCH_HEAD
        sio.truncate(sio.rewind)
        head_downloaded = scp_download!(ssh, "#{remote[:path]}/HEAD", sio)
        remote_head = sio.string.dup
        if !(remote_head =~ /^ref: refs\//)
          # fetch_refs[remote_head] = false
        else
          success = remote_head.sub('ref: refs/heads/', '').strip
        end

        fetch_refs.each do |ref, sha|
          debug "fetching ref: #{ref} #{sha}"
          if ssh_fetch(ssh, remote[:path], sha)
            if ref
              old_sha = read_remotes_id(remote[:remote_name], ref)

              debug "write_remotes_id #{sha} , #{remote[:remote_name]} , #{ref}"
              write_remotes_id(sha, remote[:remote_name], ref) unless old_sha == sha
            end
          else
            success = false
          end
        end

      end # ssh
      success
    end # fetch_over_ssh


    def map_refs(refs)
      # process the refs file
      # get a list of all the refs/heads/
      fetch_refs = {}
      refs.split("\n").each do |ref|
        if ref =~ /\trefs\/heads/
          # heads from official info/refs
          sha, head = ref.split("\t")
        elsif ref =~ /refs\/heads\/.*:\h+/
          # heads from fake info/refs
          head, sha = ref.split(":", 2)
        else
          # not a head
          head = sha = nil
          next
        end

        if head && sha
          # fixme
          head = head.sub(/.*refs\/heads\//, '').strip
          debug "    setting fetch_refs[#{head}] = #{sha}"
          fetch_refs[head] = sha
        end
      end
      fetch_refs
    end

    def ssh_fetch(ssh, path, sha)
      head = sha[0..1]
      tail = sha[2..39]

      results = true
      local_path = object_path(sha)
      remote_path = "#{path}/objects/#{head}/#{tail}"
      debug "fetching #{sha}"
      # debug "  remote path #{remote_path}, local path #{local_path}"

      unless have_object? sha
        debug "  downloading"
        FileUtils.mkdir_p(File.dirname local_path)
        unless scp_download!(ssh, remote_path, local_path)
          # TODO: handle remote pack files
          debug "    ERROR downloading failed! for #{remote_path}, #{local_path}"
          return false
        end

        debug "  parsing"
        # Attempting to get() the object at this point will fail
        # due to references to objects still missing.
        # So, we manually parse the object data to extract what we need.
        return false unless File.exists? local_path
        raw =  File.open(local_path, 'rb') { |f| f.read }
        # debug "  read"

        return false unless legacy_loose_object? raw
        header, content = Zlib::Inflate.inflate(raw).split("\0", 2)
        type, size = header.split(' ', 2)
        # debug "  deflated"
        return false unless content.length == size.to_i
        # set_encoding(sha)

        debug "  recursing "
        case type
        when 'commit'
          debug "    commit"
          headers, _ = content.split("\n\n", 2)
          headers.split("\n").each do |header|
            key, value = header.split(' ', 2)
            set_encoding(value)

            if ['tree', 'parent'].include? key
              debug "      #{key} #{value}"
              results &&= ssh_fetch(ssh, path, value)
            end
          end

        when 'tree'
          # children = []
          debug "    tree"
          data = StringIO.new(content)
          while !data.eof?
            mode = Util.read_bytes_until(data, ' ').to_i(8)
            name = set_encoding Util.read_bytes_until(data, "\0")
            id   = set_encoding data.read(20).unpack("H*").first

            debug "      child #{id}"
            # children << id
            results &&= ssh_fetch(ssh, path, id)
          end
        end  # case type

      end  # have_object?
      debug "returning #{!!results}"
      return results
    end


    ### push

    # def push(repository, remote_name = nil, branch = self.branch, options = {})
    def push(options)
      options[:push_branch] ||= self.branch

      case options[:url]
      when /^http:\/\//
        options[:ssl] = false
        push_over_http(options)
      when /^https:\/\//
        options[:ssl] = true
        push_over_http(options)
      when /^git:\/\//
        push_over_native_git(repository, remote_name, options)
      when /^file:\/\//
        push_over_filesystem(repository, remote_name, options)
      when /^([\w\.-]+)\@([\w\.-]+):([\S]+)/
        # todo: improve that regex
        push_over_ssh(options)
      when /^([^\s\@]+)\@([^\s\:]+):([\S]+)/
        # logger.warn "Sloppy regex caught what is assumed to be an ssh url."
        # raise?
        push_over_ssh(options)
      else
        raise "unknown or unsupported transport specified in push url (#{options[:url]})"
      end
    end

    def push_over_http(options)
      raise "Sorry, http urls are not currently supported for push"
    end

    def push_over_native_git(options)
      raise "Sorry, native git urls are not currently supported for push"
    end

    def push_over_filesystem(options)
      raise "Sorry, file urls are not currently supported for push"
    end

    def push_over_ssh(opts)
      # TODO: handle pack files
      success = true

      # remote_ref = remote[:branches][branch][:merge]
      push_branch = opts[:push_branch]
      local_branch_id = read_branch_id(push_branch)
      remote_ref = opts[:merge] || "refs/heads/#{push_branch}"

      Net::SSH.start(*parse_ssh_options(opts)) do |ssh|

        # get remote head if it exists
        remote_head = File.join(opts[:path], remote_ref)
        remote_sha = scp_download!(ssh, remote_head)

        # calculate which objects need to be pushed
        sync_from = remote_sha || 'HEAD'
        # TODO: detect and handle non-fast-forward situations
        objects = sync_list(remote_sha).reverse rescue []

        # scp objects over to remote
        objects.each do |sha|
          local_path = object_path(sha)
          remote_path = local_path.sub(/^#{path}/, opts[:path])
          scp_upload!(ssh, local_path, remote_path)
        end

        # update remote head
        local_head = head_path
        debug "setting remote head"
        scp_upload!(ssh, local_head, remote_head)  ## fixme

      end
      success
    end

    protected

    def parse_orphan()
    end

    def parse_ssh_options(opts)

      if opts[:url]
        # parse the url for details
        begin
          url = URI.parse opts[:url]
        rescue URI::InvalidURIError
          url = URI.parse('ssh://' + opts[:url])
        end

        opts[:user] ||= url.user
        opts[:host_name] ||= url.host
        opts[:path] ||= url.path

        unless opts[:password]
          (_, opts[:password]) = url.userinfo.split(':', 2) if url.userinfo
        end
      end

      ssh_opts = Hash[ opts.select { |k,v| Net::SSH::VALID_OPTIONS.include? k } ]
      [ ssh_opts[:host_name], ssh_opts[:user], ssh_opts ]
    end


    # convenience method for running ssh commands and getting exit code, stderr, etc.
    def ssh_exec!(ssh, command)
      # Why isn't this the default, or at least built-in to Net::SSH ?
      result = {}
      result[:stdout] = ""
      result[:stderr] = ""
      ssh.open_channel do |channel|
        channel.exec(command) do |ch, success|
          unless success
            # abort "FAILED: couldn't execute command (ssh.channel.exec)"
            raise "Error: couldn't execute command via ssh: #{command}"
          end
          channel.on_data do |ch,data|
            result[:stdout] += data
          end

          channel.on_extended_data do |ch,type,data|
            result[:stderr] += data
          end

          channel.on_request("exit-status") do |ch,data|
            result[:exit_code] = data.read_long
            result[:success] = (result[:exit_code] == 0)
          end

          channel.on_request("exit-signal") do |ch, data|
            result[:exit_signal] = data.read_long
          end
        end
      end
      ssh.loop
      result
    end  # ssh_exec!

    # A convenience wrapper for scp download which returns false if the download fails
    def scp_download!(ssh, remote, local=nil, options={}, &progress)
      begin
        exists = ssh_exec!(ssh, "ls #{remote}")[:success]
        ssh.scp.download!(remote, local, options, &progress) if exists
      rescue Net::SSH::Exception, Net::SCP::Error, RuntimeError, ArgumentError => scp_err
        # ArgumentError will be seen if the remote file doesn't exist
        # however Net::SCP doesn't clean up after itself when that occurs.
        # TODO: cleanup without closing
        debug scp_err
        return false
      end
    end

    # A convenience wrapper for scp upload that ensures the parent directory is created first
    def scp_upload!(ssh, local, remote, options={}, &progress)
      ssh_exec!(ssh, "mkdir -p #{File.dirname(remote)}")
      ssh.scp.upload!(local, remote, options, &progress)
    end

    # Use the logger if one is defined in whatever object included this module
    def debug(msg)
      if $DEBUG
        self.respond_to?(:logger) ? self.logger.debug(msg) : $stderr.puts(msg)
      end
    end

  end
end
