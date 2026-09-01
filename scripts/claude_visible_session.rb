# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

module ClaudeVisibleSession
  module_function

  PANE_NAME = "Claude Fable 5 Review"
  LAUNCH_ACK_TIMEOUT = 5.0

  def preflight!
    ensure_required_command!("claude")
    return if cmux_context? && cmux_command_path
    return if ghostty_available?
    return if omarchy_available?

    warn "No visible terminal available. Need Cmux, Ghostty, or omarchy."
    exit 1
  end

  def run_review(shell_command:, run_dir:, launch_marker:, recovery_paths: {}, launch_timeout: LAUNCH_ACK_TIMEOUT)
    viewer = if cmux_context? && cmux_command_path
               open_cmux_split(ensure_cmux_ready!, shell_command, launch_marker, launch_timeout: launch_timeout)
             elsif ghostty_available?
               open_ghostty_viewer(shell_command, run_dir, launch_marker, launch_timeout: launch_timeout)
             elsif omarchy_available?
               open_omarchy_viewer(shell_command, launch_marker, launch_timeout: launch_timeout)
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

  def ghostty_context?
    ENV.fetch("TERM_PROGRAM", "").strip.casecmp("ghostty").zero?
  end

  def current_viewer_name
    if cmux_context? && cmux_command_path
      "Cmux right split"
    elsif ghostty_available?
      ghostty_context? ? "Ghostty right split" : "Ghostty tab"
    elsif omarchy_available?
      "Omarchy terminal"
    else
      "none"
    end
  end

  def omarchy_available?
    command_available?("omarchy")
  end

  def desktop_session_env
    return nil unless command_available?("systemctl")

    listing, _stderr, status = run_command(
      "systemctl",
      "--user",
      "show-environment",
      allow_failure: true
    )
    return nil unless status.success? && !listing.empty?

    names = listing.each_line.filter_map do |line|
      name, = line.chomp.split("=", 2)
      name unless name.nil? || name.empty?
    end
    return nil if names.empty?

    stdout, _stderr, status = run_command(
      "bash",
      "-c",
      'set -a; eval "$(systemctl --user show-environment)"; exec env -0',
      allow_failure: true
    )
    return nil unless status.success? && !stdout.empty?

    decoded = {}
    stdout.split("\0").each do |entry|
      next if entry.empty?

      name, value = entry.split("=", 2)
      decoded[name] = value if name && !value.nil?
    end

    env = {}
    names.each do |name|
      env[name] = decoded[name] if decoded.key?(name)
    end
    env.empty? ? nil : env
  rescue Errno::ENOENT
    nil
  end

  def start_script_path(shell_command)
    Shellwords.split(shell_command.to_s).first
  end

  def open_omarchy_viewer(shell_command, launch_marker, launch_timeout: LAUNCH_ACK_TIMEOUT)
    start_path = start_script_path(shell_command)
    unless start_path && File.executable?(start_path)
      warn "Claude review start script is missing: #{start_path.inspect}"
      return nil
    end

    env = desktop_session_env
    unless env
      warn "Could not read the desktop session environment for the Omarchy terminal."
      return nil
    end

    omarchy = command_path("omarchy")
    begin
      pid = Process.spawn(
        env,
        omarchy,
        "launch",
        "tui",
        "--app-id=org.omarchy.claude-fable-5-review",
        start_path,
        unsetenv_others: true
      )
    rescue Errno::ENOENT
      warn "omarchy not found at #{omarchy.inspect}."
      return nil
    end
    Process.detach(pid)

    unless wait_for_launch(launch_marker, timeout: launch_timeout)
      warn "Opened an Omarchy terminal, but the Claude launcher did not acknowledge startup. The window was left open; close it before using --resume-run."
      return nil
    end

    { label: "Omarchy terminal" }
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
    return false unless command_available?("osascript")

    _stdout, _stderr, status = run_command(
      "osascript",
      "-e",
      "id of application \"Ghostty\"",
      allow_failure: true
    )
    status.success?
  end

  def open_ghostty_viewer(shell_command, run_dir, launch_marker, launch_timeout: LAUNCH_ACK_TIMEOUT)
    return nil unless ghostty_available?

    split = ghostty_context?
    launch_command = start_script_path(shell_command) || shell_command
    create_surface = if split
                       <<~APPLESCRIPT
                         set currentTerm to focused terminal of selected tab of front window
                         set newTerm to split currentTerm direction right with configuration cfg
                         focus newTerm
                         set newTabID to id of selected tab of front window
                         set newTermID to id of newTerm
                       APPLESCRIPT
                     else
                       <<~APPLESCRIPT
                         if (count of windows) > 0 then
                           set newTab to new tab in front window with configuration cfg
                           select tab newTab
                           set newTabID to id of newTab
                           set newTermID to id of focused terminal of newTab
                         else
                           set newWin to new window with configuration cfg
                           set newTabID to id of selected tab of newWin
                           set newTermID to id of focused terminal of selected tab of newWin
                         end if
                         activate
                       APPLESCRIPT
                     end
    script = <<~APPLESCRIPT
      tell application "Ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to #{applescript_string(run_dir)}
        set command of cfg to #{applescript_string(launch_command)}
        set wait after command of cfg to true
        #{create_surface.chomp}
        return (newTabID as text) & linefeed & (newTermID as text)
      end tell
    APPLESCRIPT

    stdout, stderr, status = run_command("osascript", allow_failure: true, stdin_data: script)
    unless status.success?
      warn "Failed to open the Ghostty Claude review #{split ? "split" : "tab"}."
      warn stderr unless stderr.empty?
      return nil
    end

    tab, terminal = stdout.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)
    viewer = {
      label: ghostty_label(placement: split ? "split" : "tab", tab: tab.to_s, terminal: terminal.to_s),
      tab: tab.to_s,
      terminal: terminal.to_s,
      placement: split ? "split" : "tab"
    }
    return viewer if wait_for_launch(launch_marker, timeout: launch_timeout)

    warn "Ghostty opened the Claude review #{split ? "split" : "tab"}, but the launcher did not acknowledge startup within #{launch_timeout} seconds."
    close_ghostty_viewer(viewer)
    nil
  end

  def ghostty_label(placement:, tab:, terminal:)
    if placement == "split"
      target = terminal.empty? ? tab : terminal
      target.empty? ? "Ghostty right split" : "Ghostty right split #{target}"
    else
      target = tab.empty? ? terminal : tab
      target.empty? ? "Ghostty tab" : "Ghostty tab #{target}"
    end
  end

  def close_ghostty_viewer(viewer)
    terminal = viewer[:terminal].to_s.strip
    tab = viewer[:tab].to_s.strip
    if viewer[:placement] == "split"
      if terminal.empty?
        warn "Close the empty or stalled #{viewer[:label]} manually."
        return
      end
      script = <<~APPLESCRIPT
        on run argv
          set targetID to item 1 of argv
          tell application "Ghostty"
            repeat with currentWindow in windows
              repeat with currentTab in tabs of currentWindow
                repeat with currentTerminal in terminals of currentTab
                  if (id of currentTerminal as text) is targetID then
                    close currentTerminal
                    return id of currentTerminal
                  end if
                end repeat
              end repeat
            end repeat
            error "Recorded Ghostty split is no longer open"
          end tell
        end run
      APPLESCRIPT
      target = terminal
    else
      if tab.empty?
        warn "Close the empty or stalled #{viewer[:label]} manually."
        return
      end
      script = <<~APPLESCRIPT
        on run argv
          set targetID to item 1 of argv
          tell application "Ghostty"
            repeat with currentWindow in windows
              repeat with currentTab in tabs of currentWindow
                if (id of currentTab as text) is targetID then
                  close tab currentTab
                  return targetID
                end if
              end repeat
            end repeat
            error "Recorded Ghostty tab is no longer open"
          end tell
        end run
      APPLESCRIPT
      target = tab
    end

    _stdout, stderr, status = run_command("osascript", "-", target, allow_failure: true, stdin_data: script)
    return if status.success?

    warn "Close the empty or stalled #{viewer[:label]} manually."
    warn stderr unless stderr.empty?
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
