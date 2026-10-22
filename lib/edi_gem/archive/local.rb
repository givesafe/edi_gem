# frozen_string_literal: true

require "fileutils"

module EdiGem
  class Archive
    # The local filesystem, with the same layout as S3. Writes PHI in the clear: point it only
    # at a directory that is not backed up, synced or shared.
    class Local < Archive
      def put(path, body)
        FileUtils.mkdir_p(File.dirname(path))
        # The bytes as received: an app that sets Encoding.default_internal (Rails) would otherwise
        # transcode a body holding a byte outside its declared encoding, and fail.
        File.binwrite(path, body)
        "file://#{File.expand_path(path)}"
      end

      def fetch(uri)
        raise ArgumentError, "#{uri} is not a local archive's" unless uri.to_s.start_with?("file://")

        File.binread(uri.to_s.delete_prefix("file://"))
      rescue SystemCallError => error
        raise ArchiveFailed, "#{uri} could not be read (#{error.class})"
      end
    end
  end
end
