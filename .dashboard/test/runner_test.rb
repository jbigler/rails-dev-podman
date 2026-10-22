# frozen_string_literal: true

require_relative "test_helper"

# Jobs from action specs, with a spawner that replays scripted children.
class RunnerTest < Minitest::Test
  R = Dashboard::Runner
  A = Dashboard::Actions
  SCOPE = FakeSpawner::SCOPE

  class FakeGithub
    attr_reader :hints

    def initialize = @hints = []
    def hint(kind) = @hints << kind
  end

  class FakeLocal
    attr_reader :pokes

    def initialize = @pokes = 0
    def poke = @pokes += 1
  end

  # Replays `git worktree list` outputs in turn (the last one repeats), for
  # the refs before and after a wt-create.
  class ListShell < FakeShell
    def initialize(lists)
      super()
      @lists = lists
    end

    def run(argv, chdir: nil, timeout: nil, env: {})
      return super unless argv.include?("worktree")

      @calls << Call.new(argv:, chdir:, env:)
      Dashboard::Shell::Result.ok(@lists.size > 1 ? @lists.shift : @lists.first)
    end
  end

  def setup
    @shell_was = Dashboard::Shell.backend
    Dashboard::Shell.backend = FakeShell.new # SessionEnv's systemctl is not stubbed: only NO_COLOR
    @logs = Dir.mktmpdir("runner-logs")
  end

  def teardown
    Dashboard::Shell.backend = @shell_was
    FileUtils.rm_rf(@logs)
  end

  def real_spawn(argv, env: {}, chdir: Dir.tmpdir, job: 1) = R::Spawn.new("#{@logs}/jobs").spawn(argv, env:, chdir:, job:)

  def hub = @hub ||= Dashboard::Hub.new(ws, raw: fixture_raw)
  def wt(name) = hub.snapshot.worktrees.find { it.name == name }
  def runner(spawner, **) = R.new(hub:, ws:, spawner:, **)

  # The job once it is no longer running; fails after a second.
  def finished(runner, job)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      current = runner.jobs.find { it.id == job.id }
      return current unless current.state == :running
      flunk "job #{job.id} still running after 1 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.001
    end
  end

  def test_one_job_per_worktree
    spawner = FakeSpawner.new(hold: ["mise run up"])
    r = runner(spawner)
    first = r.start(A.find("up"), worktree: wt("wt-01"))
    assert_equal :running, first.state
    assert_raises(R::Busy) { r.start(A.find("up"), worktree: wt("wt-01")) }
    assert_raises(R::Busy) { r.start(A.find("wt-rm"), worktree: wt("wt-01")) } # removing it while it starts
    other = r.start(A.find("up"), worktree: wt("wt-02"))
    2.times { spawner.release("mise run up") }
    assert_equal [:ok, :ok], [finished(r, first).state, finished(r, other).state]
    again = r.start(A.find("up"), worktree: wt("wt-01")) # free again
    spawner.release("mise run up")
    finished(r, again)
  end

  def test_one_workspace_job_at_a_time
    spawner = FakeSpawner.new(hold: ["mise run units:install"])
    r = runner(spawner)
    job = r.start(A.find("units-install"), worktree: nil)
    assert_nil job.worktree
    assert_raises(R::Busy) { r.start(A.find("autostart-on"), worktree: nil) }
    assert_raises(R::Busy) { r.start(A.find("wt-rm"), worktree: wt("wt-01")) }
    up = r.start(A.find("up"), worktree: wt("wt-01"))
    spawner.release("mise run units:install")
    finished(r, job)
    finished(r, up)
  end

  def test_scope_wrapping
    spawner = FakeSpawner.new
    r = runner(spawner)
    finished(r, r.start(A.find("up"), worktree: wt("wt-01")))
    call = spawner.calls.first
    assert_equal SCOPE, call.argv.first(SCOPE.size)
    assert_equal %w[mise run up], call.argv.last(3)
    assert_equal "#{ROOT}/wt-01", call.chdir
    assert_equal({ "NO_COLOR" => "1" }, call.env)
  end

  def test_down_and_discard_force
    spawner = FakeSpawner.new
    r = runner(spawner)
    finished(r, r.start(A.find("down"), worktree: wt("wt-01")))
    finished(r, r.start(A.find("wt-rm"), worktree: wt("wt-02")))
    finished(r, r.start(A.find("wt-rm"), worktree: wt("wt-03"), discard: true))
    down, keep, discard = spawner.calls
    assert_equal "1", down.env["FORCE"]
    assert_equal %w[mise run wt:rm wt-02], keep.argv.last(4)
    assert_equal ROOT, keep.chdir
    refute keep.env.key?("FORCE")
    assert_equal "1", discard.env["FORCE"]
  end

  def test_restart_all_stops_on_failure
    spawner = FakeSpawner.new({ "mise run stop" => [["cannot stop"], 1] })
    r = runner(spawner)
    job = finished(r, r.start(A.find("restart-all"), worktree: wt("wt-01")))
    assert_equal ["mise run stop"], spawner.commands
    assert_equal :failed, job.state
    assert_equal 1, job.exit_status
    assert_equal ["cannot stop"], job.lines
    assert job.finished_at
  end

  def test_restart_all_runs_stop_then_up
    spawner = FakeSpawner.new
    r = runner(spawner)
    assert_equal :ok, finished(r, r.start(A.find("restart-all"), worktree: wt("wt-01"))).state
    assert_equal ["mise run stop", "mise run up"], spawner.commands
  end

  def test_output_is_scrubbed
    many = Array.new(6000) { "line #{it}" }
    spawner = FakeSpawner.new({ "mise run up" => [["\e[31mred\e[0m", "\xff\xfe".b], 0], "mise run stop" => [many, 0] })
    r = runner(spawner)
    assert_equal %w[red ??], finished(r, r.start(A.find("up"), worktree: wt("wt-01"))).lines
    lines = finished(r, r.start(A.find("stop"), worktree: wt("wt-01"))).lines
    assert_equal 5000, lines.size
    assert_equal "line 5999", lines.last
    assert_equal "line 1000", lines.first
  end

  def test_long_lines_are_cut
    spawner = FakeSpawner.new({ "mise run up" => [["a" * 200 * 1024], 0] })
    r = runner(spawner)
    lines = finished(r, r.start(A.find("up"), worktree: wt("wt-01"))).lines
    assert_equal 4, lines.size
    assert(lines.all? { it.bytesize <= R::MAX_LINE })
    assert_equal 200 * 1024, lines.sum(&:bytesize)
  end

  def test_a_job_keeps_at_most_its_byte_budget
    big = Array.new(100) { |n| format("%04d", n) + ("b" * ((60 * 1024) - 4)) }
    spawner = FakeSpawner.new({ "mise run up" => [big, 0] })
    r = runner(spawner)
    lines = finished(r, r.start(A.find("up"), worktree: wt("wt-01"))).lines
    assert_operator lines.sum(&:bytesize), :<=, 4 * 1024 * 1024
    assert_operator lines.sum(&:bytesize), :>, (4 * 1024 * 1024) - (60 * 1024)
    assert lines.last.start_with?("0099"), "the newest line was dropped"
    refute lines.first.start_with?("0000"), "the oldest line was kept"
  end

  def test_github_hint_after_stack_push
    github = FakeGithub.new
    local = FakeLocal.new
    r = runner(FakeSpawner.new, github:, local:)
    finished(r, r.start(A.find("up"), worktree: wt("wt-stacked")))
    assert_empty github.hints
    assert_equal 1, local.pokes
    finished(r, r.start(A.find("stack-push"), worktree: wt("wt-stacked")))
    assert_equal [:action], github.hints
    assert_equal 2, local.pokes
  end

  def test_hub_gets_the_job_on_start_and_finish
    spawner = FakeSpawner.new({ "mise run up" => [["one", "two"], 0] }, hold: ["mise run up"])
    r = runner(spawner)
    sub = hub.subscribe(viewing: nil)
    job = r.start(A.find("up"), worktree: wt("wt-01"))
    assert_equal [:job, job.id], sub.queue.pop(timeout: 1)
    assert_equal :running, hub.snapshot.jobs.last.state
    spawner.release("mise run up")
    finished(r, job)
    seen = hub.snapshot.jobs.find { it.id == job.id }
    assert_equal [:ok, %w[one two]], [seen.state, seen.lines]
    assert [seen, seen.lines].all?(&:frozen?)
  end

  def test_cancel_kills_and_skips_the_rest
    spawner = FakeSpawner.new(hold: ["mise run stop"])
    r = runner(spawner)
    job = r.start(A.find("restart-all"), worktree: wt("wt-01"))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.001 until spawner.calls.any? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert r.cancel(job.id)
    done = finished(r, job)
    assert_equal :cancelled, done.state
    assert_nil done.exit_status
    assert_equal ["mise run stop"], spawner.commands
    refute r.cancel(job.id)
  end

  def test_terminal_mode_opens_newterm
    spawner = FakeSpawner.new
    r = runner(spawner)
    job = finished(r, r.start(A.find("nvim"), worktree: wt("wt-01")))
    argv = spawner.calls.first.argv
    assert_equal SCOPE + ["#{ROOT}/.scripts/newterm.sh", "--title", "wt-01: nvim", "--cwd", "#{ROOT}/wt-01", "--", "mise", "run", "nvim"], argv
    assert_equal [:ok, ["opened nvim"]], [job.state, job.lines]
  end

  def test_terminal_error_line_shows
    command = "#{ROOT}/.scripts/newterm.sh --title wt-01: console --cwd #{ROOT}/wt-01 -- mise run console"
    r = runner(FakeSpawner.new({ command => [["error: no terminal found"], 1] }))
    job = finished(r, r.start(A.find("console"), worktree: wt("wt-01")))
    assert_equal [:failed, ["error: no terminal found"]], [job.state, job.lines]
  end

  def test_claude_attaches_to_a_running_container
    running = Dashboard::Shell::Result.ok("true\n")
    Dashboard::Shell.backend = FakeShell.new("podman container inspect --format {{.State.Running}} myproj-wt-01-claude" => running)
    spawner = FakeSpawner.new
    r = runner(spawner)
    finished(r, r.start(A.find("claude"), worktree: wt("wt-01")))
    finished(r, r.start(A.find("claude"), worktree: wt("wt-02")))
    assert_equal %w[podman attach myproj-wt-01-claude], spawner.calls[0].argv.last(3)
    assert_equal %w[mise run claude], spawner.calls[1].argv.last(3)
  end

  def test_wt_create_records_the_new_worktree
    list = fixture("git-worktree-list.txt")
    added = "#{list.chomp}\n\nworktree #{ROOT}/feature-new\nHEAD #{'a' * 40}\nbranch refs/heads/feature/new\n"
    Dashboard::Shell.backend = ListShell.new([list, added])
    spawner = FakeSpawner.new
    r = runner(spawner)
    job = finished(r, r.start(A.find("wt-create"), worktree: nil, input: "feature/new"))
    assert_equal %w[mise run wt feature/new], spawner.calls.first.argv.last(4)
    assert_equal ROOT, spawner.calls.first.chdir
    assert_equal "feature-new", job.created
  end

  def test_real_spawn_merges_output_and_reports_status
    child = real_spawn(["sh", "-c", "echo out; echo err >&2; printf tail; exit 3"], env: { "NO_COLOR" => "1" })
    lines = []
    child.each_line { lines << it }
    assert_equal %w[out err tail], lines
    assert_equal 3, child.wait
  end

  def test_real_spawn_cuts_output_without_newlines
    child = real_spawn(["sh", "-c", "head -c 204800 /dev/zero | tr '\\0' a"])
    sizes = []
    child.each_line { sizes << it.bytesize }
    assert_equal 0, child.wait
    assert(sizes.all? { it <= R::MAX_LINE })
    assert_equal 204_800, sizes.sum
  end

  def test_real_spawn_kill_ends_the_group
    child = real_spawn(["sh", "-c", "sleep 10 & wait"])
    reader = Thread.new { child.each_line { nil } }
    child.kill
    assert reader.join(2), "output did not end after the kill"
    assert_nil child.wait
  end

  def test_real_spawn_missing_binary
    child = real_spawn(["/nonexistent/binary"])
    lines = []
    child.each_line { lines << it }
    assert_match(/\Aerror: /, lines.first)
    assert_equal 127, child.wait
  end

  # The dashboard stopping (the reader gone) must not end a job halfway: the
  # child writes after the reader left and still runs to the end.
  def test_real_spawn_child_outlives_its_reader
    Dir.mktmpdir do |dir|
      marker = "#{dir}/done"
      child = real_spawn(["sh", "-c", "echo one; sleep 0.3; echo two; touch #{marker}"], chdir: dir)
      child.each_line { break }
      assert_equal 0, child.wait
      assert File.exist?(marker), "the child died after its reader went away"
    end
  end

  def test_real_spawn_logs_privately_and_forgets
    dir = "#{@logs}/jobs"
    Dir.mkdir(dir, 0o700)
    File.write("#{dir}/1.log", "from the last run\n")
    spawn = R::Spawn.new(dir)
    refute File.exist?("#{dir}/1.log"), "a log from an earlier run survived"

    2.times do |n|
      child = spawn.spawn(["sh", "-c", "echo run#{n}"], env: {}, chdir: Dir.tmpdir, job: 7)
      lines = []
      child.each_line { lines << it }
      assert_equal ["run#{n}"], lines, "each command reads only its own output"
    end
    assert_equal "run0\nrun1\n", File.read("#{dir}/7.log")
    assert_equal 0o600, File.stat("#{dir}/7.log").mode & 0o777
    spawn.forget(7)
    refute File.exist?("#{dir}/7.log")
  end

  LOG_LIMIT = 64 * 1024

  def log_spawn(script, job: 1) = R::Spawn.new("#{@logs}/jobs", log_limit: LOG_LIMIT).spawn([RbConfig.ruby, "-e", script], env: {}, chdir: Dir.tmpdir, job:)
  def log_file(job = 1) = "#{@logs}/jobs/#{job}.log"
  def dropped?(line) = line.start_with?("… output dropped (log over ".b)

  # $XDG_RUNTIME_DIR is a small tmpfs (it holds the podman socket too): once the
  # reader has caught up past the cap, the log is truncated in place. The child
  # never writes while its log is at the cap (the reader is about to empty it),
  # so no line can land between the last read and the truncate; it reports the
  # largest size it saw its log reach.
  def test_real_spawn_caps_the_log
    script = <<~RUBY
      max = 0
      12.times do |n|
        $stdout.write(16.times.map { |i| format("%04d %s\n", n * 16 + i, "x" * 1018) }.join)
        $stdout.flush
        max = [max, $stdout.stat.size].max
        deadline = Time.now + 5
        sleep 0.001 while $stdout.stat.size >= #{LOG_LIMIT} && Time.now < deadline
      end
      puts "max=\#{max}"
    RUBY
    child = log_spawn(script)
    lines = []
    child.each_line { lines << it }

    assert_equal 0, child.wait
    max = Integer(lines.pop[/\Amax=(\d+)\z/, 1])
    assert_operator max, :<=, LOG_LIMIT + (16 * 1024), "the log outgrew the cap by more than one write"
    assert_operator max, :>=, LOG_LIMIT
    assert_equal (0...192).map { format("%04d", it) }, lines.map { it[0, 4] }, "a line was lost to the truncation"
    assert_operator File.size(log_file), :<=, LOG_LIMIT
  end

  # A child that never pauses and a reader far slower than it: the log is
  # emptied whenever it reaches twice the cap, unread part and all, and a
  # marker line says so. Sampled as each line is consumed (the reader looks at
  # the size after every read and every millisecond of consuming).
  def test_real_spawn_drops_unread_output_past_twice_the_cap
    script = <<~RUBY
      line = "x" * 1017
      n = 0
      stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop
        $stdout.write(format("%06d %s\n", n, line))
        n += 1
      end
      $stdout.flush
      # Not so close to twice the cap that "end" itself lands in a dropped part.
      deadline = Time.now + 5
      sleep 0.001 while $stdout.stat.size >= #{(2 * LOG_LIMIT) - 1024} && Time.now < deadline
      puts "end"
    RUBY
    child = log_spawn(script)
    lines = []
    sizes = []
    child.each_line do
      sizes << File.size(log_file)
      lines << it
      sleep 0.002
    end

    assert_equal 0, child.wait
    # Slack: the child writes ~0.5 GB/s; a GC pause or reschedule between the
    # reader's look and this sample lets it add a little (unfixed: >100 MiB).
    assert_operator sizes.max, :<=, (2 * LOG_LIMIT) + (16 * R::LogTail::READ), "the log outgrew twice the cap"
    assert_equal "end", lines.last
    assert(lines.any? { dropped?(it) }, "no marker for the dropped output")
    assert_includes lines, "… output dropped (log over 0.125 MiB)".b
  end

  # The child is gone with 4x the cap unread: only the last cap's worth is read
  # (from the next line start), after a marker, so the drain is bounded.
  def test_real_spawn_drains_only_the_tail_after_exit
    script = %($stdout.write(256.times.map { |i| format("%04d %s\\n", i, "x" * 1018) }.join))
    child = log_spawn(script)
    lines = []
    child.each_line do
      child.wait if lines.empty? # hold the reader until the child has exited
      lines << it
    end

    marker = lines.index { dropped?(it) }
    refute_nil marker, "no marker for the skipped output"
    head = lines[0...marker].map { Integer(it[0, 4], 10) }
    tail = lines[(marker + 1)..].map { Integer(it[0, 4], 10) }
    assert_equal (0...head.size).to_a, head
    assert_equal (193..255).to_a, tail, "the tail after the marker"
    assert_operator File.size(log_file), :<=, LOG_LIMIT
  end

  def test_a_job_dropped_from_retention_loses_its_log
    spawner = FakeSpawner.new
    r = runner(spawner)
    jobs = (Dashboard::Hub::KEEP_JOBS + 1).times.map { finished(r, r.start(A.find("up"), worktree: wt("wt-01"))) }
    assert_equal [jobs.first.id], spawner.forgotten
  end

  class RaisingLocal
    def poke = raise("poke failed")
  end

  def test_a_failing_poke_still_ends_the_job
    reporting = Thread.report_on_exception
    Thread.report_on_exception = false
    r = runner(FakeSpawner.new, local: RaisingLocal.new)
    job = finished(r, r.start(A.find("up"), worktree: wt("wt-01")))
    assert_equal :ok, job.state
    finished(r, r.start(A.find("up"), worktree: wt("wt-01")))
  ensure
    Thread.report_on_exception = reporting
  end
end
