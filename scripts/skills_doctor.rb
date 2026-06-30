#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "optparse"
require "open3"
require "pathname"
require "tmpdir"
require "uri"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
GIT_PATHSPEC_ENV_KEYS = %w[
  GIT_LITERAL_PATHSPECS
  GIT_GLOB_PATHSPECS
  GIT_NOGLOB_PATHSPECS
  GIT_ICASE_PATHSPECS
].freeze
GIT_REPOSITORY_ENV_KEYS = %w[
  GIT_DIR
  GIT_WORK_TREE
  GIT_COMMON_DIR
  GIT_INDEX_FILE
].freeze
GIT_CONFIG_OVERRIDE_ENV_KEYS = %w[
  GIT_CONFIG_PARAMETERS
].freeze
GIT_CONFIG_OVERRIDE_ENV_PREFIXES = %w[
  GIT_CONFIG_KEY_
  GIT_CONFIG_VALUE_
].freeze
DEFAULT_SKILLS_CLI_PACKAGE = "skills@1.5.14"
DEFAULT_MANAGER_REGISTRY_SOURCE = ENV.fetch("SKILLS_DOCTOR_MANAGER_REGISTRY_SOURCE", "fiveonecode/agent-skills")
DEFAULT_MANAGER_REGISTRY_SOURCE_TYPE = ENV.fetch("SKILLS_DOCTOR_MANAGER_REGISTRY_SOURCE_TYPE", "github")

class Reporter
  attr_reader :errors, :warnings

  def initialize(quiet: false)
    @errors = []
    @warnings = []
    @quiet = quiet
  end

  def section(title)
    return if @quiet

    puts
    puts "## #{title}"
  end

  def ok(message)
    return if @quiet

    puts "- ok: #{message}"
  end

  def info(message)
    return if @quiet

    puts "- info: #{message}"
  end

  def warn(message)
    @warnings << message
    if @quiet
      warn_stream = $stderr
      warn_stream.puts "warning: #{message}"
      return
    end

    puts "- warning: #{message}"
  end

  def error(message)
    @errors << message
    if @quiet
      warn_stream = $stderr
      warn_stream.puts "error: #{message}"
      return
    end

    puts "- error: #{message}"
  end
end

def load_yaml_file(path, reporter)
  content = File.read(path)
  parsed = YAML.safe_load(content, aliases: false)
  parsed.nil? ? {} : parsed
rescue Psych::Exception => error
  reporter.error("#{display_path(path)} is not valid YAML: #{error.message}")
  nil
rescue Errno::ENOENT
  reporter.error("#{display_path(path)} does not exist")
  nil
rescue SystemCallError => error
  reporter.error("#{display_path(path)} could not be read: #{redact_local_paths(error.message)}")
  nil
end

def load_json_file(path, reporter, label: display_path(path), warning_only: false)
  content = File.read(path)
  JSON.parse(content)
rescue JSON::ParserError => error
  message = "#{label} is not valid JSON: #{error.message}"
  warning_only ? reporter.warn(message) : reporter.error(message)
  nil
rescue Errno::ENOENT
  message = "#{label} does not exist"
  warning_only ? reporter.warn(message) : reporter.error(message)
  nil
rescue SystemCallError => error
  message = "#{label} could not be read: #{redact_local_paths(error.message)}"
  warning_only ? reporter.warn(message) : reporter.error(message)
  nil
end

def ensure_mapping(value, reporter, message, allow_nil: false)
  return {} if value.nil? && allow_nil
  return value if value.is_a?(Hash)

  reporter.error(message)
  {}
end

def display_path(path, show_local_paths: ENV.fetch("SKILLS_DOCTOR_SHOW_PATHS", "0") == "1")
  expanded = File.expand_path(path.to_s)
  home = File.expand_path("~")
  root = ROOT.to_s

  return path.to_s if !path.to_s.start_with?("/") && !path.to_s.start_with?("~")
  return expanded if show_local_paths
  return "." if expanded == root
  return "./#{expanded.delete_prefix("#{root}/")}" if expanded.start_with?("#{root}/")
  return "~" if expanded == home
  return "~/#{expanded.delete_prefix("#{home}/")}" if expanded.start_with?("#{home}/")

  "<absolute-path>"
end

