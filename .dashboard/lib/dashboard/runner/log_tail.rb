# frozen_string_literal: true

module Dashboard
  class Runner
    # Reads a child's log (its stdout+stderr, appended) as lines while it runs,
    # and keeps the file on its tmpfs small. The child writes with O_APPEND, so
    # emptying the file in place is safe: its next write lands at 0, where
    # reading goes on.
    # - Read past the limit and caught up: emptied. A write landing between
    #   the last read and the truncate is lost (rare: a line or so).
    # - The file reaches twice the limit while the child runs (it writes faster
    #   than its reader consumes): emptied, the unread part dropped.
    #   The size is looked at (one fstat) after every read and every CHECK
    #   seconds of consuming, so the file peaks at twice the limit plus what
    #   the child writes between two looks: about a millisecond's worth while
    #   it writes on, up to POLL seconds' worth when it starts after a pause.
    # - The child gone with more than the limit unread: only the last limit's
    #   worth is read, from the next line start, so the drain is bounded.
    # Dropped output shows as one DROPPED line; a half line before it is discarded.
    class LogTail
      # Longest sleep on a log with nothing new in it. Sleeps start at CHECK
      # after output and double while none comes, so a child that writes
      # without pause never gets POLL seconds of writing unlooked-at.
      POLL = 0.1
      # Bytes asked of the log per read.
      READ = 65_536
      # Seconds of consuming lines between looks at the log's size.
      CHECK = 0.001
      DROPPED = "… output dropped (log over %s MiB)"

      # io: the log, open read-write at where reading starts; alive: → whether the child still runs.
      def initialize(io, limit, alive)
        @io = io
        @limit = limit
        @alive = alive
        @buffer = String.new(encoding: Encoding::BINARY)
        @dropped = nil # the size crossed, until its marker is out
        @skip = false  # read from mid-line: drop up to the next newline
        @checked = 0
        @nap = CHECK
        @shown = "".b # the unfinished line last passed to `partial`
      end

      # Yields each line (bytes, without the newline; MAX_LINE bytes at most,
      # so a long run without one is cut) until the child has exited and the
      # log is read. Closes the log. partial: ->(bytes), told the text after the
      # last newline whenever it changes ("" once it is a line), so a reader can
      # show output that has no line end yet (test dots, prompts).
      def each_line(partial: nil, &)
        loop do
          exited = !@alive.call
          chunk = @io.read(READ)
          chunk = skip_partial(chunk) if chunk && @skip
          check # before the first line: after a POLL the log may have grown a lot
          feed(chunk, &) if chunk
          marker(&)
          trim
          show(partial, @buffer)
          if chunk
            @nap = CHECK
            next
          end
          break if exited

          sleep @nap
          @nap = [@nap * 2, POLL].min
        end
        yield @buffer unless @buffer.empty?
        show(partial, "".b)
      ensure
        @io.close
      end

      private

      def show(partial, text)
        return if partial.nil? || text == @shown

        @shown = text.dup
        partial.(@shown.dup)
      end

      def feed(chunk, &)
        @buffer << chunk
        start = 0
        while (newline = @buffer.index("\n", start))
          yield @buffer.byteslice(start, newline - start).chomp
          start = newline + 1
          check if now - @checked >= CHECK
        end
        @buffer = @buffer.byteslice(start..)
        marker(&)
        yield @buffer.slice!(0, MAX_LINE) while @buffer.bytesize >= MAX_LINE
      end

      def check
        @checked = now
        size = @io.size
        if !@alive.call
          drop(@limit) { @io.seek(size - @limit) } if size - @io.pos > @limit
        elsif size >= 2 * @limit
          drop(2 * @limit) do
            @io.truncate(0)
            @io.seek(0)
          end
        end
      end

      def drop(over)
        yield
        @skip = @io.pos.positive?
        @dropped = over
      end

      # After a drop: what is buffered past the last whole line belongs to the dropped part.
      def marker
        return unless @dropped

        @buffer.clear
        yield format(DROPPED, format("%g", @dropped / 1_048_576.0)).b
        @dropped = nil
      end

      def skip_partial(chunk)
        newline = chunk.index("\n")
        return "".b unless newline

        @skip = false
        chunk.byteslice((newline + 1)..)
      end

      # Read past the limit and caught up: empty it.
      def trim
        return unless @io.pos >= @limit && @io.pos >= @io.size

        @io.truncate(0)
        @io.seek(0)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
