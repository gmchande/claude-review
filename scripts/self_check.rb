#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "claude_visible_session"
require_relative "wait_for_review"

HELPER = File.expand_path("claude_review.rb", __dir__)
HANDOFF_HOOK = File.expand_path("review_handoff_hook.rb", __dir__)

def run_cmd(repo, *cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*cmd, chdir: repo)
  if !status.success? && !allow_failure
    warn "Command failed in #{repo}: #{cmd.join(" ")}"
    warn stdout unless stdout.empty?
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end
  [stdout, stderr, status]
end

def git(repo, *args)
  run_cmd(repo, "git", *args)
end

def init_repo
  repo = Dir.mktmpdir("cr-check-")
  git(repo, "init")
  git(repo, "config", "user.email", "check@example.test")
  git(repo, "config", "user.name", "Self Check")
  repo
end

def write(repo, path, content)
  full_path = File.join(repo, path)
  FileUtils.mkdir_p(File.dirname(full_path))
  File.binwrite(full_path, content)
end

def commit_all(repo, message)
  git(repo, "add", ".")
  git(repo, "commit", "-m", message)
end

def dry_run(repo, *args, allow_failure: false)
  stdout, stderr, status = run_cmd(repo, "ruby", HELPER, "--dry-run", *args, allow_failure: allow_failure)
  [stdout + stderr, status]
end

def assert(condition, message)
  return if condition

  warn "FAIL: #{message}"
  exit 1
end

def assert_includes(text, needle, label)
  assert(text.include?(needle), "#{label}: expected output to include #{needle.inspect}")
end

def write_executable(directory, name, content)
  path = File.join(directory, name)
  File.binwrite(path, content)
  FileUtils.chmod(0o700, path)
  path
end

def with_env(values)
  previous = values.to_h { |name, _value| [name, ENV[name]] }
  values.each do |name, value|
    value.nil? ? ENV.delete(name) : ENV[name] = value
  end
  yield
ensure
  previous.each do |name, value|
    value.nil? ? ENV.delete(name) : ENV[name] = value
  end
end

def invoke_handoff_hook(env, payload)
  Open3.capture3(env, RbConfig.ruby, HANDOFF_HOOK, stdin_data: JSON.generate(payload))
end

def write_assistant_transcript(path, *models)
  File.open(path, "w") do |file|
    models.each do |model|
      file.puts JSON.generate("type" => "assistant", "message" => { "model" => model })
    end
  end
end

