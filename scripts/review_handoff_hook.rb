#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"

module ReviewHandoffHook
  module_function

  def run(input, env: ENV, output: $stdout)
    handoff_path = env.fetch("CLAUDE_REVIEW_HANDOFF_PATH")
    marker_path = env.fetch("CLAUDE_REVIEW_MARKER_PATH")
    expected_model = env.fetch("CLAUDE_REVIEW_MODEL")
    expected_effort = env.fetch("CLAUDE_REVIEW_EFFORT")
    event = input.fetch("hook_event_name")

    case event
    when "SessionStart"
      validate_session_start(input, handoff_path, marker_path, expected_model, output)
    when "UserPromptSubmit"
      FileUtils.rm_f(handoff_path)
      atomic_write(marker_path, "running\n")
    when "Stop"
      finish_turn(input, handoff_path, marker_path, expected_model, expected_effort, output)
    when "StopFailure"
      fail_turn(input, handoff_path, marker_path)
    end
  rescue KeyError, JSON::ParserError => e
    output.puts JSON.generate("systemMessage" => "Claude review handoff hook failed: #{e.message}")
  rescue SystemCallError => e
    output.puts JSON.generate("systemMessage" => "Claude review handoff hook could not update its run files: #{e.message}")
  end

  def validate_session_start(input, handoff_path, marker_path, expected_model, output)
    actual_model = input["model"].to_s
    return if actual_model == expected_model

    message = if actual_model.empty?
                "Claude review stopped because Claude Code did not report its active model."
              else
                "Claude review stopped because the active model was #{actual_model.inspect}, not #{expected_model.inspect}."
              end
    atomic_write(handoff_path, "#{message}\n")
    atomic_write(marker_path, "1\n")
    output.puts JSON.generate("continue" => false, "stopReason" => message)
  end

  def finish_turn(input, handoff_path, marker_path, expected_model, expected_effort, output)
    return unless validate_turn_model(input, handoff_path, marker_path, expected_model, output)

    effort = input["effort"]
    actual_effort = effort.is_a?(Hash) ? effort["level"].to_s : ""
    if actual_effort != expected_effort
      message = if actual_effort.empty?
                  "Claude review failed because Claude Code did not report the turn effort."
                else
                  "Claude review failed because the turn used #{actual_effort.inspect} effort, not #{expected_effort.inspect}."
                end
      atomic_write(handoff_path, "#{message}\n")
      atomic_write(marker_path, "1\n")
      output.puts JSON.generate("systemMessage" => message)
      return
    end

    message = input["last_assistant_message"].to_s.strip
    if message.empty?
      message = "Claude review turn ended without a final text response."
      status = "1\n"
    else
      status = "0\n"
    end

    atomic_write(handoff_path, "#{message}\n")
    atomic_write(marker_path, status)
  end

  def validate_turn_model(input, handoff_path, marker_path, expected_model, output)
    models = transcript_models(input["transcript_path"])
    unexpected_models = models.reject { |model| model == expected_model }
    return true if !models.empty? && unexpected_models.empty?

    message = if models.empty?
                "Claude review failed because its transcript did not report an assistant model."
              else
                "Claude review failed because its transcript used #{unexpected_models.map(&:inspect).join(", ")}, not exclusively #{expected_model.inspect}."
              end
    atomic_write(handoff_path, "#{message}\n")
    atomic_write(marker_path, "1\n")
    output.puts JSON.generate("systemMessage" => message)
    false
  end

  def transcript_models(path)
    return [] if path.to_s.empty?

    models = []
    File.foreach(path) do |line|
      entry = JSON.parse(line)
      next unless entry.is_a?(Hash) && entry["type"] == "assistant"

      message = entry["message"]
      next unless message.is_a?(Hash)

      model = message["model"].to_s.strip
      next if model == "<synthetic>"

      models << model unless model.empty?
    rescue JSON::ParserError
      next
    end
    models.uniq
  rescue SystemCallError
    []
  end

  def fail_turn(input, handoff_path, marker_path)
    message = input["last_assistant_message"].to_s.strip
    message = input["error"].to_s.tr("_", " ") if message.empty?
    message = "Claude review failed without an error message." if message.empty?
    details = input["error_details"].to_s.strip
    message = "#{message}\n\n#{details}" unless details.empty? || message.include?(details)

    atomic_write(handoff_path, "#{message}\n")
    atomic_write(marker_path, "1\n")
  end

  def atomic_write(path, content)
    temporary_path = "#{path}.#{Process.pid}.tmp"
    File.open(temporary_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(content)
    end
    File.rename(temporary_path, path)
  ensure
    FileUtils.rm_f(temporary_path) if defined?(temporary_path)
  end
end

if $PROGRAM_NAME == __FILE__
  ReviewHandoffHook.run(JSON.parse($stdin.read))
end
