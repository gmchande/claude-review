#!/usr/bin/env ruby
# frozen_string_literal: true

module ClaudeReviewWaiter
  module_function

  TERMINAL_STATES = %w[0 1 130].freeze

  def wait(marker_path, after: nil, interval: 0.2, output: $stdout)
    loop do
      snapshot = marker_snapshot(marker_path)
      state = snapshot&.first
      if TERMINAL_STATES.include?(state) && (after.nil? || snapshot != after)
        output.puts "Claude review finished with marker #{state}."
        return state
      end

      sleep interval
    end
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