def test_claude_handoff_hook_tracks_interactive_turns
  dir = Dir.mktmpdir("cr-claude-handoff-")
  handoff_path = File.join(dir, "handoff.md")
  marker_path = File.join(dir, "status")
  transcript_path = File.join(dir, "session.jsonl")
  write_assistant_transcript(transcript_path, "claude-opus-5")
  env = {
    "CLAUDE_REVIEW_HANDOFF_PATH" => handoff_path,
    "CLAUDE_REVIEW_MARKER_PATH" => marker_path,
    "CLAUDE_REVIEW_MODEL" => "claude-opus-5",
    "CLAUDE_REVIEW_EFFORT" => "xhigh"
  }

  _stdout, stderr, status = invoke_handoff_hook(env, "hook_event_name" => "SessionStart", "source" => "startup", "model" => "claude-opus-5")
  assert(status.success?, "Claude SessionStart hook should succeed: #{stderr}")

  File.write(handoff_path, "stale review\n")
  _stdout, stderr, status = invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  assert(status.success?, "Claude UserPromptSubmit hook should succeed: #{stderr}")
  assert(!File.exist?(handoff_path), "prompt submit should clear the previous handoff")
  assert(File.read(marker_path) == "running\n", "prompt submit should mark the review running")
  assert((File.stat(marker_path).mode & 0o777) == 0o600, "running marker should be mode 0600")

  _stdout, stderr, status = invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => { "level" => "xhigh" },
    "last_assistant_message" => "First review"
  )
  assert(status.success?, "Claude Stop hook should succeed: #{stderr}")
  assert(File.read(handoff_path) == "First review\n", "Stop should write the completed assistant turn")
  assert(File.read(marker_path) == "0\n", "Stop should write status 0")
  assert((File.stat(handoff_path).mode & 0o777) == 0o600, "handoff should be mode 0600")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  write_assistant_transcript(transcript_path, "claude-opus-5", "<synthetic>")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => { "level" => "xhigh" },
    "last_assistant_message" => "Review after a synthetic retry"
  )
  assert(File.read(handoff_path) == "Review after a synthetic retry\n", "synthetic entries should not invalidate an Opus review")
  assert(File.read(marker_path) == "0\n", "synthetic entries should not count as another model")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  write_assistant_transcript(transcript_path, "<synthetic>")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => { "level" => "xhigh" },
    "last_assistant_message" => "Synthetic-only review"
  )
  assert(File.read(marker_path) == "1\n", "synthetic-only transcripts should not supply model evidence")
  assert_includes(File.read(handoff_path), "did not report an assistant model", "synthetic-only handoff")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  assert(File.read(marker_path) == "running\n", "an interrupted follow-up should remain running until another event")
  assert(!File.exist?(handoff_path), "an interrupted follow-up should not leave a stale handoff")

  invoke_handoff_hook(
    env,
    "hook_event_name" => "StopFailure",
    "error" => "rate_limit",
    "last_assistant_message" => "API Error: rate limit reached"
  )
  assert(File.read(marker_path) == "1\n", "StopFailure should write status 1")
  assert_includes(File.read(handoff_path), "rate limit reached", "failed handoff")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  write_assistant_transcript(transcript_path, "claude-opus-5", "claude-sonnet-5")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => { "level" => "xhigh" },
    "last_assistant_message" => "Mixed-model review"
  )
  assert(File.read(marker_path) == "1\n", "a mixed-model transcript should fail the handoff")
  assert_includes(File.read(handoff_path), "not exclusively \"claude-opus-5\"", "mixed-model handoff")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => File.join(dir, "missing.jsonl"),
    "effort" => { "level" => "xhigh" },
    "last_assistant_message" => "Unverifiable-model review"
  )
  assert(File.read(marker_path) == "1\n", "missing transcript model evidence should fail the handoff")
  assert_includes(File.read(handoff_path), "did not report an assistant model", "missing-model handoff")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  write_assistant_transcript(transcript_path, "claude-opus-5")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => { "level" => "high" },
    "last_assistant_message" => "Wrong effort review"
  )
  assert(File.read(marker_path) == "1\n", "unexpected effort should fail the handoff")
  assert_includes(File.read(handoff_path), "not \"xhigh\"", "unexpected effort handoff")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => "xhigh",
    "last_assistant_message" => "Malformed effort review"
  )
  assert(File.read(marker_path) == "1\n", "malformed effort evidence should fail the handoff")
  assert_includes(File.read(handoff_path), "did not report the turn effort", "malformed effort handoff")

  invoke_handoff_hook(env, "hook_event_name" => "UserPromptSubmit")
  invoke_handoff_hook(
    env,
    "hook_event_name" => "Stop",
    "transcript_path" => transcript_path,
    "effort" => { "level" => "xhigh" },
    "last_assistant_message" => "Corrected final review"
  )
  assert(File.read(handoff_path) == "Corrected final review\n", "corrected follow-up should replace the handoff")
  assert(File.read(marker_path) == "0\n", "corrected follow-up should replace failure with status 0")

  stdout, stderr, status = invoke_handoff_hook(env, "hook_event_name" => "SessionStart", "source" => "resume", "model" => "claude-sonnet-5")
  assert(status.success?, "model mismatch hook should return controlled JSON: #{stderr}")
  result = JSON.parse(stdout)
  assert(result["continue"] == false, "model mismatch should stop the session")
  assert(File.read(marker_path) == "1\n", "model mismatch should write status 1")
  assert_includes(File.read(handoff_path), "not \"claude-opus-5\"", "model mismatch handoff")
ensure
  FileUtils.rm_rf(dir) if dir
end

