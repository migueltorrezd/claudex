#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

unless (1..2).cover?(ARGV.length)
  warn "usage: configure-proxy-transport.rb CONFIG_PATH [http|websocket|auto]"
  exit 2
end

config_path = File.expand_path(ARGV.fetch(0))
desired_transport = ARGV[1]

if desired_transport && !%w[http websocket auto].include?(desired_transport)
  warn "proxy config: unsupported Codex transport: #{desired_transport}"
  exit 2
end

if File.symlink?(config_path)
  warn "proxy config: refusing to replace symlink: #{config_path}"
  exit 1
end

begin
  config = if File.file?(config_path)
             raw_config = File.binread(config_path)
             raw_config.strip.empty? ? {} : JSON.parse(raw_config)
           else
             {}
           end
rescue JSON::ParserError => error
  warn "proxy config: malformed JSON in #{config_path}: #{error.message}"
  exit 1
end

unless config.is_a?(Hash)
  warn "proxy config: expected a JSON object in #{config_path}"
  exit 1
end

codex_config = config["codex"]
unless codex_config.nil? || codex_config.is_a?(Hash)
  warn "proxy config: expected codex to be an object in #{config_path}"
  exit 1
end

if desired_transport.nil?
  puts codex_config&.fetch("transport", "unset") || "unset"
  exit 0
end

codex_config ||= {}
if codex_config["transport"] == desired_transport
  puts "Proxy Codex transport already set to #{desired_transport}: #{config_path}"
  exit 0
end

config["codex"] = codex_config
codex_config["transport"] = desired_transport

config_dir = File.dirname(config_path)
FileUtils.mkdir_p(config_dir, mode: 0o700)
file_mode = File.file?(config_path) ? File.stat(config_path).mode & 0o777 : 0o600

if File.file?(config_path)
  backup_path = "#{config_path}.backup-#{Time.now.strftime("%Y%m%d%H%M%S")}-#{Process.pid}"
  FileUtils.cp(config_path, backup_path, preserve: true)
  puts "Backed up existing proxy config to #{backup_path}"
end

temporary = Tempfile.new([".config", ".json"], config_dir)
begin
  temporary.chmod(file_mode)
  temporary.write(JSON.pretty_generate(config))
  temporary.write("\n")
  temporary.flush
  temporary.fsync
  temporary.close
  File.rename(temporary.path, config_path)
ensure
  temporary.close unless temporary.closed?
  temporary.unlink if File.exist?(temporary.path)
end

puts "Set proxy Codex transport to #{desired_transport}: #{config_path}"
