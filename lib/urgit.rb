require 'zlib'
require 'digest/sha1'
require 'fileutils'
require 'logger'
require 'enumerator'
require 'stringio'

require 'urgit/version'
require 'urgit/config'
require 'urgit/util'
require 'urgit/gitobject'
require 'urgit/reference'
require 'urgit/blob'
require 'urgit/tree'
require 'urgit/tag'
require 'urgit/user'
require 'urgit/pack'
require 'urgit/commit'
require 'urgit/trie'
# require 'urgit/repository'

module Urgit
  class NotFound < StandardError; end
  class NoSuchShaFound < StandardError; end

  SHA_PATTERN = /^[A-Fa-f0-9]{5,40}$/
  REVISION_PATTERN = /^[\w\-\.]+([\^~](\d+)?)*$/
  DEFAULT_ENCODING = 'utf-8'

  # Returns the hash value of an object string.
  def sha(str)
    Digest::SHA1.hexdigest(str)[0, 40]
  end

  # Calculate the id for a given type and raw data string.
  def id_for(type, content)
    sha "#{type} #{content.length}\0#{content}"
  end

end