def test_completion_waiter
  dir = Dir.mktmpdir("cr-waiter-")
  marker_path = File.join(dir, "status")
  launch_marker = File.join(dir, "launched")
  File.write(launch_marker, "#{Process.pid}\n")
  output = StringIO.new
  writer = Thread.new do
    sleep 0.03
    File.write(marker_path, "running\n")
    sleep 0.03
    File.write(marker_path, "0\n")
  end

  state = ClaudeReviewWaiter.wait(marker_path, launch_marker: launch_marker, interval: 0.005, output: output)
  writer.join
  assert(state == "0", "waiter should return the completed marker")
  assert(output.string == "Claude review finished with marker 0.\n", "waiter should stay silent until completion")

  File.write(marker_path, "130\n")
  output = StringIO.new
  state = ClaudeReviewWaiter.wait(marker_path, interval: 0.005, output: output)
  assert(state == "130", "waiter should return a closed-before-completion marker")

  File.write(marker_path, "0\n")
  baseline = ClaudeReviewWaiter.marker_snapshot(marker_path)
  output = StringIO.new
  writer = Thread.new do
    sleep 0.03
    File.write(marker_path, "running\n")
    sleep 0.03
    File.write(marker_path, "0\n")
  end
  state = ClaudeReviewWaiter.wait(marker_path, after: baseline, launch_marker: launch_marker, interval: 0.005, output: output)
  writer.join
  assert(state == "0", "a resumed wait should return the new completed marker")
  assert(output.string == "Claude review finished with marker 0.\n", "a resumed wait should ignore the stale completed marker")

  dead_pid = Process.spawn(RbConfig.ruby, "-e", "exit 0")
  Process.wait(dead_pid)
  File.write(marker_path, "running\n")
  File.write(launch_marker, "#{dead_pid}\n")
  output = StringIO.new
  state = ClaudeReviewWaiter.wait(marker_path, launch_marker: launch_marker, interval: 0.005, output: output)
  assert(state == ClaudeReviewWaiter::LAUNCHER_GONE, "a dead launcher should end an ambiguous wait")
  assert(output.string == "Claude review launcher exited before a terminal marker.\n", "dead launcher output")
ensure
  writer&.join
  FileUtils.rm_rf(dir) if dir
end

def test_supported_followup
  dir = Dir.mktmpdir("cr-followup-")
  marker_path = File.join(dir, "status")
  handoff_path = File.join(dir, "handoff.md")
  prompt_log = File.join(dir, "prompt.log")
  command_file = File.join(dir, "cmux-command")
  File.write(marker_path, "0\n")
  File.write(handoff_path, "stale review\n")
  write_executable(dir, "resume-review", <<~'SH')
    #!/bin/sh
    test "$(sed -n '1p' "$FOLLOWUP_MARKER_PATH")" = running || exit 8
    test ! -e "$FOLLOWUP_HANDOFF_PATH" || exit 9
    printf '%s' "$@" > "$FOLLOWUP_PROMPT_LOG"
    sleep 0.03
    printf '0\n' > "$FOLLOWUP_MARKER_PATH"
  SH
  write_executable(dir, "claude", <<~'SH')
    #!/bin/sh
    exit 0
  SH
  fake_cmux = write_executable(dir, "cmux", <<~'SH')
    #!/bin/sh
    case "$1" in
      ping)
        exit 0
        ;;
      --json)
        printf '%s\n' '{"surface_ref":"surface:followup"}'
        ;;
      send)
        last=''
        for arg in "$@"; do last="$arg"; done
        printf '%s\n' "$last" > "$CMUX_COMMAND_FILE"
        ;;
      send-key)
        "$(sed -n '1p' "$CMUX_COMMAND_FILE")" >/dev/null 2>&1 &
        ;;
    esac
  SH

  env = {
    "PATH" => "#{dir}:#{ENV.fetch("PATH")}",
    "CMUX_WORKSPACE_ID" => "workspace:followup",
    "CMUX_SURFACE_ID" => "surface:caller",
    "CMUX_BUNDLED_CLI_PATH" => fake_cmux,
    "CMUX_COMMAND_FILE" => command_file,
    "FOLLOWUP_PROMPT_LOG" => prompt_log,
    "FOLLOWUP_MARKER_PATH" => marker_path,
    "FOLLOWUP_HANDOFF_PATH" => handoff_path
  }

  File.write(File.join(dir, "launched"), "#{Process.pid}\n")
  active_stdout, active_stderr, active_status = Open3.capture3(
    env,
    RbConfig.ruby,
    HELPER,
    "--resume-run",
    dir,
    "--intent",
    "Do not open concurrently",
    chdir: File.expand_path("..", __dir__)
  )
  assert(!active_status.success?, "follow-up should refuse an already-open session: #{active_stdout}#{active_stderr}")
  assert_includes(active_stderr, "still open in another terminal", "concurrent follow-up refusal")
  FileUtils.rm_f(File.join(dir, "launched"))

  stdout, stderr, status = Open3.capture3(
    env,
    RbConfig.ruby,
    HELPER,
    "--resume-run",
    dir,
    "--intent",
    "Review the corrected watcher",
    chdir: File.expand_path("..", __dir__)
  )
  assert(status.success?, "supported follow-up should succeed: #{stdout}#{stderr}")
  assert_includes(stdout, "Existing Claude Opus 5 review resumed.", "follow-up launch")
  assert_includes(stdout, "Viewer: Cmux right split surface:followup", "follow-up viewer")
  assert_includes(stdout, "Claude review finished with marker 0.", "follow-up completion")
  assert(File.read(prompt_log) == "Review the corrected watcher", "follow-up should submit the supplied intent")
