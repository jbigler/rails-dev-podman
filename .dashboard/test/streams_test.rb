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

  def job(id, state: :running, worktree: "wt-01", lines: ["hello <b>"], created: nil)
    Dashboard::Job.new(id:, worktree:, label: "up", state:, exit_status: state == :failed ? 1 : nil, started_at: NOW, finished_at: nil,
                       lines:, created:)
  end

  def test_new_job_appends_and_a_shown_one_is_replaced
    hub.publish_job(job(1))
    frame = one(S.frames([:job, 1], state, sub(nil), jobs: {}))
    assert_match(/\A<turbo-stream action="append" target="actions"><template><article id="job-1"/, frame)
    assert_includes frame, "hello &lt;b&gt;"
    assert_includes frame, 'data-action-url-param="/jobs/1/cancel"'
    frame = one(S.frames([:job, 1], state, sub(nil), jobs: { 1 => :running }))
    assert_match(/\A<turbo-stream action="replace" target="job-1">/, frame)
    assert_empty S.frames([:job, 2], state, sub(nil), jobs: {})
  end

  def test_finished_job_shows_status_and_the_created_worktree
    hub.publish_job(job(1, state: :failed))
    hub.publish_job(job(2, state: :ok, worktree: nil, created: "wt-new"))
    failed = one(S.frames([:job, 1], state, sub(nil), jobs: { 1 => :running }))
    assert_includes failed, "exit 1"
    refute_includes failed, "/cancel"
    created = one(S.frames([:job, 2], state, sub(nil), jobs: {}))
    assert_includes created, 'data-job-created="/w/wt-new"'
    assert_includes created, 'href="/w/wt-new"'
  end

  def test_running_job_shows_only_the_tail
    hub.publish_job(job(1, lines: Array.new(800) { "line #{it}" }))
    frame = one(S.frames([:job, 1], state, sub(nil), jobs: {}))
    refute_includes frame, "line 299\n"
    assert_includes frame, "line 300\n"
    assert_includes frame, "300 earlier lines"
  end

  def test_a_job_starting_or_ending_rerenders_the_viewed_detail
    hub.publish_job(job(1))
    frames = S.frames([:job, 1], state, sub("wt-01"), jobs: {})
    assert_equal 2, frames.size
    assert_match(/\A<turbo-stream action="replace" target="detail">/, frames.last)
    assert_equal 1, S.frames([:job, 1], state, sub("wt-01"), jobs: { 1 => :running }).size # output only
    assert_equal 1, S.frames([:job, 1], state, sub("wt-02"), jobs: {}).size
  end

  def test_jobs_the_hub_dropped_are_removed_when_a_new_one_appends
    (1..21).each { hub.publish_job(job(it, state: :ok)) }
    shown = (1..20).to_h { [it, :ok] }
    frames = S.frames([:job, 21], state, sub(nil), jobs: shown)
    assert_equal ['<turbo-stream action="remove" target="job-1"></turbo-stream>'], frames[0..-2]
    assert_match(/action="append"/, frames.last)
    assert_equal (2..21).to_h { [it, :ok] }, S.shown_jobs(state, shown, 21)
    assert_equal (2..21).to_h { [it, :ok] }, S.shown_jobs(state)
  end

  def test_events_stream_delivers_jobs
    _, _, stream, thread = open_stream
    assert stream.wait_for('target="detail"'), "no catch-up within 1 s"
    hub.publish_job(job(1))
    hub.publish_job(job(1, state: :ok))
    output = stream.wait_for('target="job-1"')
    assert output, "no job frames within 1 s"
    assert_match(/^data: <turbo-stream action="append" target="actions">/, output)
    assert_match(/^data: <turbo-stream action="replace" target="job-1">/, output)
  ensure
    stream&.close
    thread&.kill
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
    assert_equal 4, frames.size
    assert_includes frames[2], "worktree removed"
    assert_equal 3, S.catch_up(state, sub(nil), repo: "example-org/app").size # nothing shown, no detail to repair
  end

  def test_catch_up_brings_the_jobs
    hub.publish_job(job(1, state: :ok))
    frame = S.catch_up(state, sub(nil), repo: "example-org/app").last
    assert_match(/\A<turbo-stream action="update" target="actions"><template><article id="job-1"/, frame)
  end

  def test_disconnect_unsubscribes
    _, _, stream, thread = open_stream
    stream.close
    hub.apply([:git, "wt-01"], git(3))
    assert thread.join(1), "the stream did not stop"
    assert_equal 0, hub.subscriber_count
  end
end
