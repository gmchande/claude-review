# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

module ClaudeVisibleSession
  module_function

  PANE_NAME = "Claude Opus 5 Review"
  LAUNCH_ACK_TIMEOUT = 5.0

  def preflight!
    ensure_required_command!("claude")
    if cmux_context?
      ensure_cmux_ready!
    else
      ensure_ghostty_ready!
    end
  end

  def run_review(shell_command:, run_dir:, launch_marker:, recovery_paths: {}, launch_timeout: LAUNCH_ACK_TIMEOUT)
    viewer = if cmux_context?
               open_cmux_split(ensure_cmux_ready!, shell_command, launch_marker, launch_timeout: launch_timeout)
             else
               open_ghostty_tab(shell_command, run_dir, launch_marker, launch_timeout: launch_timeout)
             end

    return viewer if viewer

    warn "The Claude review was not launched."
    recovery_paths.each do |label, path|
      warn "#{label}: #{path}"
    end
    exit 1
  end

  def cmux_context?
    !ENV.fetch("CMUX_WORKSPACE_ID", "").strip.empty? &&
      !ENV.fetch("CMUX_SURFACE_ID", "").strip.empty?
  end

  def cmux_command_path
    bundled_path = ENV.fetch("CMUX_BUNDLED_CLI_PATH", "").strip
    return bundled_path if !bundled_path.empty? && File.executable?(bundled_path)

    path = command_path("cmux")
    return path if path != "cmux" && File.executable?(path)

    app_path = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    app_path if File.executable?(app_path)
  end

  def ensure_cmux_ready!
    path = cmux_command_path
    unless path
      warn "Cmux context detected, but the Cmux CLI is unavailable."
      exit 1
    end

    _stdout, stderr, status = run_command(path, "ping", allow_failure: true)
    unless status.success?
      warn "Cmux context detected, but its control socket is unavailable."
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end

    path
  end

  def open_cmux_split(cmux_path, shell_command, launch_marker, launch_timeout: LAUNCH_ACK_TIMEOUT)
    workspace = ENV.fetch("CMUX_WORKSPACE_ID")
    caller_surface = ENV.fetch("CMUX_SURFACE_ID")

    stdout, stderr, status = run_command(
      cmux_path,
      "--json",
      "new-split",
      "right",
      "--workspace",
      workspace,
      "--surface",
      caller_surface,
      "--focus",
      "true",
      allow_failure: true
    )
    unless status.success?
      warn "Cmux could not create the right-hand Claude review split."
      warn stderr unless stderr.empty?
      return nil
    end

    surface = cmux_ref(stdout, "surface_ref", "surface_id")
    unless surface
      warn "Cmux created a split but returned no surface id. Close the empty split manually."
      return nil
    end

    rename_cmux_tab(cmux_path, workspace, surface)
    unless cmux_send(cmux_path, workspace, surface, shell_command)
      close_cmux_surface(cmux_path, workspace, surface)
      return nil
    end

    unless wait_for_launch(launch_marker, timeout: launch_timeout)
      warn "Cmux opened #{surface}, but the Claude launcher did not acknowledge startup within #{launch_timeout} seconds."
      close_cmux_surface(cmux_path, workspace, surface)
      return nil
    end

    { label: "Cmux right split #{surface}" }
  end

  def wait_for_launch(path, timeout: LAUNCH_ACK_TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      return true if File.size?(path)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def cmux_send(cmux_path, workspace, surface, shell_command)
    _stdout, stderr, status = run_command(
      cmux_path,
      "send",
      "--workspace",
      workspace,
      "--surface",
      surface,
      shell_command,
      allow_failure: true
    )
    unless status.success?
      warn "Cmux opened #{surface}, but could not send the Claude command."
      warn stderr unless stderr.empty?
      return false
    end

    _stdout, stderr, status = run_command(
      cmux_path,
      "send-key",
      "--workspace",
      workspace,
      "--surface",
      surface,
      "Enter",
      allow_failure: true
    )
    unless status.success?
      warn "Cmux opened #{surface}, but could not submit the Claude command."
      warn stderr unless stderr.empty?
      return false
    end

    true
  end

  def rename_cmux_tab(cmux_path, workspace, surface)
    _stdout, stderr, status = run_command(
      cmux_path,
      "rename-tab",
      "--workspace",
      workspace,
      "--surface",
      surface,
      PANE_NAME,
      allow_failure: true
    )
    return if status.success?

    warn "Cmux opened #{surface}, but could not rename it to #{PANE_NAME.inspect}."
    warn stderr unless stderr.empty?
  end

  def close_cmux_surface(cmux_path, workspace, surface)
    _stdout, stderr, status = run_command(
      cmux_path,
      "close-surface",
      "--workspace",
      workspace,
      "--surface",
      surface,
      allow_failure: true
    )
    return if status.success?

    warn "Cmux could not close #{surface} after the partial launch."
    warn stderr unless stderr.empty?
  end

  def cmux_ref(output, *keys)
    response = JSON.parse(output)
    response = response["result"] if response.is_a?(Hash) && response["result"].is_a?(Hash)
    return nil unless response.is_a?(Hash)

    value = keys.map { |key| response[key] }.find { |candidate| candidate.is_a?(String) && !candidate.strip.empty? }
    value&.strip
  rescue JSON::ParserError
    nil
  end

  def ghostty_available?
    return false unless command_available?("osascript") && command_available?("zsh")

    _stdout, _stderr, status = run_command(
      "osascript",
      "-e",
      "id of application \"Ghostty\"",
      allow_failure: true
    )
    status.success?
  end

  def ensure_ghostty_ready!
    ensure_required_command!("osascript")
    ensure_required_command!("zsh")
    return true if ghostty_available?

    warn "Ghostty is unavailable, so the visible Claude review was not launched."
    exit 1
  end

  def open_ghostty_tab(shell_command, run_dir, launch_marker, launch_timeout: LAUNCH_ACK_TIMEOUT)
    return nil unless ghostty_available?

    launch_command = "#{command_path("zsh").shellescape} -lc #{shell_command.shellescape}"
    script = <<~APPLESCRIPT
      tell application "Ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to #{applescript_string(run_dir)}
        set command of cfg to #{applescript_string(launch_command)}
        set wait after command of cfg to true
        if (count of windows) > 0 then
          set newTab to new tab in front window with configuration cfg
          select tab newTab
          set newTabID to id of newTab
        else
          set newWin to new window with configuration cfg
          set newTabID to id of selected tab of newWin
        end if
        activate
        return newTabID
      end tell
    APPLESCRIPT

    stdout, stderr, status = run_command("osascript", allow_failure: true, stdin_data: script)
    if status.success?
      tab_id = stdout.strip
      if wait_for_launch(launch_marker, timeout: launch_timeout)
        return { label: tab_id.empty? ? "Ghostty tab" : "Ghostty tab #{tab_id}" }
      end

      warn "Ghostty opened the Claude review tab, but the launcher did not acknowledge startup within #{launch_timeout} seconds."
      warn "Close the empty or stalled Ghostty tab manually."
      return nil
    end

    warn "Failed to open the Ghostty Claude review tab."
    warn stderr unless stderr.empty?
    nil
  end

  def ensure_required_command!(name)
    return if command_available?(name)

    warn "#{name} not found on PATH."
    exit 1
  end

  def command_available?(name)
    _stdout, _stderr, status = run_command(
      "sh",
      "-c",
      "command -v #{Shellwords.escape(name)} >/dev/null 2>&1",
      allow_failure: true
    )
    status.success?
  end

  def command_path(name)
    stdout, _stderr, status = run_command(
      "sh",
      "-c",
      "command -v #{Shellwords.escape(name)}",
      allow_failure: true
    )
    status.success? && !stdout.strip.empty? ? stdout.strip : name
  end

  def run_command(*command, allow_failure: false, stdin_data: "")
    stdout, stderr, status = Open3.capture3(*command, stdin_data: stdin_data)
    if !status.success? && !allow_failure
      warn "Command failed: #{command.shelljoin}"
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end
    [stdout, stderr, status]
  end

  def applescript_string(value)
    "\"#{value.to_s.gsub("\\", "\\\\\\").gsub('"', '\\"')}\""
  end
end