ensure
  FileUtils.rm_rf(dir) if dir
end

def test_generated_resume_script_settles_early_failure
  repo = init_repo
  scratch = Dir.mktmpdir("cr-generated-resume-")
  command_file = File.join(scratch, "cmux-command")
  write(repo, "app.txt", "before\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "after\n")

  fake_claude = write_executable(scratch, "claude", <<~'SH')
    #!/bin/sh
    case " $* " in
      *" --resume "*) exit 7 ;;
    esac
    printf 'Initial review\n' > "$CLAUDE_REVIEW_HANDOFF_PATH"
    printf '0\n' > "$CLAUDE_REVIEW_MARKER_PATH"
  SH
  fake_cmux = write_executable(scratch, "cmux", <<~'SH')
    #!/bin/sh
    case "$1" in
      ping)
        exit 0
        ;;
      --json)
        printf '%s\n' '{"surface_ref":"surface:generated"}'
        ;;
      send)
        last=''
        for arg in "$@"; do last="$arg"; done
        printf '%s\n' "$last" > "$CMUX_COMMAND_FILE"
        ;;
      send-key)
        "$(sed -n '1p' "$CMUX_COMMAND_FILE")" >/dev/null 2>&1 &
        ;;
    esac
  SH
  env = {
    "PATH" => "#{scratch}:#{ENV.fetch("PATH")}",
    "TMPDIR" => scratch,
    "CMUX_WORKSPACE_ID" => "workspace:generated",
    "CMUX_SURFACE_ID" => "surface:caller",
    "CMUX_BUNDLED_CLI_PATH" => fake_cmux,
    "CMUX_COMMAND_FILE" => command_file
  }

  stdout, stderr, status = Open3.capture3(
    env,
    RbConfig.ruby,
    HELPER,
    "--intent",
    "Generate a resumable review",
    chdir: repo
  )
  assert(status.success?, "initial fake review should succeed: #{stdout}#{stderr}")
  run_dir = Dir.glob(File.join(scratch, "claude-review", "run-*")).first
  assert(run_dir, "initial fake review should create a private run")
  resume_script = File.join(run_dir, "resume-review")
  assert(File.executable?(resume_script), "initial fake review should generate an executable resume script")

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
  launch_marker = File.join(run_dir, "launched")
  while ClaudeReviewWaiter.launcher_alive?(launch_marker) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    sleep 0.01
  end
  assert(!ClaudeReviewWaiter.launcher_alive?(launch_marker), "initial fake Claude launcher should exit")

  _resume_stdout, _resume_stderr, resume_status = Open3.capture3(env, resume_script, "Follow-up that fails before hooks", chdir: repo)
  assert(!resume_status.success?, "fake resumed Claude should preserve its failure status")
  assert(File.read(File.join(run_dir, "status")) == "1\n", "generated resume trailer should settle an early failure")
  assert_includes(File.read(File.join(run_dir, "handoff.md")), "process status 7", "generated resume failure handoff")
ensure
  FileUtils.rm_rf(repo) if repo
  FileUtils.rm_rf(scratch) if scratch
end

