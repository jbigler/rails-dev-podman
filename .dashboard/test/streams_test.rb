# frozen_string_literal: true

require "test_helper"
require "rack/lint"
require "rack/mock_request"

# Hub events as Turbo Stream frames, sent over the /events SSE stream.
class StreamsTest < Minitest::Test
  S = Dashboard::Streams
  HOST = { "HTTP_HOST" => "wt.localhost:7700" }.freeze

  # What a streaming body writes, for a test to wait on; after #close every write
  # raises, as a disconnected client's stream does.
  class StreamDouble
    def initialize
      @lock = Mutex.new
      @changed = ConditionVariable.new
      @output = +""
      @closed = false
    end

    def write(chunk)
      @lock.synchronize do
        raise IOError, "closed stream" if @closed

        @output << chunk
        @changed.broadcast
      end
      chunk.bytesize
    end

    def <<(chunk) = tap { write(chunk) }
    def read(*) = nil
    def flush = self
    def close_read = nil
    def close_write = close
    def close = @lock.synchronize { @closed = true } && nil
    def closed? = @lock.synchronize { @closed }

    # The output once it contains `text`, nil after `timeout` seconds without it.
    def wait_for(text, timeout: 1)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        until @output.include?(text)
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil unless left.positive?

          @changed.wait(@lock, left)
        end
        @output.dup
      end
    end
  end

  class FakeGithub
    attr_reader :hints

    def initialize = @hints = []
    def hint(kind) = @hints << kind
  end

  def hub = @hub ||= Dashboard::Hub.new(ws, raw: @raw || fixture_raw)
  def state = hub.snapshot
  def sub(viewing) = Dashboard::Subscription.new(viewing)

  def app(github: nil)
    Rack::Lint.new(Dashboard::App.build(hub:, runner: nil, token: "t", port: 7700, ws:, github:, repo: "example-org/app"))
  end

  # The only frame of `frames`.
  def one(frames)
    assert_equal 1, frames.size
    frames.first
  end

  def git(dirty) = Dashboard::GitInfo.new(ahead: 0, behind: 0, upstream: "origin", dirty_count: dirty)

  def test_sse_framing
    assert_equal "data: <a>\ndata: <b>\n\n", S.sse("<a>\n<b>")
  end

  def test_detail_frame_targets_detail
    frames = S.frames([:detail, "wt-stacked"], state, sub("wt-stacked"))
    assert_equal 1, frames.size
    assert_includes frames.first, 'action="replace" target="detail"'
    assert_includes frames.first, "◀ HEAD"
  end

  def test_vanished_worktree
    frames = S.frames([:gone, "wt-01"], state, sub("wt-01"))
    assert_equal 1, frames.size
    assert_includes frames.first, 'action="replace" target="detail"'
    assert_includes frames.first, "worktree removed"
    hub.apply(:worktrees, fixture_raw.refs.reject { it.name == "wt-01" })
    response = Rack::MockRequest.new(app).get("/w/wt-01", HOST)
    assert_equal 302, response.status
    assert_equal "/", response.headers["location"]
  end

  def test_row_frame_replaces_the_row_and_marks_the_viewed_one
    frame = one(S.frames([:row, "wt-stacked"], state, sub("wt-stacked")))
    assert_includes frame, 'action="replace" target="row-wt-stacked"'
    assert_includes frame, 'aria-current="page"'
    refute_includes one(S.frames([:row, "wt-stacked"], state, sub("wt-01"))), "aria-current"
  end

  def test_added_or_removed_worktree_replaces_the_list
    listed = state.worktrees.map(&:name)
    hub.apply(:worktrees, fixture_raw.refs.reject { it.name == "wt-01" })
    frame = one(S.frames([:row, "wt-01"], state, sub("wt-02"), listed:))
    assert_includes frame, 'action="replace" target="worktrees"'
    refute_includes frame, 'id="row-wt-01"'
    assert_includes frame, 'id="row-wt-02"'
    hub.apply(:worktrees, fixture_raw.refs)
    frame = one(S.frames([:row, "wt-01"], state, sub("wt-02"), listed: listed - ["wt-01"]))
    assert_includes frame, 'action="replace" target="worktrees"'
    assert_includes frame, 'id="row-wt-01"'
  end

  def test_header_frame_shows_the_repo
    frame = one(S.frames([:header], state, sub(nil), repo: "example-org/app"))
    assert_includes frame, 'action="replace" target="header"'
    assert_includes frame, '<span class="repo">example-org/app</span>'
  end

  def test_notify_frame_escapes_the_agent_message
    claude = Dashboard::Container.new(name: "myproj-wt-01-claude", state: "running", health: nil, exit_code: 0, started_at: NOW - 3600)
    file = Dashboard::StatusFile.new(v: 2, state: "working", phase: "permission", ts: NOW, message: %(Run "rm" <now>?), tool: "Bash",
                                     last_message: nil, rtk: nil)
    @raw = fixture_raw.with(containers: fixture_raw.containers.merge(claude.name => claude), agent_files: { "wt-01" => [NOW, file] })
    frame = one(S.frames([:notify, "wt-01"], state, sub(nil)))
    assert_equal '<turbo-stream action="notify" title="wt-01: needs permission" body="Run &quot;rm&quot; &lt;now&gt;?" tag="wt-01">' \
                 "</turbo-stream>", frame
  end

  def test_job_events_are_left_for_later
    assert_empty S.frames([:job, "j1"], state, sub(nil))
  end

  # Runs GET /events?w=wt-01 in a thread, the way a streaming server calls the body.
  def open_stream(github: nil)
    status, headers, body = app(github:).call(Rack::MockRequest.env_for("/events?w=wt-01", HOST))
    stream = StreamDouble.new
    thread = Thread.new { body.call(stream) }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.001 until hub.subscriber_count == 1 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    [status, headers, stream, thread]
  end

  def test_events_stream_delivers_row_updates
    github = FakeGithub.new
    status, headers, stream, thread = open_stream(github:)
    assert_equal [200, "text/event-stream", "no-store"], [status, headers["content-type"], headers["cache-control"]]
    assert_equal [:focus], github.hints
    assert_equal Set["wt-01"], hub.viewed_names
    hub.apply([:git, "wt-01"], git(3))
    output = stream.wait_for('target="row-wt-01"')
    assert output, "no row frame within 1 s"
    assert_match(/^data: <turbo-stream action="replace" target="row-wt-01">/, output)
    stream.close
    hub.apply([:git, "wt-01"], git(4)) # a write to the closed stream ends the loop
    assert thread.join(1), "the stream did not stop"
  ensure
    stream&.close
    thread&.kill
  end

  # A connect first brings the page up to date: whatever changed between its render
  # (or an EventSource reconnect gap) and the stream.
  def test_connect_catches_up_list_header_and_detail
    _, _, stream, thread = open_stream
    output = stream.wait_for('target="detail"')
    assert output, "no catch-up within 1 s"
    first = output.split("\n\n")
    assert_match(/\Adata: <turbo-stream action="replace" target="worktrees">/, first[0])
    assert_match(/\Adata: <turbo-stream action="replace" target="header">/, first[1])
    assert_match(/\Adata: <turbo-stream action="replace" target="detail">/, first[2])
    assert_includes first[0], 'aria-current="page"'
    assert_includes first[1], '<span class="repo">example-org/app</span>'
    assert_includes first[2], "wt-01"
  ensure
    stream&.close
    thread&.kill
  end

  def test_catch_up_for_a_removed_worktree_shows_the_gone_notice
    hub.apply(:worktrees, fixture_raw.refs.reject { it.name == "wt-01" })
    frames = S.catch_up(state, sub("wt-01"), repo: "example-org/app")
    assert_equal 3, frames.size
    assert_includes frames.last, "worktree removed"
    assert_equal 2, S.catch_up(state, sub(nil), repo: "example-org/app").size # nothing shown, no detail to repair
  end

  def test_disconnect_unsubscribes
    _, _, stream, thread = open_stream
    stream.close
    hub.apply([:git, "wt-01"], git(3))
    assert thread.join(1), "the stream did not stop"
    assert_equal 0, hub.subscriber_count
  end
end
