# frozen_string_literal: true

module Dashboard
  # Reads a file a container can write (status files, .unit-env, the git
  # config): a FIFO must not block, a symlink must not lead elsewhere, and a
  # huge file must not exhaust memory.
  module SafeFile
    LIMIT = 1024 * 1024

    # Not a regular file, or larger than the limit.
    class Refused < Error; end

    # → the bytes (BINARY). Raises Refused, or SystemCallError when it cannot
    # be opened (gone, a symlink: ELOOP).
    def self.read(path, limit: LIMIT)
      raise Refused, "#{path}: not a regular file" unless File.lstat(path).file?

      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |f|
        raise Refused, "#{path}: not a regular file" unless f.stat.file?

        data = f.read(limit + 1) || +""
        raise Refused, "#{path}: larger than #{limit} bytes" if data.bytesize > limit

        data
      end
    end
  end
end
