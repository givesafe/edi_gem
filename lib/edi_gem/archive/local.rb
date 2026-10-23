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

      # A read the system says to try again (interrupted, busy, timed out) is retryable. Every
      # other failure, a missing file or a refused permission included, will not pass by asking
      # again without something changing, and is not.
      RETRYABLE_ERRORS = [Errno::EAGAIN, Errno::EINTR, Errno::EBUSY, Errno::ETIMEDOUT].freeze

      def fetch(uri)
        File.binread(path_of(uri))
      rescue SystemCallError => error
        raise ArchiveFailed.new("#{uri} could not be read (#{error.class})",
                                retryable: RETRYABLE_ERRORS.any? { |kind| error.is_a?(kind) })
      end

      # As for S3: a uri this archive did not make is not retryable.
      # Reads the uri's text.
      # :reek:FeatureEnvy
      def path_of(uri)
        text = uri.to_s
        raise ArchiveFailed, "#{uri} is not a local archive's" unless text.start_with?("file://")

        text.delete_prefix("file://")
      end
    end
  end
end
