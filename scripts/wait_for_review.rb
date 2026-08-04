#!/usr/bin/env ruby
# frozen_string_literal: true

module ClaudeReviewWaiter
  module_function

  TERMINAL_STATES = %w[0 1 130].freeze
  LAUNCHER_GONE = "launcher_gone"

  def wait(marker_path, after: nil, launch_marker: nil, interval: 0.2, output: $stdout)
    loop do
      snapshot = marker_snapshot(marker_path)
      state = snapshot&.first
      if TERMINAL_STATES.include?(state) && (after.nil? || snapshot != after)
        output.puts "Claude review finished with marker #{state}."
        return state
      end
      if launch_marker && !launcher_alive?(launch_marker)
        output.puts "Claude review launcher exited before a terminal marker."
        return LAUNCHER_GONE
      end

      sleep interval
    end
  end

  def launcher_alive?(path)
    pid = Integer(File.read(path).strip, 10)
    return false unless pid.positive?

    Process.kill(0, pid)
    true
  rescue Errno::EPERM
    true
  rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH, ArgumentError
    false
  end

  def live_launch_markers(run_dir)
    Dir.glob(File.join(run_dir, "launched*")).select { |path| launcher_alive?(path) }
  end

  def marker_state(path)
    marker_snapshot(path)&.first
  end

  def marker_snapshot(path)
    File.open(path) do |file|
      state = file.readline.strip
      stat = file.stat
      [state, stat.dev, stat.ino, stat.size, stat.mtime.to_r]
    end
  rescue Errno::ENOENT, EOFError
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  marker_path = ARGV.fetch(0) do
    warn "Usage: #{File.basename($PROGRAM_NAME)} MARKER_PATH"
    exit 2
  end
  state = ClaudeReviewWaiter.wait(marker_path)
  exit(state == "0" ? 0 : 1)
end