def test_review_scenarios
  clean_branch = lambda do |repo|
    write(repo, "app.txt", "base\n")
    commit_all(repo, "initial")
    git(repo, "branch", "-M", "main")
    git(repo, "checkout", "-b", "feature")
    write(repo, "app.txt", "feature\n")
    commit_all(repo, "feature")
  end

  scenarios = [
    {
      name: "dirty diff",
      setup: ->(repo) { write(repo, "app.txt", "hello\n"); commit_all(repo, "initial"); write(repo, "app.txt", "hello world\n") },
      args: ["--intent", "Review dirty diff"],
      includes: ["Review target: working tree against HEAD", "+hello world"]
    },
    {
      name: "clean branch with base",
      setup: clean_branch,
      args: ["--base", "main", "--intent", "Review branch"],
      includes: ["Review target: current branch against main", "+feature"]
    },
    {
      name: "clean branch requires base",
      setup: clean_branch,
      args: ["--intent", "Review branch"],
      success: false,
      includes: ["No local changes found. Pass --base REF"]
    },
    {
      name: "unborn untracked",
      setup: ->(repo) { write(repo, "notes.txt", "first file\n") },
      args: ["--intent", "Review unborn repo"],
      includes: ["working tree against empty tree", "## Untracked Files", "first file"]
    },
    {
      name: "missing plan",
      setup: ->(repo) { write(repo, "app.txt", "hello\n"); commit_all(repo, "initial") },
      args: ["--plan", "missing.md"],
      success: false,
      includes: ["Plan file not found: missing.md"]
    },
    {
      name: "plan only",
      setup: ->(repo) { write(repo, "docs/plan.md", "# Plan\n\nShip the bounded review.\n"); commit_all(repo, "initial") },
      args: ["--plan", "docs/plan.md"],
      includes: ["Review target: plan docs/plan.md", "Plan under review: docs/plan.md", "Ship the bounded review."]
    },
    {
      name: "binary untracked",
      setup: ->(repo) { write(repo, "app.txt", "hello\n"); commit_all(repo, "initial"); write(repo, "blob.bin", "abc\u0000def") },
      args: ["--intent", "Review binary untracked"],
      includes: ["### blob.bin", "Skipped: not a readable text file."]
    },
    {
      name: "artifact only",
      setup: ->(repo) { write(repo, "docs/plan.md", "# Plan\n\nShip the workflow.\n"); commit_all(repo, "initial") },
      args: ["--artifact", "docs/plan.md"],
      includes: ["Review target: artifact docs/plan.md", "Artifact under review: docs/plan.md", "Ship the workflow."]
    },
    {
      name: "dirty artifact",
      setup: lambda do |repo|
        write(repo, "app.txt", "hello\n")
        write(repo, "docs/plan.md", "# Plan\n\nShip the workflow.\n")
        commit_all(repo, "initial")
        write(repo, "app.txt", "hello changed\n")
      end,
      args: ["--artifact", "docs/plan.md"],
      includes: ["Review target: working tree against HEAD", "Artifact under review: docs/plan.md", "+hello changed"]
    }
  ]

  scenarios.each do |scenario|
    repo = init_repo
    begin
      scenario[:setup].call(repo)
      output, status = dry_run(repo, *scenario[:args], allow_failure: !scenario.fetch(:success, true))
      expected_success = scenario.fetch(:success, true)
      assert(status.success? == expected_success, "#{scenario[:name]} dry-run success should be #{expected_success}")
      scenario[:includes].each { |needle| assert_includes(output, needle, scenario[:name]) }
    ensure
      FileUtils.rm_rf(repo)
    end
  end
end