def redact_local_paths(text, show_local_paths: ENV.fetch("SKILLS_DOCTOR_SHOW_PATHS", "0") == "1")
  return text.to_s if show_local_paths

  text
    .to_s
    .gsub(%r{(["'])/.*?\1}) do |match|
      quote = match[0]
      "#{quote}<absolute-path>#{quote}"
    end
    .gsub(%r{ - /[^\n]*}, " - <absolute-path>")
    .gsub(%r{(?<![[:alnum:]_.-])/(?:[^[:space:]]+)}, "<absolute-path>")
end

def expand_config_path(path, base_dir: ROOT)
  value = path.to_s
  return File.expand_path(value.delete_prefix("~/"), Dir.home) if value.start_with?("~/")

  File.expand_path(value, base_dir)
end

def valid_path_string?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if value.start_with?("~") && value != "~" && !value.start_with?("~/")

  Pathname.new(value)
  true
rescue ArgumentError
  false
end

def valid_argv_string?(value)
  value.is_a?(String) && !value.include?("\0")
end

def contains_non_nul_control_characters?(value)
  value.is_a?(String) && /[\x01-\x1F\x7F]/.match?(value)
end

def valid_git_tag_name?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if value.start_with?("refs/")

  _stdout, _stderr, status = Open3.capture3("git", "check-ref-format", "refs/tags/#{value}")
  status.success?
rescue SystemCallError, ArgumentError
  false
end

def local_file_url?(value)
  value.is_a?(String) && /\Afile:/i.match?(value)
end

def home_relative_url?(value)
  value.is_a?(String) && value.start_with?("~")
end

def scheme_url?(value)
  value.is_a?(String) && /\A[a-z][a-z0-9+.-]*:\/\//i.match?(value)
end

def scp_like_url?(value)
  value.is_a?(String) && /\A(?:[^\/@\s]+@)?[^\/:\s]+:.+\z/.match?(value)
end

def ext_remote_url?(value)
  value.is_a?(String) && value.start_with?("ext::")
end

def url_scheme(value)
  match = /\A([a-z][a-z0-9+.-]*):/i.match(value.to_s)
  match && match[1]
end

def remote_helper_transport_url?(value)
  raw_scheme = url_scheme(value)
  return false if raw_scheme.nil? || ext_remote_url?(value)

  return true if value.to_s.match?(/\A[a-z][a-z0-9+.-]*::/i)
  return false unless scheme_url?(value)

  scheme = raw_scheme.downcase
  return true if raw_scheme != scheme
  !%w[file git http https ssh ftp ftps rsync].include?(scheme)
end

def scheme_url_authority(value)
  return nil unless scheme_url?(value)

  value.sub(/\A[a-z][a-z0-9+.-]*:\/\//i, "").split(/[\/?#]/, 2).first
end

def http_url_authority(value)
  return nil unless value.is_a?(String) && /\Ahttps?:\/\//i.match?(value)

  scheme_url_authority(value)
end

def credential_bearing_scheme_url?(value)
  authority = scheme_url_authority(value)
  return false if authority.nil? || authority.empty?
  return true if authority.include?("@")

  uri = URI.parse(value)
  uri.respond_to?(:userinfo) && !uri.userinfo.to_s.empty?
rescue URI::InvalidURIError
  authority.include?("@")
end

def valid_http_remote_url?(value)
  return false unless value.is_a?(String) && /\Ahttps?:\/\//i.match?(value)

  uri = URI.parse(value)
  uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
rescue URI::InvalidURIError
  false
end

def valid_remote_scheme_url?(value)
  return false unless scheme_url?(value)

  uri = URI.parse(value)
  !uri.scheme.to_s.empty? && !uri.host.to_s.empty?
rescue URI::InvalidURIError
  false
end

def relative_upstream_url?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if scheme_url?(value)
  return false if scp_like_url?(value)
  return false if home_relative_url?(value)
  return false if Pathname.new(value).absolute?

  safe_relative_path?(value) && (value.start_with?(".") || value.include?("/") || value.end_with?(".git"))
rescue ArgumentError
  false
end

def path_within_root?(path, root)
  path_string = path.to_s
  root_string = root.to_s
  path_string == root_string || path_string.start_with?(root_string + File::SEPARATOR)
end

def registry_relative_upstream_candidate(url, registry_root)
  return nil unless safe_relative_path?(url)
  return nil if scheme_url?(url) || scp_like_url?(url) || home_relative_url?(url)
  return nil if Pathname.new(url).absolute?

  registry_root.join(url).cleanpath
rescue ArgumentError
  nil
end

def resolved_registry_relative_upstream_path(url, registry_root)
  candidate = registry_relative_upstream_candidate(url, registry_root)
  return nil if candidate.nil? || !candidate.exist?

  candidate_realpath = candidate.realpath
  root_realpath = registry_root.realpath
  return nil unless path_within_root?(candidate_realpath, root_realpath)

  candidate_realpath
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, SystemCallError
  nil
end

def relative_upstream_resolves_outside_registry?(url, registry_root)
  candidate = registry_relative_upstream_candidate(url, registry_root)
  return false if candidate.nil? || !candidate.exist?

  candidate_realpath = candidate.realpath
  root_realpath = registry_root.realpath
  !path_within_root?(candidate_realpath, root_realpath)
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, SystemCallError
  false
end

def valid_git_object_id?(value)
  return false unless value.is_a?(String) && /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i.match?(value)

  !value.match?(/\A0+\z/)
end

def valid_sha256_hex?(value)
  value.is_a?(String) && /\A[0-9a-f]{64}\z/i.match?(value)
end

def safe_relative_path?(path)
  value = path.to_s
  return false if value.empty?
  return false unless valid_argv_string?(value)
  return false if contains_non_nul_control_characters?(value)
  return false if value.start_with?("/")
  return false if Pathname.new(value).each_filename.any? { |part| part == ".." }

  Pathname.new(value).cleanpath.each_filename.none? { |part| part == ".." }
rescue ArgumentError
  false
end

def top_level_skill_path?(path)
  return false unless safe_relative_path?(path)

  parts = Pathname.new(path.to_s).each_filename.to_a
  parts.length == 1 && parts[0] == path.to_s && parts[0] != "."
rescue ArgumentError
  false
end

def safe_adapter_name?(name)
  value = name.to_s
  return false if value.empty? || value.strip.empty?
  return false unless valid_argv_string?(value)
  return false if contains_non_nul_control_characters?(value)
  return false if value.start_with?("/")
  return false if value == "." || value == ".."

  cleaned = Pathname.new(value).cleanpath.to_s
  parts = Pathname.new(value).each_filename.to_a
  cleaned == value && parts.length == 1 && parts[0] == value
rescue ArgumentError
  false
end

def path_within?(path, root)
  path_value = Pathname.new(path).to_s
  root_value = Pathname.new(root).to_s
  path_value == root_value || path_value.start_with?("#{root_value}/")
end

def repo_skill_entrypoint_name(path)
  parts = path.split(File::SEPARATOR)
  agents_index = (0...(parts.length - 1)).to_a.reverse.find { |index| parts[index] == ".agents" && parts[index + 1] == "skills" }
  return nil unless agents_index && parts.length == agents_index + 4

  parts[agents_index + 2]
end

def directory_digest(dir, reporter)
  digest = Digest::SHA256.new
  files = []
  invalid = false
  Find.find(dir) do |entry|
    if File.symlink?(entry)
      reporter.error("#{display_path(entry)} must not be a symlink")
      invalid = true
      Find.prune if File.directory?(entry)
      next
    end

    next if File.directory?(entry)
    unless File.file?(entry)
      reporter.error("#{display_path(entry)} must be a regular file")
      invalid = true
      next
    end

    files << entry
  end
  return nil if invalid

  files.sort.each do |file|
    relative = Pathname.new(file).relative_path_from(Pathname.new(dir)).to_s
    digest.update(relative)
    digest.update("\0")
    digest.update(format("%03o", File.stat(file).mode & 0o111))
    digest.update("\0")
    digest.update(File.binread(file))
    digest.update("\0")
  end
  digest.hexdigest
rescue SystemCallError => error
  reporter.error("#{display_path(dir)} could not be hashed cleanly: #{redact_local_paths(error.message)}")
  nil
end

def frontmatter(path, reporter)
  lines = File.readlines(path, chomp: true)
  unless lines.first == "---"
    reporter.error("#{display_path(path)} is missing YAML front matter")
    return {}
  end

  closing = lines[1..]&.index("---")
  unless closing
    reporter.error("#{display_path(path)} has unterminated YAML front matter")
    return {}
  end

  metadata = YAML.safe_load(lines[1, closing].join("\n"), aliases: false) || {}
  return metadata if metadata.is_a?(Hash)

  reporter.error("#{display_path(path)} front matter must be a mapping")
  {}
rescue Psych::Exception => error
  reporter.error("#{display_path(path)} front matter is not valid YAML: #{error.message}")
  {}
rescue SystemCallError => error
  reporter.error("#{display_path(path)} could not be read: #{redact_local_paths(error.message)}")
  {}
end

def git_status_entries(root)
  checkout_root = Pathname.new(root).realpath
  until checkout_root.join(".git").exist?
    parent = checkout_root.parent
    return [] if parent == checkout_root

    checkout_root = parent
  end

  stdout, stderr, status = Open3.capture3(
    sanitized_git_env(clear_repository_env: true, clear_pathspec_env: true),
    "git",
    "-C",
    root.to_s,
    "status",
    "--porcelain"
  )
  unless status.success?
    message = stderr.to_s.strip
    message = message.empty? ? "git status exited with status #{status.exitstatus}" : redact_local_paths(message)
    yield(message) if block_given?
    return nil
  end

  stdout.lines.map(&:chomp).reject(&:empty?)
rescue SystemCallError => error
  yield(redact_local_paths(error.message)) if block_given?
  nil
end

def git_path_status_entries(root, pathspec)
  checkout_root = Pathname.new(root).realpath
  until checkout_root.join(".git").exist?
    parent = checkout_root.parent
    return [] if parent == checkout_root

    checkout_root = parent
  end

  stdout, _stderr, status = Open3.capture3(
    sanitized_git_env(clear_repository_env: true, clear_pathspec_env: true),
    "git",
    "-C",
    root.to_s,
    "status",
    "--porcelain",
    "--ignored=matching",
    "--untracked-files=all",
    "--",
    ":(literal)#{pathspec}"
  )
  unless status.success?
    stderr = _stderr.to_s.strip
    message = stderr.empty? ? "git status exited with status #{status.exitstatus}" : redact_local_paths(stderr)
    yield(message) if block_given?
    return nil
  end

  stdout.lines.map(&:chomp).reject(&:empty?)
rescue SystemCallError => error
  yield(redact_local_paths(error.message)) if block_given?
  nil
end

def git_ls_remote_tag(url, tag)
  stdout, stderr, status = Open3.capture3(
    sanitized_git_env(
      clear_repository_env: true,
      clear_git_config_env: true,
      disable_interactive_prompts: true
    ),
    "git",
    "ls-remote",
    "--tags",
    "--end-of-options",
    url.to_s,
    "refs/tags/#{tag}",
    "refs/tags/#{tag}^{}",
    chdir: "/"
  )
  refs = stdout.lines.each_with_object({}) do |line, memo|
    hash, ref = line.split(/\s+/, 2)
    next if hash.nil? || ref.nil?

    memo[ref.strip] = hash
  end
  [refs, stderr, status]
end

def sanitized_git_env(clear_repository_env: false, clear_pathspec_env: false, clear_git_config_env: false, disable_interactive_prompts: false)
  env = {}

  if clear_repository_env
    GIT_REPOSITORY_ENV_KEYS.each do |key|
      env[key] = nil
    end
  end

  if clear_pathspec_env
    GIT_PATHSPEC_ENV_KEYS.each do |key|
      env[key] = nil
    end
  end

  if clear_git_config_env
    GIT_CONFIG_OVERRIDE_ENV_KEYS.each do |key|
      env[key] = nil
    end
    GIT_CONFIG_OVERRIDE_ENV_PREFIXES.each do |prefix|
      ENV.each_key do |key|
        env[key] = nil if key.start_with?(prefix)
      end
    end
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_SYSTEM"] = File::NULL
    env["GIT_CONFIG_GLOBAL"] = File::NULL
    env["GIT_CONFIG_COUNT"] = "0"
  end

  if disable_interactive_prompts
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_ASKPASS"] = "false"
    env["SSH_ASKPASS"] = "false"
    env["SSH_ASKPASS_REQUIRE"] = "never"
    env["GCM_INTERACTIVE"] = "never"
    env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes"
  end

  env
end

def resolve_upstream_url(url, registry_root)
  resolved = resolved_registry_relative_upstream_path(url, registry_root)
  return resolved.to_s unless resolved.nil?

  url
end

def unresolved_bare_upstream_url?(url, registry_root)
  return false unless safe_relative_path?(url)
  return false if scheme_url?(url) || scp_like_url?(url) || home_relative_url?(url)
  return false if Pathname.new(url).absolute?

  parts = Pathname.new(url).each_filename.to_a
  return false unless parts.length == 1 && parts[0] == url

  !registry_root.join(url).cleanpath.exist?
rescue ArgumentError
  false
end

def unresolved_relative_upstream_url?(url, registry_root)
  relative_upstream_url?(url) && resolved_registry_relative_upstream_path(url, registry_root).nil?
end

def registry_skills(skills, reporter)
  return [] unless skills.is_a?(Array)

  skills.each_with_index.each_with_object([]) do |(skill, index), memo|
    if skill.is_a?(Hash)
      memo << skill
    else
      reporter.error("skills[#{index}] must be a mapping")
    end
  end
end

def mapping_array(value, reporter, label, allow_nil: false)
  return [] if value.nil? && allow_nil
  unless value.is_a?(Array)
    reporter.error("#{label} must be an array")
    return []
  end

  value.each_with_index.each_with_object([]) do |(entry, index), memo|
    if entry.is_a?(Hash)
      memo << entry
    else
      reporter.error("#{label}[#{index}] must be a mapping")
    end
  end
end

def string_array(value, reporter, label)
  unless value.is_a?(Array)
    reporter.error("#{label} must be an array of strings")
    return []
  end

  value.each_with_index.each_with_object([]) do |(entry, index), memo|
    if entry.is_a?(String)
      memo << entry
    else
      reporter.error("#{label}[#{index}] must be a string")
    end
  end
end

def normalize_consumer_roots(consumer_roots, reporter, label)
  return {} unless consumer_roots.is_a?(Hash)

  consumer_roots.each_with_object({}) do |(consumer, root_config), memo|
    unless consumer.is_a?(String) && !consumer.empty?
      reporter.error("#{label} consumer_roots keys must be non-empty strings")
      next
    end

    consumer_name = consumer
    if root_config.is_a?(Hash)
      memo[consumer_name] = root_config
    else
      reporter.error("#{label} consumer_roots.#{consumer_name} must be a mapping")
      memo[consumer_name] = {}
    end
  end
end

def profile_paths(options, registry_path)
  return options[:profiles].map { |path| File.expand_path(path) } unless options[:profiles].empty?

  registry_root = File.dirname(File.expand_path(registry_path))
  Dir.glob(File.join(registry_root, "profiles/**/*.yaml")).sort
end

def validate_registry(registry_path, registry, options, reporter)
  reporter.section("Registry")
  unless registry.is_a?(Hash)
    reporter.error("#{display_path(registry_path)} must contain a top-level mapping") unless registry.nil?
    return {}
  end

  registry_root = Pathname.new(File.dirname(registry_path)).realpath
  registry_root_real = registry_root.realpath
  registry_metadata = ensure_mapping(registry["registry"], reporter, "registry metadata must be a mapping", allow_nil: true)
  raw_skills = registry["skills"]
  id = registry_metadata["id"]
  name = registry_metadata["name"]
  skills = registry_skills(raw_skills, reporter)
  reporter.ok("registry #{id || "(missing id)"} / #{name || "(missing name)"} declares #{skills.length} skill entries")

  reporter.error("registry.id must be a string") unless id.nil? || id.is_a?(String)
  reporter.error("registry.name must be a string") unless name.nil? || name.is_a?(String)
  reporter.error("registry.id is required") if !id.is_a?(String) || id.empty?
  reporter.error("registry.name is required") if !name.is_a?(String) || name.empty?
  reporter.error("skills must be a non-empty array") unless raw_skills.is_a?(Array) && !raw_skills.empty?

  ids = {}
  resolved = {}
  exported_name_owners = {}

  if options[:print_lock]
    manifest_path = Pathname.new(registry_path).realpath.relative_path_from(registry_root_real).to_s
    manifest_status_entries = git_path_status_entries(registry_root, manifest_path) do |message|
      reporter.error("registry manifest git status check failed: #{message}")
    end
    if manifest_status_entries.nil?
      # git failure already reported
    elsif !manifest_status_entries.empty?
      reporter.error("registry manifest has unreviewed git changes; commit or clean changes before --print-lock")
    end
  end

  skills.each do |skill|
    unless skill["id"].is_a?(String)
      reporter.error("skill entry id must be a string")
      next
    end

    skill_id = skill["id"].to_s
    unless valid_argv_string?(skill_id) && !contains_non_nul_control_characters?(skill_id)
      reporter.error("skill entry id must not contain control characters")
      next
    end
    source = skill["source"] || {}
    exported_names = string_array(skill["exported_names"], reporter, "#{skill_id}: exported_names")

    if skill_id.strip.empty?
      reporter.error("skill entry is missing id")
      next
    end

    if ids.key?(skill_id)
      reporter.error("duplicate skill id #{skill_id}")
    else
      ids[skill_id] = true
    end

    reporter.error("#{skill_id}: exported_names must not be empty") if exported_names.empty?
    exported_names.each do |exported_name|
      if exported_name.strip.empty?
        reporter.error("#{skill_id}: exported_names entries must not be empty")
        next
      end

      unless safe_adapter_name?(exported_name)
        display_name = valid_argv_string?(exported_name) && !contains_non_nul_control_characters?(exported_name) ? exported_name : exported_name.inspect
        reporter.error("#{skill_id}: exported_name #{display_name} must be a safe adapter directory name")
        next
      end

      owner = exported_name_owners[exported_name]
      if owner.nil?
        exported_name_owners[exported_name] = skill_id
      elsif owner == skill_id
        reporter.error("#{skill_id}: exported_name #{exported_name} is duplicated")
      else
        reporter.error("#{skill_id}: exported_name #{exported_name} already belongs to #{owner}")
      end
    end
    unless source.is_a?(Hash)
      reporter.error("#{skill_id}: source must be a mapping")
      next
    end

    case source["type"]
    when "registry-local"
      unless source["path"].is_a?(String)
        reporter.error("#{skill_id}: registry-local source.path must be a string")
        next
      end

      source_path = source["path"].to_s
      unless safe_relative_path?(source_path)
        reporter.error("#{skill_id}: registry-local source.path must be a safe relative path")
        next
      end
      unless top_level_skill_path?(source_path)
        reporter.error("#{skill_id}: registry-local source.path must name a top-level skill directory")
        next
      end

      skill_dir = registry_root.join(source_path).cleanpath
      skill_file = skill_dir.join("SKILL.md")
      unless skill_dir.directory?
        reporter.error("#{skill_id}: source directory #{source_path} is missing")
        next
      end

      if skill_dir.symlink?
        reporter.error("#{skill_id}: registry-local source.path must not be a symlink")
        next
      end

      unless path_within?(skill_dir.realpath, registry_root_real)
        reporter.error("#{skill_id}: registry-local source.path must stay within registry root")
        next
      end

      if options[:print_lock]
        real_source_path = skill_dir.realpath.relative_path_from(registry_root_real).to_s
        declared_pathspecs = Pathname.new(source_path).each_filename.each_with_object([]) do |part, memo|
          memo << (memo.empty? ? part : File.join(memo.last, part))
        end
        pathspecs = (declared_pathspecs + [real_source_path]).uniq
        git_status_failed = false
        unreviewed = pathspecs.each_with_object([]) do |pathspec, memo|
          entries = git_path_status_entries(registry_root, pathspec) do |message|
            reporter.error("#{skill_id}: registry-local source.path git status check failed: #{message}")
          end
          if entries.nil?
            git_status_failed = true
            break
          end

          memo.concat(entries)
        end
        next if git_status_failed
        unreviewed.uniq!
        unless unreviewed.empty?
          reporter.error("#{skill_id}: registry-local source.path has unreviewed git changes; commit or clean changes before --print-lock")
          next
        end
      end

      unless skill_file.file?
        reporter.error("#{skill_id}: #{source_path}/SKILL.md is missing")
        next
      end

      metadata = frontmatter(skill_file.to_s, reporter)
      name = metadata["name"]
      description = metadata["description"]
      unless name.is_a?(String)
        reporter.error("#{skill_id}: SKILL.md front matter name must be a string")
        name = ""
      end
      unless description.is_a?(String)
        reporter.error("#{skill_id}: SKILL.md front matter description must be a string")
        description = ""
      end
      if contains_non_nul_control_characters?(name)
        reporter.error("#{skill_id}: SKILL.md front matter name must not contain control characters")
        name = ""
      end
      reporter.error("#{skill_id}: SKILL.md front matter name is required") if name.strip.empty?
      reporter.error("#{skill_id}: SKILL.md front matter description is required") if description.strip.empty?
      reporter.warn("#{skill_id}: exported_names does not include SKILL.md name #{name}") if !name.strip.empty? && !exported_names.include?(name)

      digest = directory_digest(skill_dir.to_s, reporter)
      next if digest.nil?
      resolved[skill_id] = {
        "source_type" => "registry-local",
        "path" => source_path,
        "absolute_path" => skill_dir.to_s,
        "digest_sha256" => digest,
        "exported_names" => exported_names
      }
      reporter.ok("#{skill_id}: registry-local #{source_path} digest #{digest[0, 12]}")
    when "external-git"
      invalid_source_field = false
      {
        "source.url" => source["url"],
        "source.path" => source["path"],
        "pinned_tag" => source["pinned_tag"],
        "observed_commit" => source["observed_commit"]
      }.each do |field, value|
        next if value.nil? || value.is_a?(String)

        reporter.error("#{skill_id}: external-git #{field} must be a string")
        invalid_source_field = true
      end
      {
        "source.url" => source["url"],
        "pinned_tag" => source["pinned_tag"]
      }.each do |field, value|
        next if value.nil? || valid_argv_string?(value)

        reporter.error("#{skill_id}: external-git #{field} must not contain null bytes")
        invalid_source_field = true
      end
      if source["url"].is_a?(String) && contains_non_nul_control_characters?(source["url"])
        reporter.error("#{skill_id}: external-git source.url must not contain control characters")
        invalid_source_field = true
      end
      if source["url"].is_a?(String) && source["url"].start_with?("-")
        reporter.error("#{skill_id}: external-git source.url must not start with -")
        invalid_source_field = true
      end
      next if invalid_source_field

      url = source["url"].to_s
      source_path = source["path"].to_s
      tag = source["pinned_tag"].to_s
      observed_commit = source["observed_commit"].to_s
      reporter.error("#{skill_id}: external-git source.url is required") if url.empty?
      if (options[:check_upstream] || options[:print_lock]) && unresolved_bare_upstream_url?(url, registry_root)
        reporter.error("#{skill_id}: external-git source.url must resolve within the registry root or use an explicit remote URL")
        next
      end
      if (options[:check_upstream] || options[:print_lock]) && unresolved_relative_upstream_url?(url, registry_root)
        reporter.error("#{skill_id}: external-git source.url must resolve within the registry root")
        next
      end
      if (options[:check_upstream] || options[:print_lock]) && relative_upstream_resolves_outside_registry?(url, registry_root)
        reporter.error("#{skill_id}: external-git source.url must resolve within the registry root")
        next
      end
      if (options[:check_upstream] || options[:print_lock]) && ext_remote_url?(url)
        reporter.error("#{skill_id}: external-git source.url must not use ext:: remotes")
        next
      end
      if (options[:check_upstream] || options[:print_lock]) && remote_helper_transport_url?(url)
        reporter.error("#{skill_id}: external-git source.url must use a supported Git transport")
        next
      end
      if options[:print_lock] && credential_bearing_scheme_url?(url)
        reporter.error("#{skill_id}: external-git source.url must not include credentials when using --print-lock")
        next
      end
      if options[:print_lock] && http_url_authority(url) && !valid_http_remote_url?(url)
        reporter.error("#{skill_id}: external-git source.url must be a valid HTTP(S) URL when using --print-lock")
        next
      end
      if options[:print_lock] && scheme_url?(url) && !local_file_url?(url) && http_url_authority(url).nil? && !valid_remote_scheme_url?(url)
        reporter.error("#{skill_id}: external-git source.url must be a valid remote URL when using --print-lock")
        next
      end
      if options[:print_lock] && local_file_url?(url)
        reporter.error("#{skill_id}: external-git source.url must not be a local file URL when using --print-lock")
        next
      end
      if options[:print_lock] && home_relative_url?(url)
        reporter.error("#{skill_id}: external-git source.url must not be a local home-relative path when using --print-lock")
        next
      end
      if options[:print_lock] && !scheme_url?(url) && !scp_like_url?(url) && !Pathname.new(url).absolute? && !safe_relative_path?(url)
        reporter.error("#{skill_id}: external-git source.url must be a safe relative path when using --print-lock")
        next
      end
      if options[:print_lock] && Pathname.new(url).absolute?
        reporter.error("#{skill_id}: external-git source.url must not be a local absolute path when using --print-lock")
        next
      end
      reporter.warn("#{skill_id}: external-git source.path is missing; assuming repository root") if source_path.empty?
      if !source_path.empty? && !safe_relative_path?(source_path)
        reporter.error("#{skill_id}: external-git source.path must be a safe relative path")
        next
      end
      reporter.error("#{skill_id}: external-git pinned_tag is required") if tag.empty?
      if !tag.empty? && !valid_git_tag_name?(tag)
        reporter.error("#{skill_id}: external-git pinned_tag must be an exact tag name")
        next
      end
      if !observed_commit.empty? && !valid_git_object_id?(observed_commit)
        reporter.error("#{skill_id}: external-git observed_commit must be a full git object id")
        next
      end
      observed_commit = observed_commit.downcase
      if options[:check_upstream] && options[:print_lock] && observed_commit.empty?
        reporter.error("#{skill_id}: external-git observed_commit is required when using --check-upstream with --print-lock")
        next
      end
      reporter.warn("#{skill_id}: external-git observed_commit is missing") if observed_commit.empty?

      if options[:check_upstream] && !url.empty? && !tag.empty?
        refs, stderr, status = git_ls_remote_tag(resolve_upstream_url(url, registry_root), tag)
        resolved_commit = refs["refs/tags/#{tag}^{}"] || refs["refs/tags/#{tag}"]
        resolved_commit = resolved_commit.downcase unless resolved_commit.nil?
        if status.success?
          if resolved_commit.nil?
            message = "#{skill_id}: upstream tag #{tag} is not present"
            if options[:print_lock]
              reporter.error(message)
              next
            end

            reporter.warn(message)
          elsif !observed_commit.empty? && observed_commit != resolved_commit
            message = "#{skill_id}: pinned tag #{tag} no longer resolves to observed_commit #{observed_commit[0, 12]}"
            if options[:print_lock]
              reporter.error(message)
              next
            end

            reporter.warn(message)
          else
            reporter.ok("#{skill_id}: upstream tag #{tag} resolves to #{resolved_commit[0, 12]}")
          end
        else
          reporter.warn("#{skill_id}: could not resolve upstream tag #{tag}: #{redact_local_paths(stderr.strip)}")
        end
      else
        reporter.info("#{skill_id}: upstream check skipped")
      end

      resolved[skill_id] = {
        "source_type" => "external-git",
        "url" => url,
        "path" => source_path.empty? ? "." : source_path,
        "pinned_tag" => tag,
        "observed_commit" => observed_commit,
        "exported_names" => exported_names
      }
    else
      reporter.error("#{skill_id}: unsupported source.type #{source["type"].inspect}")
    end
  end

  unless options[:print_lock]
    status_entries = git_status_entries(registry_root) do |message|
      reporter.warn("registry worktree git status check failed: #{message}")
    end
    if status_entries.nil?
      # Warning already recorded; skip clean/dirty summary.
    elsif status_entries.empty?
      reporter.ok("registry worktree is clean")
    else
      reporter.warn("registry worktree has #{status_entries.length} uncommitted entries")
    end

    validate_lock(options[:lock], registry_root, resolved, reporter)
  end
  resolved
end

def lock_field_mismatches(locked, entry, fields)
  fields.each_with_object([]) do |field, mismatches|
    matches =
      if field == "exported_names"
        locked[field] == Array(entry[field])
      elsif field == "observed_commit"
        locked[field].to_s.downcase == entry[field].to_s.downcase
      else
        locked[field].to_s == entry[field].to_s
      end
    mismatches << field unless matches
  end
end

def validate_lock_scalar_fields(locked, fields, lock_label, skill_id, reporter)
  fields.all? do |field|
    next true if locked[field].is_a?(String)

    reporter.error("#{lock_label}: #{skill_id} lock #{field} must be a string")
    false
  end
end

def validate_lock_exported_names(exported_names, lock_label, skill_id, reporter)
  unless exported_names.is_a?(Array) && exported_names.all? { |name| name.is_a?(String) }
    reporter.error("#{lock_label}: #{skill_id} lock exported_names must be an array of strings")
    return false
  end

  invalid_name = exported_names.find { |name| !safe_adapter_name?(name) }
  return true unless invalid_name

  reporter.error("#{lock_label}: #{skill_id} lock exported_names entries must be safe adapter directory names")
  false
end

def validate_lock_external_git_url(url, registry_root, lock_label, skill_id, reporter)
  unless valid_argv_string?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must not contain null bytes")
    return false
  end
  if contains_non_nul_control_characters?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must not contain control characters")
    return false
  end
  if url.empty?
    reporter.error("#{lock_label}: #{skill_id} lock url is required")
    return false
  end
  if url.start_with?("-")
    reporter.error("#{lock_label}: #{skill_id} lock url must not start with -")
    return false
  end
  if ext_remote_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must not use ext:: remotes")
    return false
  end
  if remote_helper_transport_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must use a supported Git transport")
    return false
  end
  if credential_bearing_scheme_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must not include credentials")
    return false
  end
  if http_url_authority(url) && !valid_http_remote_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must be a valid HTTP(S) URL")
    return false
  end
  if scheme_url?(url) && !local_file_url?(url) && http_url_authority(url).nil? && !valid_remote_scheme_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must be a valid remote URL")
    return false
  end
  if local_file_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must not be a local file URL")
    return false
  end
  if home_relative_url?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must not be a local home-relative path")
    return false
  end
  if unresolved_bare_upstream_url?(url, registry_root)
    reporter.error("#{lock_label}: #{skill_id} lock url must resolve within the registry root or use an explicit remote URL")
    return false
  end
  if unresolved_relative_upstream_url?(url, registry_root)
    reporter.error("#{lock_label}: #{skill_id} lock url must resolve within the registry root")
    return false
  end
  if relative_upstream_resolves_outside_registry?(url, registry_root)
    reporter.error("#{lock_label}: #{skill_id} lock url must resolve within the registry root")
    return false
  end
  if !scheme_url?(url) && !scp_like_url?(url) && !Pathname.new(url).absolute? && !safe_relative_path?(url)
    reporter.error("#{lock_label}: #{skill_id} lock url must be a safe relative path")
    return false
  end
  if Pathname.new(url).absolute?
    reporter.error("#{lock_label}: #{skill_id} lock url must not be a local absolute path")
    return false
  end

  true
rescue ArgumentError
  reporter.error("#{lock_label}: #{skill_id} lock url must be a valid string")
  false
end

def validate_lock_entry_shape(locked, registry_root, lock_label, skill_id, reporter)
  return false unless validate_lock_exported_names(locked["exported_names"], lock_label, skill_id, reporter)

  source_type = locked["source_type"]
  unless source_type.is_a?(String)
    reporter.error("#{lock_label}: #{skill_id} lock source_type must be a string")
    return false
  end

  case source_type
  when "registry-local"
    return false unless validate_lock_scalar_fields(locked, %w[source_type path digest_sha256], lock_label, skill_id, reporter)
    unless top_level_skill_path?(locked["path"])
      reporter.error("#{lock_label}: #{skill_id} lock path must name a top-level skill directory")
      return false
    end
    return true if valid_sha256_hex?(locked["digest_sha256"])

    reporter.error("#{lock_label}: #{skill_id} lock digest_sha256 must be a 64-character hex SHA-256")
    false
  when "external-git"
    return false unless validate_lock_scalar_fields(locked, %w[source_type url path pinned_tag observed_commit], lock_label, skill_id, reporter)
    return false unless validate_lock_external_git_url(locked["url"], registry_root, lock_label, skill_id, reporter)
    unless safe_relative_path?(locked["path"])
      reporter.error("#{lock_label}: #{skill_id} lock path must be a safe relative path")
      return false
    end
    unless valid_git_tag_name?(locked["pinned_tag"])
      reporter.error("#{lock_label}: #{skill_id} lock pinned_tag must be an exact tag name")
      return false
    end
    return true if locked["observed_commit"].empty? || valid_git_object_id?(locked["observed_commit"])

    reporter.error("#{lock_label}: #{skill_id} lock observed_commit must be a full git object id")
    false
  else
    reporter.error("#{lock_label}: #{skill_id} lock source_type must be registry-local or external-git")
    false
  end
end

def validate_lock(lock_path, registry_root, resolved, reporter)
  path = Pathname.new(File.expand_path(lock_path, registry_root)).cleanpath
  lock_label = display_path(path)
  unless path.exist?
    reporter.warn("#{lock_label} is missing; run with --print-lock to create a reviewed lock candidate")
    return
  end

  unless path.file?
    reporter.error("#{lock_label} must be a file")
    return
  end

  lock = load_yaml_file(path.to_s, reporter)
  unless lock.is_a?(Hash)
    reporter.error("#{display_path(path)} must contain a top-level mapping") unless lock.nil?
    return
  end

  unless lock["skills"].is_a?(Array)
    reporter.error("#{lock_label}: skills must be an array")
    return
  end

  entries = mapping_array(lock["skills"], reporter, "#{display_path(path)} skills")
  valid_locked_entries = {}
  locked_by_id = entries.each_with_object({}) do |entry, memo|
    unless entry["id"].is_a?(String) && !entry["id"].strip.empty?
      reporter.error("#{lock_label}: lock entries must include non-empty string id")
      next
    end
    unless valid_argv_string?(entry["id"]) && !contains_non_nul_control_characters?(entry["id"])
      reporter.error("#{lock_label}: lock entry id must not contain control characters")
      next
    end

    skill_id = entry["id"]

    if memo.key?(skill_id)
      reporter.error("#{lock_label}: duplicate lock entry id #{skill_id}")
      next
    end

    memo[skill_id] = entry
    valid_locked_entries[skill_id] = validate_lock_entry_shape(entry, registry_root, lock_label, skill_id, reporter)
  end
  (locked_by_id.keys - resolved.keys).sort.each do |skill_id|
    reporter.error("#{lock_label}: stale lock entry #{skill_id} is not present in the registry")
  end

  resolved.each do |skill_id, entry|
    locked = locked_by_id[skill_id]
    if locked.nil?
      reporter.error("#{lock_label}: missing lock entry for #{skill_id}")
      next
    end

    next unless valid_locked_entries[skill_id]

    case entry["source_type"]
    when "registry-local"
      mismatches = lock_field_mismatches(locked, entry, %w[source_type path digest_sha256 exported_names])
      if mismatches.empty?
        reporter.ok("#{lock_label}: #{skill_id} digest matches")
      else
        reporter.error("#{lock_label}: #{skill_id} differs from current source fields: #{mismatches.join(", ")}")
      end
    when "external-git"
      mismatches = lock_field_mismatches(locked, entry, %w[source_type url path pinned_tag observed_commit exported_names])
      if mismatches.empty?
        reporter.ok("#{lock_label}: #{skill_id} external pin matches")
      else
        reporter.error("#{lock_label}: #{skill_id} differs from registry fields: #{mismatches.join(", ")}")
      end
    end
  end
end

def validate_profiles(paths, resolved, reporter)
  reporter.section("Profiles")
  if paths.empty?
    reporter.info("no profiles found")
    return []
  end

  profiles = []
  paths.each do |profile_path|
    expanded = File.expand_path(profile_path)
    profile = load_yaml_file(expanded, reporter)
    unless profile.is_a?(Hash)
      reporter.error("#{display_path(expanded)} must contain a top-level mapping") unless profile.nil?
      next
    end

    profile_metadata = ensure_mapping(profile["profile"], reporter, "#{display_path(expanded)} profile must be a mapping", allow_nil: true)
    id = profile_metadata["id"]
    consumer_roots = profile["consumer_roots"]
    normalized_consumer_roots = normalize_consumer_roots(consumer_roots, reporter, "#{display_path(expanded)}")
    selected_skills = mapping_array(profile["selected_skills"], reporter, "#{display_path(expanded)} selected_skills", allow_nil: true)

    reporter.error("#{display_path(expanded)} profile.id must be a string") unless id.nil? || id.is_a?(String)
    reporter.error("#{display_path(expanded)} profile.id is required") if !id.is_a?(String) || id.empty?
    reporter.error("#{display_path(expanded)} consumer_roots must be a mapping") unless consumer_roots.is_a?(Hash)

    root_keys = normalized_consumer_roots.keys
    normalized_consumer_roots.each do |consumer, root_config|
      consumer_path = root_config["path"]
      next if valid_path_string?(consumer_path)

      reporter.error("#{display_path(expanded)} consumer_roots.#{consumer} path must be a non-empty string")
      normalized_consumer_roots[consumer]["path"] = nil
    end

    selected_skills.each do |selection|
      next unless selection.is_a?(Hash)

      unless selection["skill_id"].is_a?(String) && !selection["skill_id"].empty?
        reporter.error("#{display_path(expanded)} selected_skills[].skill_id must be a non-empty string")
        next
      end

      skill_id = selection["skill_id"]
      expose_to = string_array(selection["expose_to"], reporter, "#{display_path(expanded)} #{skill_id} expose_to")
      reporter.error("#{display_path(expanded)} selected skill #{skill_id} is not in registry") unless resolved.key?(skill_id)
      if expose_to.empty?
        reporter.error("#{display_path(expanded)} #{skill_id} expose_to must list at least one consumer")
        next
      end

      expose_to.each do |consumer|
        unless root_keys.include?(consumer)
          reporter.error("#{display_path(expanded)} #{skill_id} exposes to unknown consumer #{consumer}")
          next
        end
      end

      selection["expose_to"] = expose_to
    end

    reporter.ok("#{id.is_a?(String) && !id.empty? ? id : display_path(expanded)}: #{selected_skills.length} selected skills, #{root_keys.length} consumer roots")
    profiles << [expanded, profile.merge("consumer_roots" => normalized_consumer_roots, "selected_skills" => selected_skills)]
  end

  profiles
end

def check_adapters(profiles, resolved, reporter)
  reporter.section("Adapter Drift")
  if profiles.empty?
    reporter.info("no profile-selected adapters to check")
    return
  end

  profiles.each do |profile_path, profile|
    roots = profile["consumer_roots"].is_a?(Hash) ? profile["consumer_roots"] : {}
    selections = Array(profile["selected_skills"])

    selections.each do |selection|
      skill_id = selection["skill_id"].to_s
      skill = resolved[skill_id]
      next unless skill

      Array(selection["expose_to"]).each do |consumer|
        root_config = roots[consumer]
        root_config = root_config.is_a?(Hash) ? root_config : {}
        root_path = root_config["path"]
        next unless root_path.is_a?(String) && !root_path.empty?

        expanded_root = expand_config_path(root_path, base_dir: File.dirname(profile_path))
        unless File.directory?(expanded_root)
          if root_config["status"] == "planned"
            reporter.info("#{consumer}: #{display_path(expanded_root)} is missing")
          else
            reporter.warn("#{consumer}: #{display_path(expanded_root)} is missing")
          end
          next
        end

        Array(skill["exported_names"]).each do |exported_name|
          entry = File.join(expanded_root, exported_name)
          if File.symlink?(entry)
            target = File.realpath(entry) rescue nil
            if target.nil?
              reporter.warn("#{consumer}: #{exported_name} adapter symlink is broken")
            elsif skill["source_type"] == "registry-local"
              expected = Pathname.new(skill["absolute_path"]).realpath.to_s
              if target == expected
                reporter.ok("#{consumer}: #{exported_name} symlink points at registry source")
              else
                reporter.warn("#{consumer}: #{exported_name} symlink points outside registry source")
              end
            else
              reporter.info("#{consumer}: #{exported_name} external skill adapter exists")
            end
          elsif File.exist?(entry)
            reporter.warn("#{consumer}: #{exported_name} exists as a copy or non-symlink adapter")
          else
            reporter.warn("#{consumer}: #{exported_name} adapter missing")
          end
        end
      end
    end
  end
end

def repo_skill_entrypoints(projects_root, reporter)
  return [] unless File.directory?(projects_root)

  scan_root = File.realpath(projects_root)
  stdout, stderr, status = Open3.capture3(
    "find",
    "-L",
    scan_root,
    "-maxdepth",
    ENV.fetch("SKILLS_DOCTOR_REPO_FIND_MAXDEPTH", "8"),
    "-path",
    "*/.agents/skills/*/SKILL.md",
    "-type",
    "f"
  )
  reporter.warn("repo-local duplicate scan encountered find errors; using partial results") unless status.success?

  stdout.lines.map(&:chomp).select do |entry|
    !repo_skill_entrypoint_name(entry).nil?
  end
rescue Errno::ENOENT, Errno::EACCES
  []
end

def check_repo_duplicates(projects_root, resolved, reporter)
  reporter.section("Repo-Local Duplicate Skills")
  unless File.directory?(projects_root)
    reporter.info("projects root #{display_path(projects_root)} is missing")
    return
  end

  registry_names = resolved.each_with_object({}) do |(skill_id, entry), memo|
    memo[skill_id] ||= skill_id
    Array(entry["exported_names"]).each do |name|
      memo[name] ||= skill_id
    end
  end
  counts = Hash.new(0)
  samples = Hash.new { |hash, key| hash[key] = [] }
  repo_skill_entrypoints(projects_root, reporter).each do |file|
    skill_dir = File.dirname(file)
    skills_root = File.dirname(skill_dir)
    agents_root = File.dirname(skills_root)
    next if File.symlink?(skill_dir) || File.symlink?(skills_root) || File.symlink?(agents_root)

    name = repo_skill_entrypoint_name(file)
    skill_id = registry_names[name]
    next unless skill_id

    counts[skill_id] += 1
    samples[skill_id] << file if samples[skill_id].length < 3
  end

  if counts.empty?
    reporter.ok("no repo-local copies of registry-owned skills found")
    return
  end

  counts.sort.each do |skill_id, count|
    if ENV.fetch("SKILLS_DOCTOR_SHOW_PATHS", "0") == "1"
      sample = samples[skill_id].map { |path| display_path(path) }.join(", ")
      reporter.warn("#{skill_id}: #{count} repo-local copies found; samples: #{sample}")
    else
      reporter.warn("#{skill_id}: #{count} repo-local copies found; set SKILLS_DOCTOR_SHOW_PATHS=1 to show paths")
    end
  end
end

def manager_registry_names(resolved)
  resolved.each_with_object({}) do |(skill_id, entry), memo|
    memo[skill_id] ||= skill_id
    Array(entry["exported_names"]).each do |name|
      memo[name] ||= skill_id
    end
  end
end

def manager_expected_registry_source_description
  "#{DEFAULT_MANAGER_REGISTRY_SOURCE_TYPE} source #{DEFAULT_MANAGER_REGISTRY_SOURCE}"
end

def manager_github_source_url_slug(value)
  return nil unless value.is_a?(String) && /\Ahttps?:\/\//i.match?(value)

  uri = URI.parse(value)
  host = uri.host.to_s.downcase.sub(/\Awww\./, "")
  return nil unless host == "github.com"

  segments = uri.path.to_s.split("/").reject(&:empty?)
  return nil if segments.length < 2

  owner = segments[0]
  repo = segments[1].sub(/\.git\z/i, "")
  return nil if owner.empty? || repo.empty?

  "#{owner}/#{repo}".downcase
rescue URI::InvalidURIError
  nil
end

def manager_source_url_matches_expected_source?(value)
  return false unless value.is_a?(String) && !value.empty?
  return true unless DEFAULT_MANAGER_REGISTRY_SOURCE_TYPE == "github"

  manager_github_source_url_slug(value) == DEFAULT_MANAGER_REGISTRY_SOURCE.downcase
end

def manager_lock_entry_matches_expected_source?(entry, require_source_url: false)
  return false unless entry.is_a?(Hash)
  return false unless entry["source"] == DEFAULT_MANAGER_REGISTRY_SOURCE &&
    entry["sourceType"] == DEFAULT_MANAGER_REGISTRY_SOURCE_TYPE

  !require_source_url || manager_source_url_matches_expected_source?(entry["sourceUrl"])
end

def default_manager_global_lock_path
  xdg_state_home = ENV["XDG_STATE_HOME"].to_s
  if xdg_state_home.empty?
    File.expand_path("~/.agents/.skill-lock.json")
  else
    File.join(File.expand_path(xdg_state_home), "skills", ".skill-lock.json")
  end
end

def manager_project_lock_paths(projects_root, explicit_paths, reporter)
  return explicit_paths.map { |path| File.expand_path(path) }.uniq.sort unless explicit_paths.empty?
  return [] unless File.directory?(projects_root)

  scan_root = File.realpath(projects_root)
  stdout, _stderr, status = Open3.capture3(
    "find",
    "-L",
    scan_root,
    "-maxdepth",
    ENV.fetch("SKILLS_DOCTOR_MANAGER_FIND_MAXDEPTH", "4"),
    "-name",
    "skills-lock.json",
    "-type",
    "f"
  )
  reporter.warn("manager project-lock scan encountered find errors; using partial results") unless status.success?
  stdout.lines.map(&:chomp).uniq.sort
rescue Errno::ENOENT, Errno::EACCES
  []
end

def load_manager_list(options, reporter)
  parsed =
    if options[:manager_list_json]
      label = display_path(options[:manager_list_json])
      load_json_file(options[:manager_list_json], reporter, label: label, warning_only: true)
    else
      stdout, stderr, status = Open3.capture3(
        "npx",
        "--yes",
        options[:skills_cli_package],
        "ls",
        "--global",
        "--json"
      )
      unless status.success?
        reporter.warn("npx #{options[:skills_cli_package]} ls --global --json failed: #{redact_local_paths(stderr.strip)}")
        return []
      end

      JSON.parse(stdout)
    end

  unless parsed.is_a?(Array)
    reporter.warn("npx skills global list output must be a JSON array")
    return []
  end

  parsed.each_with_index do |entry, index|
    unless entry.is_a?(Hash)
      reporter.warn("npx skills global list entry #{index} must be a mapping")
      next
    end

    reporter.warn("npx skills global list entry #{index} name must be a string") unless entry["name"].is_a?(String)
    reporter.warn("npx skills global list entry #{index} path must be a string") unless entry["path"].is_a?(String)
    reporter.warn("npx skills global list entry #{index} scope must be global") unless entry["scope"] == "global"
    unless entry["agents"].is_a?(Array) && entry["agents"].all? { |agent| agent.is_a?(String) }
      reporter.warn("npx skills global list entry #{index} agents must be an array of strings")
    end
  end

  parsed.select { |entry| entry.is_a?(Hash) && entry["name"].is_a?(String) }
rescue JSON::ParserError => error
  reporter.warn("npx skills global list output is not valid JSON: #{error.message}")
  []
rescue Errno::ENOENT
  reporter.warn("npx is not available; install Node/npm or pass --manager-list-json for fixture input")
  []
end

def validate_global_manager_lock(path, reporter)
  lock_label = display_path(path)
  unless File.exist?(path)
    reporter.warn("global skills lock #{lock_label} is missing")
    return { entries: {}, usable_entries: {} }
  end

  unless File.file?(path)
    reporter.warn("global skills lock #{lock_label} must be a file")
    return { entries: {}, usable_entries: {} }
  end

  lock = load_json_file(path, reporter, label: "global skills lock #{lock_label}", warning_only: true)
  unless lock.is_a?(Hash)
    reporter.warn("global skills lock #{lock_label} must be a JSON object") unless lock.nil?
    return { entries: {}, usable_entries: {} }
  end

  version = lock["version"]
  unless version.is_a?(Numeric)
    reporter.warn("global skills lock #{lock_label} version must be a number")
    return { entries: {}, usable_entries: {} }
  end
  if version < 3
    reporter.warn("global skills lock #{lock_label} version #{version} is older than supported version 3 and will be ignored by #{DEFAULT_SKILLS_CLI_PACKAGE}")
    return { entries: {}, usable_entries: {} }
  end
  reporter.warn("global skills lock #{lock_label} version #{version} is newer than supported version 3") if version.is_a?(Numeric) && version > 3

  skills = lock["skills"]
  unless skills.is_a?(Hash)
    reporter.warn("global skills lock #{lock_label} skills must be a mapping")
    return { entries: {}, usable_entries: {} }
  end

  entries = {}
  usable_entries = {}
  skills.each do |name, entry|
    reporter.warn("global skills lock #{lock_label} skill names must be strings") unless name.is_a?(String)
    unless entry.is_a?(Hash)
      reporter.warn("global skills lock #{lock_label} #{name} entry must be a mapping")
      next
    end

    entries[name] = entry if name.is_a?(String)

    valid_entry = true
    %w[source sourceType].each do |field|
      reporter.warn("global skills lock #{lock_label} #{name} #{field} must be a string") unless entry[field].is_a?(String)
      valid_entry = false unless entry[field].is_a?(String)
    end
    unless entry["skillFolderHash"].is_a?(String)
      reporter.warn("global skills lock #{lock_label} #{name} skillFolderHash must be a string")
      valid_entry = false
    end
    if entry["skillFolderHash"].is_a?(String) && entry["skillFolderHash"].empty?
      reporter.warn("global skills lock #{lock_label} #{name} skillFolderHash must be a non-empty string")
      valid_entry = false
    end
    unless entry["sourceUrl"].is_a?(String)
      reporter.warn("global skills lock #{lock_label} #{name} sourceUrl must be a string")
      valid_entry = false
    end
    if entry["sourceUrl"].is_a?(String) && entry["sourceUrl"].empty?
      reporter.warn("global skills lock #{lock_label} #{name} sourceUrl must be a non-empty string")
      valid_entry = false
    end
    if entry.key?("skillPath") && !entry["skillPath"].is_a?(String)
      reporter.warn("global skills lock #{lock_label} #{name} skillPath must be a string")
      valid_entry = false
    end

    usable_entries[name] = entry if name.is_a?(String) && valid_entry
  end

  reporter.ok("global skills lock #{lock_label} tracks #{skills.length} skill(s)")
  { entries: entries, usable_entries: usable_entries }
end

def validate_project_manager_lock(path, registry_names, reporter)
  label = display_path(path)
  lock = load_json_file(path, reporter, label: "project skills lock #{label}", warning_only: true)
  return unless lock.is_a?(Hash)

  version = lock["version"]
  reporter.warn("project skills lock #{label} version must be a number") unless version.is_a?(Numeric)

  skills = lock["skills"]
  unless skills.is_a?(Hash)
    reporter.warn("project skills lock #{label} skills must be a mapping")
    return
  end

  usable_entries = {}
  skills.each do |name, entry|
    reporter.warn("project skills lock #{label} skill names must be strings") unless name.is_a?(String)
    unless entry.is_a?(Hash)
      reporter.warn("project skills lock #{label} #{name} entry must be a mapping")
      next
    end

    valid_entry = true
    %w[source sourceType].each do |field|
      reporter.warn("project skills lock #{label} #{name} #{field} must be a string") unless entry[field].is_a?(String)
      valid_entry = false unless entry[field].is_a?(String)
    end
    unless entry["computedHash"].is_a?(String)
      reporter.warn("project skills lock #{label} #{name} computedHash must be a string")
      valid_entry = false
    end
    if entry["computedHash"].is_a?(String) && entry["computedHash"].empty?
      reporter.warn("project skills lock #{label} #{name} computedHash must be a non-empty string")
      valid_entry = false
    end

    usable_entries[name] = entry if name.is_a?(String) && valid_entry
  end

  reporter.ok("project skills lock #{label} tracks #{skills.length} skill(s)")
  skills.keys.sort.each do |name|
    skill_id = registry_names[name]
    next unless skill_id

    unless usable_entries.key?(name)
      reporter.warn("project skills lock #{label} entry for registry-related #{name} is not usable manager evidence")
      next
    end
    unless manager_lock_entry_matches_expected_source?(usable_entries[name])
      reporter.warn("project skills lock #{label} tracks registry-related #{name}, but source metadata does not match expected #{manager_expected_registry_source_description}")
      next
    end

    source = usable_entries[name]["source"]
    reporter.info("project skills lock #{label} tracks registry-related #{skill_id} as #{name} from #{source}")
  end
end

def check_manager_state(options, resolved, reporter)
  reporter.section("Manager State")

  registry_names = manager_registry_names(resolved)
  manager_list = load_manager_list(options, reporter)
  reporter.ok("npx #{options[:skills_cli_package]} global list reports #{manager_list.length} skill(s)")

  global_lock_path = File.expand_path(options[:manager_global_lock] || default_manager_global_lock_path)
  global_lock_state = validate_global_manager_lock(global_lock_path, reporter)
  global_lock_entries = global_lock_state[:entries]
  usable_global_lock_entries = global_lock_state[:usable_entries]
  lock_names = global_lock_entries.keys
  usable_lock_names = usable_global_lock_entries.keys
  list_names = manager_list.map { |entry| entry["name"] }.compact

  (list_names & registry_names.keys).sort.each do |name|
    skill_id = registry_names[name]
    entry = manager_list.find { |item| item["name"] == name } || {}
    agents = Array(entry["agents"]).join(", ")
    reporter.ok("npx global list sees registry-related #{skill_id} as #{name} for #{agents.empty? ? "unknown agents" : agents}")
    unless lock_names.include?(name)
      reporter.warn("npx global list sees registry-related #{name}, but global skills lock does not track it")
      next
    end
    unless usable_lock_names.include?(name)
      reporter.warn("npx global list sees registry-related #{name}, but global skills lock entry is not usable manager evidence")
      next
    end
    next if manager_lock_entry_matches_expected_source?(usable_global_lock_entries[name], require_source_url: true)

    reporter.warn("npx global list sees registry-related #{name}, but global skills lock source metadata does not match expected #{manager_expected_registry_source_description}")
  end

  (lock_names & registry_names.keys).sort.each do |name|
    skill_id = registry_names[name]
    reporter.warn("global skills lock tracks registry-related #{name}, but npx global list does not report it") unless list_names.include?(name)
    unless usable_lock_names.include?(name)
      reporter.warn("global skills lock entry for registry-related #{name} is not usable manager evidence") unless list_names.include?(name)
      next
    end
    unless manager_lock_entry_matches_expected_source?(usable_global_lock_entries[name], require_source_url: true)
      reporter.warn("global skills lock tracks registry-related #{name}, but source metadata does not match expected #{manager_expected_registry_source_description}") unless list_names.include?(name)
      next
    end
    reporter.ok("global skills lock tracks registry-related #{skill_id} as #{name}")
  end

  project_lock_paths = manager_project_lock_paths(File.expand_path(options[:projects_root]), options[:manager_project_locks], reporter)
  if project_lock_paths.empty?
    reporter.info("no project skills-lock.json files found")
  else
    reporter.ok("found #{project_lock_paths.length} project skills-lock.json file(s)")
    project_lock_paths.each do |path|
      validate_project_manager_lock(path, registry_names, reporter)
    end
  end
end

def lock_document(resolved)
  {
    "schema_version" => 0.1,
    "generated_by" => "scripts/skills_doctor.rb --print-lock",
    "skills" => resolved.keys.sort.map do |skill_id|
      entry = resolved[skill_id]
      {
        "id" => skill_id,
        "source_type" => entry["source_type"],
        "path" => entry["path"],
        "url" => entry["url"],
        "pinned_tag" => entry["pinned_tag"],
        "observed_commit" => entry["observed_commit"],
        "digest_sha256" => entry["digest_sha256"],
        "exported_names" => entry["exported_names"]
      }.compact
    end
  }
end

options = {
  registry: ROOT.join("skills.registry.yaml").to_s,
  profiles: [],
  projects_root: ENV.fetch("PROJECTS_ROOT", File.join(Dir.home, "Projects")),
  lock: "skills.lock.yaml",
  check_upstream: false,
  check_manager: false,
  manager_global_lock: nil,
  manager_list_json: nil,
  manager_project_locks: [],
  skills_cli_package: ENV.fetch("SKILLS_DOCTOR_SKILLS_CLI_PACKAGE", DEFAULT_SKILLS_CLI_PACKAGE),
  print_lock: false
}

parser = OptionParser.new do |opts|
  opts.banner = "usage: scripts/skills_doctor.rb [options]"
  opts.on("--registry PATH", "Registry manifest path") { |value| options[:registry] = value }
  opts.on("--profile PATH", "Profile path; can be repeated") { |value| options[:profiles] << value }
  opts.on("--projects-root PATH", "Projects root for repo-local duplicate scan") { |value| options[:projects_root] = value }
  opts.on("--lock PATH", "Lock file to validate if present") { |value| options[:lock] = value }
  opts.on("--check-upstream", "Resolve external git tags") { options[:check_upstream] = true }
  opts.on("--check-manager", "Inspect upstream skills manager state without mutation") { options[:check_manager] = true }
  opts.on("--manager-global-lock PATH", "Override upstream global .skill-lock.json path") { |value| options[:manager_global_lock] = value }
  opts.on("--manager-list-json PATH", "Read npx skills ls --global --json output from PATH") { |value| options[:manager_list_json] = value }
  opts.on("--manager-project-lock PATH", "Project skills-lock.json path; can be repeated") { |value| options[:manager_project_locks] << value }
  opts.on("--skills-cli-package PACKAGE", "Pinned skills CLI package for manager checks") { |value| options[:skills_cli_package] = value }
  opts.on("--print-lock", "Print a lock-file candidate and skip local drift scans") { options[:print_lock] = true }
end
parser.parse!

reporter = Reporter.new(quiet: options[:print_lock])
registry_path = File.expand_path(options[:registry])
registry = load_yaml_file(registry_path, reporter)
resolved = validate_registry(registry_path, registry, options, reporter)

if options[:print_lock]
  if reporter.errors.empty?
    puts lock_document(resolved).to_yaml
  end
else
  profiles = validate_profiles(profile_paths(options, registry_path), resolved, reporter)
  check_adapters(profiles, resolved, reporter)
  check_repo_duplicates(File.expand_path(options[:projects_root]), resolved, reporter)
  check_manager_state(options, resolved, reporter) if options[:check_manager]

  reporter.section("Summary")
  if reporter.errors.empty? && reporter.warnings.empty?
    reporter.ok("skills doctor passed")
  elsif reporter.errors.empty?
    reporter.warn("skills doctor completed with #{reporter.warnings.length} warning(s)")
  else
    reporter.error("skills doctor failed with #{reporter.errors.length} error(s) and #{reporter.warnings.length} warning(s)")
  end
end

exit(reporter.errors.empty? ? 0 : 1)
