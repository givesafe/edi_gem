# frozen_string_literal: true

require "fileutils"

module EdiGem
  class Archive
    # The local filesystem, with the same layout as S3. Writes PHI in the clear: point it only
    # at a directory that is not backed up, synced or shared.
    class Local < Archive
      def put(path, body)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        "file://#{File.expand_path(path)}"
      end
    end
  end
end