def test_default_claude_configuration
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello changed\n")

  output, status = dry_run(repo, "--intent", "Review defaults")

  assert(status.success?, "default Claude configuration dry-run should succeed")
  assert_includes(output, "Claude model: claude-opus-5", "default model")
  assert_includes(output, "Claude effort: xhigh", "default effort")
  assert_includes(output, "Runner: native Claude TUI in a right-hand Cmux split or Ghostty tab", "native runner")
  assert_includes(output, "Viewer selection: right-hand split inside Cmux; Ghostty tab otherwise", "viewer selection")
  assert_includes(output, "Claude tools: Read,Grep,Glob", "review tool boundary")
  assert_includes(output, "Permission mode: dontAsk", "permission mode")
  assert_includes(output, "Workspace: primary repository; private run directory is auxiliary only", "workspace selection")
  assert_includes(output, "Setting sources: explicit private settings only", "setting isolation")
  assert_includes(output, "Selectable models: claude-opus-5", "model allowlist")
  assert_includes(output, "Automatic model fallback: disabled", "automatic fallback")
  assert_includes(output, "Handoff model validation: transcript must contain only claude-opus-5", "handoff model validation")
  assert_includes(output, "Launch acknowledgement: required before reporting success", "launch acknowledgement")
  assert_includes(File.read(HELPER), '"CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK" => "1"', "fallback environment")
  assert(!output.include?("Bash"), "review tool boundary should exclude Bash")
  assert(!output.include?("WebFetch"), "review tool boundary should exclude web tools")
  assert(!output.include?("Agent"), "review tool boundary should exclude subagents")
  assert_includes(output, "Match review depth to the change's size, risk, and project context.", "proportional review prompt")
  assert_includes(output, "Use tools when needed to understand affected behavior", "review exploration prompt")
  assert_includes(output, "state the review limitation instead of claiming no actionable findings", "incomplete review prompt")
  assert(!output.include?("Before reporting a finding, verify"), "Opus 5 prompt should not request redundant verification")
  assert(!output.match?(/at most \d+ tool calls/i), "review prompt should not contain a numeric tool-call budget")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_native_viewer_selection
  directory = Dir.mktmpdir("cr-viewer-")
  cmux_log = File.join(directory, "cmux.log")
  ghostty_log = File.join(directory, "osascript.log")
  launch_marker = File.join(directory, "launched")
  fake_cmux = write_executable(directory, "cmux", <<~SH)
    #!/bin/sh
    printf '%s\n' "$*" >> "$CMUX_LOG"
    case "$*" in
      "ping") exit 0 ;;
      *"new-split right"*) printf '%s\n' '{"surface_ref":"surface:9"}' ;;
      *"send-key"*" Enter"*)
        if [ -n "$LAUNCH_MARKER" ]; then printf '%s\n' started > "$LAUNCH_MARKER"; fi
        ;;
    esac
  SH
  write_executable(directory, "osascript", <<~SH)
    #!/bin/sh
    if [ "$1" = "-e" ]; then exit 0; fi
    tee "$GHOSTTY_LOG" >/dev/null
    if [ -n "$LAUNCH_MARKER" ]; then printf '%s\n' started > "$LAUNCH_MARKER"; fi
    printf '%s\n' 'tab:test'
  SH

  with_env(
    "CMUX_WORKSPACE_ID" => "workspace:3",
    "CMUX_SURFACE_ID" => "surface:8",
    "CMUX_BUNDLED_CLI_PATH" => fake_cmux,
    "CMUX_LOG" => cmux_log,
    "LAUNCH_MARKER" => launch_marker
  ) do
    viewer = ClaudeVisibleSession.run_review(
      shell_command: "/tmp/review-run/start-review",
      run_dir: directory,
      launch_marker: launch_marker
    )
    assert(viewer[:label] == "Cmux right split surface:9", "Cmux viewer should return the new right split")

    FileUtils.rm_f(launch_marker)
    with_env("LAUNCH_MARKER" => nil) do
      viewer = ClaudeVisibleSession.open_cmux_split(
        fake_cmux,
        "/tmp/review-run/start-review",
        launch_marker,
        launch_timeout: 0.01
      )
      assert(viewer.nil?, "Cmux should reject a split whose launcher never acknowledges startup")

      previous_stderr = $stderr
      captured_stderr = StringIO.new
      begin
        $stderr = captured_stderr
        begin
          ClaudeVisibleSession.run_review(
            shell_command: "/tmp/review-run/start-review",
            run_dir: directory,
            launch_marker: launch_marker,
            launch_timeout: 0.01,
            recovery_paths: {
              "Handoff" => "/tmp/review-run/handoff.md",
              "Marker" => "/tmp/review-run/status",
              "Resume command" => "/tmp/review-run/resume-review"
            }
          )
          assert(false, "a launch timeout should stop the launcher")
        rescue SystemExit => e
          assert(e.status == 1, "a launch timeout should exit with status 1")
        end
      ensure
        $stderr = previous_stderr
      end
      assert_includes(captured_stderr.string, "Handoff: /tmp/review-run/handoff.md", "launch failure recovery handoff")
      assert_includes(captured_stderr.string, "Marker: /tmp/review-run/status", "launch failure recovery marker")
      assert_includes(captured_stderr.string, "Resume command: /tmp/review-run/resume-review", "launch failure recovery command")
    end
  end
  cmux = File.read(cmux_log)
  assert_includes(cmux, "--json new-split right --workspace workspace:3 --surface surface:8 --focus true", "Cmux right split")
  assert_includes(cmux, "send --workspace workspace:3 --surface surface:9 /tmp/review-run/start-review", "Cmux command delivery")
  assert_includes(cmux, "send-key --workspace workspace:3 --surface surface:9 Enter", "Cmux command submission")
  assert_includes(cmux, "close-surface --workspace workspace:3 --surface surface:9", "Cmux launch timeout cleanup")
  assert(!cmux.include?("new-surface"), "Cmux viewer should not create a tab")
  assert(!cmux.include?("CLAUDE_REVIEW_HANDOFF_PATH"), "Cmux should receive only the short launcher path")

  with_env(
    "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
    "CMUX_WORKSPACE_ID" => nil,
    "CMUX_SURFACE_ID" => nil,
    "CMUX_BUNDLED_CLI_PATH" => nil,
    "GHOSTTY_LOG" => ghostty_log,
    "LAUNCH_MARKER" => launch_marker
  ) do
    viewer = ClaudeVisibleSession.run_review(
      shell_command: "/tmp/review-run/start-review",
      run_dir: directory,
      launch_marker: launch_marker
    )
    assert(viewer[:label] == "Ghostty tab tab:test", "outside Cmux the viewer should open a Ghostty tab")
  end
  ghostty = File.read(ghostty_log)
  assert_includes(ghostty, "tell application \"Ghostty\"", "Ghostty AppleScript")
  assert_includes(ghostty, "/tmp/review-run/start-review", "Ghostty command delivery")
  assert(!ghostty.include?("CLAUDE_REVIEW_HANDOFF_PATH"), "Ghostty should receive only the short launcher path")
  assert(!ghostty.downcase.include?("zellij"), "Ghostty viewer should not use Zellij")
