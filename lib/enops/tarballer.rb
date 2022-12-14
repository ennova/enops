require 'enops/utils'
require 'rubygems/package'
require 'stringio'
require 'zlib'

module Enops
  class Tarballer
    def initialize
      reset
    end

    def reset
      close
      @io = StringIO.new
      @io.binmode
      @tar = Gem::Package::TarWriter.new(@io)
    end

    def close
      @tar.close if @tar
      @tar = nil
    end

    def gzipped_result
      close
      Zlib.gzip(@io.string)
    end

    def add_file(path, mode = nil, content = nil)
      unless content
        content ||= File.read(path, external_encoding: 'binary')
        mode ||= File.stat(path).mode
      end

      @tar.add_file Utils.basepath(path), mode do |io|
        io.write content
      end
    end
  end
end
