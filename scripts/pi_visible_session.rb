# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"

module PiVisibleSession
  module_function

  SKILL_NAME = "claude-review"
  PANE_NAME = "Kimi K3 Review"

  def run_review(
    session:,
    repo_root:,
    pi_shell_command:,
    handoff_path:,
    done_marker_path:
  )
    ensure_required_command!("zellij")
    ensure_required_command!("pi")
    ensure_required_command!("zsh")
    ensure_zellij_socket_dir!

    _stdout, stderr, status = zellij("attach", "--create-background", session, allow_failure: true)
    unless status.success?
      warn "Failed to create Zellij background session: #{session}"
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end

    stdout, stderr, status = zellij(
      "--session",
      session,
      "run",
      "--in-place",
      "--close-replaced-pane",
      "--cwd",
      repo_root,
      "--name",
      PANE_NAME,
      "--",
      "zsh",
      "-lc",
      pi_shell_command,
      allow_failure: true
    )

    unless status.success?
      warn "Failed to create Zellij Pi pane in session: #{session}"
      warn stderr unless stderr.empty?
      delete_zellij_session(session)
      exit status.exitstatus || 1
    end

    pane_id = stdout.strip
    if pane_id.empty?
      warn "Zellij did not return a pane id; cannot safely watch the review."
      delete_zellij_session(session)
      exit 1
    end

    ghostty_opened = open_ghostty_attach(session, repo_root)
    warn "Ghostty auto-open unavailable; the review is still running. Attach manually with `#{zellij_shell_command("attach", session)}`." unless ghostty_opened

    puts "Interactive Kimi K3 review started: #{session}"
    puts "Attach: #{zellij_shell_command("attach", session)}"
    puts "Handoff: #{handoff_path}"
    puts "Marker: #{done_marker_path}"
    puts "Marker states: running=active; 0=complete; 130=interrupted; 1=failed. Ctrl+D is not needed for handoff."
    puts "Controls: Escape interrupts; Enter sends a follow-up; Ctrl+D exits Pi."
    puts "Never relaunch this review without explicit user approval."
    puts "Cleanup only after the user is finished: #{zellij_shell_command("delete-session", "--force", session)}"
  end

  def ensure_required_command!(name)
    return if command_available?(name)

    if name == "zellij"
      warn "Zellij is required for #{SKILL_NAME}. Install it with `brew install zellij` and rerun this command."
    else
      warn "#{name} not found on PATH."
    end
    exit 1
  end

  def ensure_zellij_socket_dir!
    socket_dir = ENV.fetch("ZELLIJ_SOCKET_DIR", "").strip
    socket_dir = "/tmp/zellij-#{Process.uid}" if socket_dir.empty?
    ENV["ZELLIJ_SOCKET_DIR"] = socket_dir

    begin
      FileUtils.mkdir_p(socket_dir)
    rescue SystemCallError => e
      warn "Could not create ZELLIJ_SOCKET_DIR for #{SKILL_NAME} #{socket_dir.inspect}: #{e.message}"
      exit 1
    end

    socket_dir
  end

  def run_command(*cmd, allow_failure: false)
    stdout, stderr, status = Open3.capture3(*cmd)
    if !status.success? && !allow_failure
      warn "Command failed: #{cmd.shelljoin}"
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end
    [stdout, stderr, status]
  end

  def command_available?(name)
    _stdout, _stderr, status = run_command("sh", "-c", "command -v #{Shellwords.escape(name)} >/dev/null 2>&1", allow_failure: true)
    status.success?
  end

  def zellij(*args, allow_failure: false)
    stdout, stderr, status = run_command("zellij", *args, allow_failure: true)
    if !status.success? && !allow_failure
      warn "Command failed: #{zellij_shell_command(*args)}"
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end

    [stdout, stderr, status]
  end

  def zellij_shell_command(*args)
    (["env", "ZELLIJ_SOCKET_DIR=#{ENV.fetch("ZELLIJ_SOCKET_DIR")}", "zellij"] + args).shelljoin
  end

  def delete_zellij_session(session)
    zellij("delete-session", "--force", session, allow_failure: true)
  end

  def applescript_string(value)
    "\"#{value.to_s.gsub("\\", "\\\\\\").gsub('"', '\\"')}\""
  end

  def command_path(name)
    stdout, _stderr, status = run_command("sh", "-c", "command -v #{Shellwords.escape(name)}", allow_failure: true)
    return stdout.strip if status.success? && !stdout.strip.empty?

    name
  end

  def open_ghostty_attach(session, repo_root)
    unless command_available?("osascript")
      warn "osascript not found; skipping Ghostty auto-open."
      return false
    end

    attach_inner = "export ZELLIJ_SOCKET_DIR=#{ENV.fetch("ZELLIJ_SOCKET_DIR").shellescape}; " \
                   "#{command_path("zellij").shellescape} attach #{session.shellescape}"
    attach_command = "#{command_path("zsh").shellescape} -lc #{Shellwords.escape(attach_inner)}"

    script = <<~APPLESCRIPT
      tell application "Ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to #{applescript_string(repo_root)}
        set command of cfg to #{applescript_string(attach_command)}
        set wait after command of cfg to true
        if (count of windows) > 0 then
          set newTab to new tab in front window with configuration cfg
          select tab newTab
        else
          set newWin to new window with configuration cfg
        end if
        activate
      end tell
    APPLESCRIPT

    _stdout, stderr, status = Open3.capture3("osascript", stdin_data: script)
    return true if status.success?

    warn "Failed to open Ghostty attached to Zellij session: #{session}"
    warn stderr unless stderr.empty?
    false
  end
end