ensure
  FileUtils.rm_rf(directory) if directory
end

def test_secret_untracked_skip
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, ".env", "LEAK_ME_ENV=1\n")
  write(repo, "config/api_token.txt", "LEAK_ME_TOKEN=1\n")
  write(repo, "auth.rb", "class Auth\nend\n")
  write(repo, "tokens.rb", "TOKENS_SOURCE = true\n")
  write(repo, "password_input.tsx", "export function PasswordInput() {}\n")

  output, status = dry_run(repo, "--intent", "Review secret skips")

  assert(status.success?, "secret untracked dry-run should succeed")
  assert_includes(output, "### .env", "secret untracked")
  assert_includes(output, "### config/api_token.txt", "secret untracked")
  assert_includes(output, "Skipped: likely secret or credential filename.", "secret untracked")
  assert(!output.include?("LEAK_ME_ENV"), "secret untracked: should not include .env contents")
  assert(!output.include?("LEAK_ME_TOKEN"), "secret untracked: should not include token file contents")
  assert_includes(output, "### auth.rb", "secret untracked")
  assert_includes(output, "class Auth", "secret untracked")
  assert_includes(output, "### tokens.rb", "secret untracked")
  assert_includes(output, "TOKENS_SOURCE = true", "secret untracked")
  assert_includes(output, "### password_input.tsx", "secret untracked")
  assert_includes(output, "PasswordInput", "secret untracked")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_project_context_includes_parent_and_repo_authority_files
  parent = Dir.mktmpdir("cr-context-parent-")
  repo = File.join(parent, "child")
  FileUtils.mkdir_p(repo)

  write(parent, "AGENTS.md", "# Parent guidance\n\nUse the small-app rules when judging architecture.\n")
  write(repo, "AGENTS.md", "# Child guidance\n\nPrefer JSON until durable querying is real.\n")
  write(repo, "CLAUDE.md", "@AGENTS.md\n")
  git(repo, "init")
  git(repo, "config", "user.email", "check@example.test")
  git(repo, "config", "user.name", "Self Check")
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello changed\n")

  output, status = dry_run(repo, "--intent", "Review project context")

  assert(status.success?, "project context dry-run should succeed")
  assert_includes(output, "Project context (auto-loaded from authority files", "project context")
  assert_includes(output, "Use the small-app rules when judging architecture.", "project context")
  assert_includes(output, "Prefer JSON until durable querying is real.", "project context")
  assert_includes(output, "### ../AGENTS.md", "project context")
  assert_includes(output, "### AGENTS.md", "project context")
  assert_includes(output, "### CLAUDE.md", "project context")
ensure
  FileUtils.rm_rf(parent) if parent
end

def test_include_repo_bundles_related_diff
  primary = init_repo
  related = init_repo

  write(primary, "primary.txt", "before\n")
  write(primary, "docs/plan.md", "# Plan\n\nCoordinate both repositories.\n")
  write(primary, "docs/workflow.md", "# Workflow\n\nUpdate the related repository.\n")
  commit_all(primary, "initial primary")

  write(related, "AGENTS.md", "# Related guidance\n\nPreserve historical notes.\n")
  write(related, "related.txt", "before\n")
  commit_all(related, "initial related")
  write(related, "related.txt", "after\n")
  write(related, "new-note.md", "new related context\n")

  output, status = dry_run(primary, "--include-repo", related, "--intent", "Review both repos")

  assert(status.success?, "include-repo dry-run should succeed")
  assert_includes(output, "Review target: clean primary working tree with included repositories", "include repo primary")
  assert_includes(output, "# Related Repositories", "include repo")
  assert_includes(output, "Repository: #{File.realpath(related)}", "include repo")
  assert_includes(output, "Preserve historical notes.", "include repo authority")
  assert_includes(output, "+after", "include repo diff")
  assert_includes(output, "new related context", "include repo untracked")

  plan_output, plan_status = dry_run(primary, "--include-repo", related, "--plan", "docs/plan.md", "--intent", "Review both repos against the plan")
  assert(plan_status.success?, "include-repo plan dry-run should succeed")
  assert_includes(plan_output, "Review target: clean primary working tree with included repositories", "include repo plan target")
  assert_includes(plan_output, "Plan supporting context: docs/plan.md", "include repo plan role")

  artifact_output, artifact_status = dry_run(primary, "--include-repo", related, "--artifact", "docs/workflow.md", "--intent", "Review both repos and the workflow")
  assert(artifact_status.success?, "include-repo artifact dry-run should succeed")
  assert_includes(artifact_output, "Review target: clean primary working tree with included repositories", "include repo artifact target")
  assert_includes(artifact_output, "Artifact under review: docs/workflow.md", "include repo artifact")

  commit_all(related, "related changes")

  plan_only_output, plan_only_status = dry_run(primary, "--include-repo", related, "--plan", "docs/plan.md")
  assert(plan_only_status.success?, "plan-only dry-run with clean included repos should succeed")
  assert_includes(plan_only_output, "Review target: plan docs/plan.md", "plan only with clean included repos")

  clean_output, clean_status = dry_run(primary, "--include-repo", related, "--intent", "Review both repos", allow_failure: true)
  assert(!clean_status.success?, "all-clean included repos should not create an empty review")
  assert_includes(clean_output, "No diff content found to review.", "all-clean include repo")
ensure
  FileUtils.rm_rf(primary) if primary
  FileUtils.rm_rf(related) if related
end

tests = [
  method(:test_claude_handoff_hook_tracks_interactive_turns),
  method(:test_completion_waiter),
  method(:test_supported_followup),
  method(:test_generated_resume_script_settles_early_failure),
  method(:test_review_scenarios),
  method(:test_default_claude_configuration),
  method(:test_secret_untracked_skip),
  method(:test_project_context_includes_parent_and_repo_authority_files),
  method(:test_native_viewer_selection),
  method(:test_include_repo_bundles_related_diff)
]

tests.each do |test|
  test.call
  puts "PASS #{test.name}"
end

puts "All self-checks passed."
