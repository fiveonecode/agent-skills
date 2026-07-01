#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "optparse"
require "pathname"
require "shellwords"
require "uri"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
DEFAULT_SKILLS_CLI_PACKAGE = "skills@1.5.14"
DEFAULT_MANAGER_SOURCE_BY_REGISTRY_ID = {
  "agent-skills" => "fiveonecode/agent-skills"
}.freeze

class Reporter
  attr_reader :errors, :warnings

  def initialize
    @errors = []
    @warnings = []
  end

  def error(message)
    @errors << message
  end

  def warn(message)
    @warnings << message
  end
end

def show_local_paths?
  ENV.fetch("SKILLS_SYNC_SHOW_PATHS", "0") == "1"
end

def display_path(path, root: ROOT)
  value = path.to_s
  expanded =
    if value.start_with?("~/")
      File.expand_path(value.delete_prefix("~/"), Dir.home)
    else
      File.expand_path(value)
    end
  expanded = canonical_path_for_display(expanded)
  home = canonical_path_for_display(File.expand_path("~"))
  root_path = canonical_path_for_display(File.expand_path(root.to_s))

  return expanded if show_local_paths?
  return "." if expanded == root_path
  return "./#{expanded.delete_prefix("#{root_path}/")}" if expanded.start_with?("#{root_path}/")
  return "~" if expanded == home
  return "~/#{expanded.delete_prefix("#{home}/")}" if expanded.start_with?("#{home}/")

  "<absolute-path>"
end

def canonical_path_for_display(path)
  expanded = File.expand_path(path.to_s)
  parent = File.dirname(expanded)
  basename = File.basename(expanded)
  return File.join(canonical_existing_path(parent), basename) unless parent == expanded

  expanded
rescue SystemCallError
  expanded
end

def canonical_existing_path(path)
  expanded = File.expand_path(path.to_s)
  return File.realpath(expanded) if File.exist?(expanded) || File.symlink?(expanded)

  parent = expanded
  missing_parts = []
  until File.exist?(parent) || File.symlink?(parent)
    next_parent = File.dirname(parent)
    break if next_parent == parent

    missing_parts.unshift(File.basename(parent))
    parent = next_parent
  end

  parent_real = File.realpath(parent)
  File.join(parent_real, *missing_parts)
rescue SystemCallError
  expanded
end

def nearest_existing_ancestor(path)
  current = File.expand_path(path.to_s)

  loop do
    return current if File.exist?(current) || File.symlink?(current)

    parent = File.dirname(current)
    return nil if parent == current

    current = parent
  end
end

def obstructing_ancestor(path)
  ancestor = nearest_existing_ancestor(path)
  return nil if ancestor.nil? || File.directory?(ancestor)

  ancestor
rescue SystemCallError
  ancestor
end

def local_path_redaction_variants(path)
  value = path.to_s
  return [] if value.empty?

  expanded =
    if value.start_with?("~/")
      File.expand_path(value.delete_prefix("~/"), Dir.home)
    else
      File.expand_path(value)
    end

  [value, expanded, canonical_path_for_display(expanded)].compact.uniq.sort_by { |item| -item.length }
rescue SystemCallError, ArgumentError
  [value]
end

def redact_local_path_fragments(message)
  redacted = message.to_s.gsub(%r{(?<![[:alnum:]_.])/(?:[^[:space:]'"]+)}, "<absolute-path>")
  redacted.gsub!(%r{(?<![[:alnum:]_.])(?:[a-z]:[\\/]|\\\\[^\\/\s]+[\\/]|//[^/\s]+/)(?:[^[:space:]'"]+)}i, "<absolute-path>")
  redacted
end

def redact_local_paths(message, known_paths: [])
  text = message.to_s
  return text if show_local_paths?

  redacted = text.dup
  Array(known_paths).flatten.compact.each do |path|
    local_path_redaction_variants(path).each do |variant|
      redacted.gsub!(variant, "<absolute-path>")
    end
  end

  redact_local_path_fragments(redacted)
end

def display_link_target(target)
  value = target.to_s
  return value if show_local_paths?
  return "<absolute-path>" if value.start_with?("/") || value.start_with?("~") || windows_local_path?(value)

  redact_local_path_fragments(value)
end

def load_yaml_file(path, reporter)
  parsed = YAML.safe_load(File.read(path), aliases: false)
  parsed.nil? ? {} : parsed
rescue Psych::Exception => error
  reporter.error("#{display_path(path)} is not valid YAML: #{error.message}")
  nil
rescue Errno::ENOENT
  reporter.error("#{display_path(path)} does not exist")
  nil
rescue SystemCallError => error
  reporter.error("#{display_path(path)} could not be read: #{redact_local_paths(error.message, known_paths: [path])}")
  nil
end

def contains_control_characters?(value)
  value.is_a?(String) && /[\x00-\x1F\x7F]/.match?(value)
end

def valid_path_string?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if contains_control_characters?(value)
  return false if windows_local_path?(value)
  return false if value.start_with?("~") && value != "~" && !value.start_with?("~/")

  Pathname.new(value)
  true
rescue ArgumentError
  false
end

def safe_relative_path?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if contains_control_characters?(value)
  return false if value.start_with?("/")
  return false if windows_local_path?(value) || value.include?("\\")

  path = Pathname.new(value)
  return false if path.each_filename.any? { |part| part == ".." }

  path.cleanpath.each_filename.none? { |part| part == ".." }
rescue ArgumentError
  false
end

def safe_adapter_name?(value)
  return false unless value.is_a?(String) && !value.strip.empty?
  return false if contains_control_characters?(value)
  return false if value.start_with?("/")
  return false if windows_local_path?(value) || value.include?("\\")
  return false if [".", ".."].include?(value)

  path = Pathname.new(value)
  path.cleanpath.to_s == value &&
    path.each_filename.to_a.length == 1 &&
    path.each_filename.first == value
rescue ArgumentError
  false
end

def safe_non_path_identifier?(value)
  safe_adapter_name?(value)
end

def equivalent_external_lock_value?(field, locked_value, registry_value)
  if field == "observed_commit"
    return locked_value.to_s.casecmp?(registry_value.to_s) if valid_git_object_id?(locked_value) && valid_git_object_id?(registry_value)
  end

  locked_value == registry_value
end

def expand_config_path(path, base_dir:)
  value = path.to_s
  return File.expand_path(value.delete_prefix("~/"), Dir.home) if value.start_with?("~/")

  File.expand_path(value, base_dir)
end

def path_within?(path, root)
  candidate = Pathname.new(path).cleanpath.to_s
  root_path = Pathname.new(root).cleanpath.to_s
  candidate == root_path || candidate.start_with?("#{root_path}/")
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

def credential_bearing_scp_url?(value)
  match = /\A(?<userinfo>[^\/@\s]+)@[^\/:\s]+:.+\z/.match(value.to_s)
  match && match[:userinfo].include?(":")
end

def query_or_fragment_bearing_scp_url?(value)
  match = /\A(?:[^\/@\s]+@)?[^\/:\s]+:(?<path>.+)\z/.match(value.to_s)
  match && (match[:path].include?("?") || match[:path].include?("#"))
end

def windows_drive_letter_path?(value)
  value.is_a?(String) && /\A[a-z]:(?:[\\\/]|[^\\\/]|$)/i.match?(value)
end

def windows_unc_path?(value)
  value.is_a?(String) && (value.start_with?("\\\\") || value.match?(%r{\A//[^/\\]}))
end

def windows_local_path?(value)
  windows_drive_letter_path?(value) || windows_unc_path?(value)
end

def windows_path_fragment?(value)
  return false unless value.is_a?(String) && !value.empty?

  return true if windows_local_path?(value) || value.include?("\\")

  value.split("/").any? { |segment| windows_local_path?(segment) }
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
  uri = URI.parse(value)
  userinfo = uri.respond_to?(:userinfo) ? uri.userinfo.to_s : ""
  return false if userinfo.empty?

  !(uri.scheme.to_s.casecmp("ssh").zero? && !userinfo.include?(":"))
rescue URI::InvalidURIError
  authority = scheme_url_authority(value)
  return false if authority.nil? || authority.empty?

  match = /\A(?<userinfo>[^@]+)@/.match(authority)
  return false unless match

  scheme = url_scheme(value).to_s.downcase
  userinfo = match[:userinfo]

  !(scheme == "ssh" && !userinfo.include?(":"))
end

def query_or_fragment_bearing_scheme_url?(value)
  return false unless scheme_url?(value)

  uri = URI.parse(value)
  !uri.query.to_s.empty? || !uri.fragment.to_s.empty?
rescue URI::InvalidURIError
  suffix = value.to_s.sub(/\A[a-z][a-z0-9+.-]*:\/\/[^\/?#]*/i, "")
  suffix.include?("?") || suffix.include?("#")
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

def valid_git_object_id?(value)
  return false unless value.is_a?(String) && /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i.match?(value)

  !value.match?(/\A0+\z/)
end

def valid_git_tag_name?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if value.start_with?("refs/")

  system("git", "check-ref-format", "refs/tags/#{value}", out: File::NULL, err: File::NULL)
rescue SystemCallError, ArgumentError
  false
end

def split_manager_source_ref(value)
  return [value, nil] unless value.is_a?(String)

  fragment_index = value.index("#")
  return [value, nil] if fragment_index.nil?

  base = value[0...fragment_index]
  fragment = value[(fragment_index + 1)..]
  return [value, nil] if base.to_s.empty? || fragment.to_s.empty?

  [base, fragment]
end

def public_manager_shorthand?(value)
  base, fragment = split_manager_source_ref(value)
  return false if value.include?("#") && fragment.nil?
  return false unless safe_relative_path?(base)
  return false if base.start_with?(".")
  return false if base.include?(":")
  return false if base.include?("?")
  return false unless base.include?("/")
  return false if fragment && (fragment.match?(/\s/) || contains_control_characters?(fragment))

  true
end

def safe_manager_source?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if contains_control_characters?(value)
  return false if value.match?(/\s/)
  return false if value.start_with?("-")
  source_base, = split_manager_source_ref(value)
  return false if windows_local_path?(source_base) || Pathname.new(source_base).absolute?
  return false if local_file_url?(source_base) || home_relative_url?(source_base)
  return false if ext_remote_url?(source_base) || remote_helper_transport_url?(source_base)
  return false if credential_bearing_scheme_url?(source_base) || credential_bearing_scp_url?(source_base)
  return false if query_or_fragment_bearing_scheme_url?(source_base) || query_or_fragment_bearing_scp_url?(source_base)

  if scheme_url?(source_base)
    valid_http_remote_url?(source_base) || valid_remote_scheme_url?(source_base)
  elsif scp_like_url?(source_base)
    true
  else
    public_manager_shorthand?(value)
  end
rescue ArgumentError
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
  return nil unless path_within?(candidate_realpath, root_realpath)

  candidate_realpath
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, SystemCallError
  nil
end

def relative_upstream_resolves_outside_registry?(url, registry_root)
  candidate = registry_relative_upstream_candidate(url, registry_root)
  return false if candidate.nil? || !candidate.exist?

  candidate_realpath = candidate.realpath
  root_realpath = registry_root.realpath
  !path_within?(candidate_realpath, root_realpath)
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, SystemCallError
  false
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

def consumer_root_listing_error(path)
  Dir.children(path)
  nil
rescue SystemCallError => error
  redact_local_paths(error.message, known_paths: [path])
end

def unresolved_relative_upstream_url?(url, registry_root)
  relative_upstream_url?(url) && resolved_registry_relative_upstream_path(url, registry_root).nil?
end

def valid_sha256_hex?(value)
  value.is_a?(String) && /\A[0-9a-f]{64}\z/i.match?(value)
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
  reporter.error("#{display_path(dir)} could not be hashed cleanly: #{redact_local_paths(error.message, known_paths: [dir])}")
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
  reporter.error("#{display_path(path)} could not be read: #{redact_local_paths(error.message, known_paths: [path])}")
  {}
end

def supported_adapter?(adapter)
  adapter == "symlink"
end

def mapping(value, reporter, label, allow_nil: false)
  return {} if value.nil? && allow_nil
  return value if value.is_a?(Hash)

  reporter.error("#{label} must be a mapping")
  {}
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

def profile_paths(options, registry_path)
  return options[:profiles].map { |path| File.expand_path(path) } unless options[:profiles].empty?

  registry_root = File.dirname(File.expand_path(registry_path))
  Dir.glob(File.join(registry_root, "profiles/**/*.yaml")).sort
end

def registry_local_source_entries(registry_by_id)
  registry_by_id.values.each_with_object([]) do |skill, memo|
    next unless skill[:source_type] == "registry-local"

    source_root = File.realpath(skill[:source_absolute])
    memo << { skill: skill, source_root: source_root }
  rescue SystemCallError
    next
  end
end

def load_registry(path, reporter)
  registry = load_yaml_file(path, reporter)
  unless registry.is_a?(Hash)
    reporter.error("#{display_path(path)} must contain a top-level mapping") unless registry.nil?
    return [{}, nil, {}]
  end

  registry_root = Pathname.new(File.dirname(File.expand_path(path))).realpath
  registry_root_real = registry_root.realpath
  registry_metadata = mapping(registry["registry"], reporter, "registry metadata", allow_nil: true)
  registry_id = registry_metadata["id"]
  registry_name = registry_metadata["name"]
  raw_manager_source = registry_metadata["manager_source"]
  manager_source =
    if raw_manager_source.nil? || raw_manager_source.to_s.empty?
      DEFAULT_MANAGER_SOURCE_BY_REGISTRY_ID[registry_id]
    elsif safe_manager_source?(raw_manager_source)
      raw_manager_source
    else
      reporter.error("registry.manager_source must be a public-safe skills source")
      nil
    end
  reporter.error("registry.id must be a string") unless registry_id.nil? || registry_id.is_a?(String)
  reporter.error("registry.name must be a string") unless registry_name.nil? || registry_name.is_a?(String)
  reporter.error("registry.id is required") if !registry_id.is_a?(String) || registry_id.empty?
  reporter.error("registry.name is required") if !registry_name.is_a?(String) || registry_name.empty?
  reporter.error("registry.manager_source must be a string") unless raw_manager_source.nil? || raw_manager_source.is_a?(String)

  raw_skills = registry["skills"]
  skills =
    if raw_skills.is_a?(Array)
      reporter.error("skills must be a non-empty array") if raw_skills.empty?
      mapping_array(raw_skills, reporter, "skills")
    else
      reporter.error("skills must be a non-empty array")
      []
    end
  by_id = {}
  exported_owner = {}
  registry_local_source_owner = {}

  skills.each do |skill|
    skill_id = skill["id"]
    if !skill_id.is_a?(String) || skill_id.strip.empty? || contains_control_characters?(skill_id)
      reporter.error("skill entry id must be a non-empty string without control characters")
      next
    end
    unless safe_non_path_identifier?(skill_id)
      reporter.error("skill entry id must be a safe non-path identifier")
      next
    end

    if by_id.key?(skill_id)
      reporter.error("duplicate skill id #{skill_id}")
      next
    end

    source = mapping(skill["source"], reporter, "#{skill_id}: source")
    exported_names = string_array(skill["exported_names"], reporter, "#{skill_id}: exported_names")
    clients = mapping(skill["clients"], reporter, "#{skill_id}: clients", allow_nil: true)
    reporter.error("#{skill_id}: exported_names must not be empty") if exported_names.empty?

    exported_names.each do |name|
      unless safe_adapter_name?(name)
        reporter.error("#{skill_id}: exported_names entries must be safe adapter directory names")
        next
      end
      if exported_owner.key?(name)
        if exported_owner[name] == skill_id
          reporter.error("#{skill_id}: exported adapter name #{name} is duplicated")
        else
          reporter.error("exported adapter name #{name} is declared by both #{exported_owner[name]} and #{skill_id}")
        end
      else
        exported_owner[name] = skill_id
      end
    end

    normalized_clients = clients.each_with_object({}) do |(client_name, client_status), memo|
      next if client_status.nil? || client_status == ""

      unless client_status.is_a?(String) && safe_non_path_identifier?(client_status)
        reporter.error("#{skill_id}: clients values must be safe non-path identifiers")
        next
      end

      memo[client_name] = client_status
    end

    source_type = source["type"]
    case source_type
    when "registry-local"
      source_path = source["path"]
      unless safe_adapter_name?(source_path)
        reporter.error("#{skill_id}: registry-local source.path must name a top-level skill directory")
        next
      end
      if registry_local_source_owner.key?(source_path)
        reporter.error("#{skill_id}: registry-local source.path #{source_path} is already declared by #{registry_local_source_owner[source_path]}")
      else
        registry_local_source_owner[source_path] = skill_id
      end
      source_absolute = registry_root.join(source_path).cleanpath
      unless path_within?(source_absolute, registry_root)
        reporter.error("#{skill_id}: registry-local source.path must stay inside the registry root")
        next
      end
      skill_file = source_absolute.join("SKILL.md")
      source_digest_sha256 = nil
      if !source_absolute.directory?
        reporter.error("#{skill_id}: registry-local source.path #{source_path} is missing")
      elsif source_absolute.symlink?
        reporter.error("#{skill_id}: registry-local source.path must not be a symlink")
      elsif !path_within?(source_absolute.realpath, registry_root_real)
        reporter.error("#{skill_id}: registry-local source.path must stay inside the registry root")
      elsif !skill_file.file?
        reporter.error("#{skill_id}: #{source_path}/SKILL.md is missing")
      else
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
        if contains_control_characters?(name)
          reporter.error("#{skill_id}: SKILL.md front matter name must not contain control characters")
          name = ""
        end
        if contains_control_characters?(description)
          reporter.error("#{skill_id}: SKILL.md front matter description must not contain control characters")
          description = ""
        end
        reporter.error("#{skill_id}: SKILL.md front matter name is required") if name.strip.empty?
        reporter.error("#{skill_id}: SKILL.md front matter description is required") if description.strip.empty?
        source_digest_sha256 = directory_digest(source_absolute.to_s, reporter)
      end
      by_id[skill_id] = {
        id: skill_id,
        status: skill["status"].to_s,
        source_type: source_type,
        path: source_path,
        source_absolute: source_absolute.to_s,
        source_digest_sha256: source_digest_sha256,
        manager_skill_name: name,
        exported_names: exported_names,
        clients: normalized_clients
      }
    when "external-git"
      url = source["url"]
      raw_source_path = source["path"]
      source_path =
        if raw_source_path.nil? || (raw_source_path.is_a?(String) && raw_source_path.empty?)
          "."
        else
          raw_source_path
        end
      pinned_tag = source["pinned_tag"]
      observed_commit = source["observed_commit"]
      invalid_source = false
      reporter.error("#{skill_id}: external-git source.url must be a string") unless url.is_a?(String) && !url.empty?
      if url.is_a?(String)
        if contains_control_characters?(url)
          reporter.error("#{skill_id}: external-git source.url must not contain control characters")
          invalid_source = true
        end
        if url.start_with?("-")
          reporter.error("#{skill_id}: external-git source.url must not start with -")
          invalid_source = true
        end
      end
      unless source_path.is_a?(String)
        reporter.error("#{skill_id}: external-git source.path must be a string when provided")
        invalid_source = true
      end
      reporter.error("#{skill_id}: external-git source.path must be a safe relative path") if source_path.is_a?(String) && !safe_relative_path?(source_path)
      reporter.error("#{skill_id}: external-git source.pinned_tag must be a string") unless pinned_tag.is_a?(String) && !pinned_tag.empty?
      reporter.error("#{skill_id}: external-git source.observed_commit must be a string") unless observed_commit.is_a?(String)
      if pinned_tag.is_a?(String) && !pinned_tag.empty? && !valid_git_tag_name?(pinned_tag)
        reporter.error("#{skill_id}: external-git source.pinned_tag must be an exact tag name")
        invalid_source = true
      end
      if observed_commit.is_a?(String) && !observed_commit.empty? && !valid_git_object_id?(observed_commit)
        reporter.error("#{skill_id}: external-git source.observed_commit must be a full git object id")
        invalid_source = true
      end
      if url.is_a?(String) && !url.empty? && !invalid_source
        if windows_local_path?(url)
          reporter.error("#{skill_id}: external-git source.url must not be a local Windows path")
          invalid_source = true
        end
        unless invalid_source
          if unresolved_bare_upstream_url?(url, registry_root)
            reporter.error("#{skill_id}: external-git source.url must resolve within the registry root or use an explicit remote URL")
            invalid_source = true
          end
          if unresolved_relative_upstream_url?(url, registry_root)
            reporter.error("#{skill_id}: external-git source.url must resolve within the registry root")
            invalid_source = true
          end
          if relative_upstream_resolves_outside_registry?(url, registry_root)
            reporter.error("#{skill_id}: external-git source.url must resolve within the registry root")
            invalid_source = true
          end
          if ext_remote_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not use ext:: remotes")
            invalid_source = true
          end
          if remote_helper_transport_url?(url)
            reporter.error("#{skill_id}: external-git source.url must use a supported Git transport")
            invalid_source = true
          end
          if credential_bearing_scheme_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not include credentials")
            invalid_source = true
          end
          if query_or_fragment_bearing_scheme_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not include a query or fragment")
            invalid_source = true
          end
          if credential_bearing_scp_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not include credentials")
            invalid_source = true
          end
          if query_or_fragment_bearing_scp_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not include a query or fragment")
            invalid_source = true
          end
          if http_url_authority(url) && !valid_http_remote_url?(url)
            reporter.error("#{skill_id}: external-git source.url must be a valid HTTP(S) URL")
            invalid_source = true
          end
          if scheme_url?(url) && !local_file_url?(url) && http_url_authority(url).nil? && !valid_remote_scheme_url?(url)
            reporter.error("#{skill_id}: external-git source.url must be a valid remote URL")
            invalid_source = true
          end
          if local_file_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not be a local file URL")
            invalid_source = true
          end
          if home_relative_url?(url)
            reporter.error("#{skill_id}: external-git source.url must not be a local home-relative path")
            invalid_source = true
          end
          if !scheme_url?(url) && !scp_like_url?(url) && !Pathname.new(url).absolute? && !safe_relative_path?(url)
            reporter.error("#{skill_id}: external-git source.url must be a safe relative path")
            invalid_source = true
          end
          if Pathname.new(url).absolute?
            reporter.error("#{skill_id}: external-git source.url must not be a local absolute path")
            invalid_source = true
          end
        end
      end
      next if invalid_source

      by_id[skill_id] = {
        id: skill_id,
        status: skill["status"].to_s,
        source_type: source_type,
        url: url,
        path: source_path,
        pinned_tag: pinned_tag,
        observed_commit: observed_commit,
        exported_names: exported_names,
        clients: normalized_clients
      }
    else
      reporter.error("#{skill_id}: unsupported source.type")
    end
  end

  [by_id, registry_root, { id: registry_id, name: registry_name, manager_source: manager_source }]
end

def load_lock(path, registry_root, registry_by_id, reporter)
  lock = load_yaml_file(path, reporter)
  unless lock.is_a?(Hash)
    reporter.error("#{display_path(path, root: registry_root)} must contain a top-level mapping") unless lock.nil?
    return {}
  end

  entries = mapping_array(lock["skills"], reporter, "#{display_path(path, root: registry_root)} skills")
  by_id = {}
  entries.each do |entry|
    skill_id = entry["id"]
    if !skill_id.is_a?(String) || skill_id.strip.empty? || contains_control_characters?(skill_id)
      reporter.error("#{display_path(path, root: registry_root)} lock entries must include non-empty string id")
      next
    end
    unless safe_non_path_identifier?(skill_id)
      reporter.error("#{display_path(path, root: registry_root)} lock entries must use safe non-path identifiers")
      next
    end
    if by_id.key?(skill_id)
      reporter.error("#{display_path(path, root: registry_root)} duplicate lock entry id #{skill_id}")
      next
    end
    by_id[skill_id] = entry
  end

  registry_by_id.each do |skill_id, skill|
    locked = by_id[skill_id]
    if locked.nil?
      reporter.error("#{display_path(path, root: registry_root)} missing lock entry for #{skill_id}")
      next
    end

    lock_exported_names = locked["exported_names"]
    unless lock_exported_names.is_a?(Array) && lock_exported_names.all? { |name| name.is_a?(String) }
      reporter.error("#{skill_id}: lock exported_names must be an array of strings")
      next
    end

    if skill[:source_type] == "external-git"
      invalid_external_lock = false
      {
        "source_type" => locked["source_type"],
        "path" => locked["path"],
        "url" => locked["url"],
        "pinned_tag" => locked["pinned_tag"],
        "observed_commit" => locked["observed_commit"]
      }.each do |field, value|
        next if value.is_a?(String)

        reporter.error("#{skill_id}: lock #{field} must be a string")
        invalid_external_lock = true
      end
      reporter.error("#{skill_id}: lock exported_names differ from registry") if lock_exported_names != skill[:exported_names]
      next if invalid_external_lock

      reporter.error("#{skill_id}: lock source_type differs from registry") if locked["source_type"] != skill[:source_type]
      reporter.error("#{skill_id}: lock path differs from registry") if locked["path"] != skill[:path]
      %w[url pinned_tag observed_commit].each do |field|
        reporter.error("#{skill_id}: lock #{field} differs from registry") unless equivalent_external_lock_value?(field, locked[field], skill[field.to_sym])
      end
    else
      reporter.error("#{skill_id}: lock source_type differs from registry") if locked["source_type"] != skill[:source_type]
      reporter.error("#{skill_id}: lock path differs from registry") if locked["path"] != skill[:path]
      reporter.error("#{skill_id}: lock exported_names differ from registry") if lock_exported_names != skill[:exported_names]
      if !valid_sha256_hex?(locked["digest_sha256"])
        reporter.error("#{skill_id}: lock digest_sha256 must be a 64-character hex SHA-256")
      elsif skill[:source_digest_sha256] && locked["digest_sha256"] != skill[:source_digest_sha256]
        reporter.error("#{skill_id}: lock digest_sha256 does not match registry-local source contents")
      end
    end
  end

  (by_id.keys - registry_by_id.keys).sort.each do |skill_id|
    reporter.error("#{display_path(path, root: registry_root)} stale lock entry #{skill_id} is not present in the registry")
  end

  by_id
end

def infer_client(consumer_name)
  return "claude" if consumer_name.include?("claude")
  return "codex" if consumer_name.include?("codex")

  nil
end

def load_profiles(paths, registry_by_id, reporter)
  profiles = []
  loaded_profile_ids = {}
  paths.each do |path|
    profile = load_yaml_file(path, reporter)
    unless profile.is_a?(Hash)
      reporter.error("#{display_path(path)} must contain a top-level mapping") unless profile.nil?
      next
    end

    profile_metadata = mapping(profile["profile"], reporter, "#{display_path(path)} profile", allow_nil: true)
    profile_id = profile_metadata["id"]
    reporter.error("#{display_path(path)} profile.id is required") if !profile_id.is_a?(String) || profile_id.empty?
    if profile_id.is_a?(String) && !profile_id.empty? && !safe_non_path_identifier?(profile_id)
      reporter.error("#{display_path(path)} profile.id must be a safe non-path identifier")
    end
    if profile_id.is_a?(String) && !profile_id.empty? && safe_non_path_identifier?(profile_id)
      if loaded_profile_ids.key?(profile_id)
        reporter.error("#{display_path(path)} profile.id #{profile_id} duplicates #{display_path(loaded_profile_ids[profile_id])}")
      else
        loaded_profile_ids[profile_id] = path
      end
    end
    profile_status = profile["status"]
    if !profile_status.nil? && !profile_status.is_a?(String)
      reporter.error("#{display_path(path)} status must be a string when provided")
      profile_status = profile_status.to_s
    end

    roots = mapping(profile["consumer_roots"], reporter, "#{display_path(path)} consumer_roots")
    normalized_roots = roots.each_with_object({}) do |(consumer, root_config), memo|
      unless consumer.is_a?(String) && !consumer.empty?
        reporter.error("#{display_path(path)} consumer_roots keys must be non-empty strings")
        next
      end
      if contains_control_characters?(consumer)
        reporter.error("#{display_path(path)} consumer_roots keys must not contain control characters")
        next
      end
      unless safe_non_path_identifier?(consumer)
        reporter.error("#{display_path(path)} consumer_roots keys must be safe non-path identifiers")
        next
      end
      config = mapping(root_config, reporter, "#{display_path(path)} consumer_roots.#{consumer}")
      root_path = config["path"]
      if windows_path_fragment?(root_path)
        reporter.error("#{display_path(path)} consumer_roots.#{consumer} path must not be a local Windows path")
      elsif !valid_path_string?(root_path)
        reporter.error("#{display_path(path)} consumer_roots.#{consumer} path must be a non-empty valid path")
      end
      raw_adapter = config["adapter"]
      adapter =
        if raw_adapter.nil? || (raw_adapter.is_a?(String) && raw_adapter.empty?)
          "symlink"
        else
          raw_adapter
        end
      unless adapter.is_a?(String)
        reporter.error("#{display_path(path)} consumer_roots.#{consumer} adapter must be a string when provided")
        adapter = adapter.to_s
      end
      reporter.error("#{display_path(path)} consumer_roots.#{consumer} adapter must not contain control characters") if contains_control_characters?(adapter)
      if !adapter.empty? && !safe_non_path_identifier?(adapter)
        reporter.error("#{display_path(path)} consumer_roots.#{consumer} adapter must be a safe non-path identifier")
      end
      status = config["status"].to_s.empty? ? "planned" : config["status"].to_s
      memo[consumer] = config.merge("adapter" => adapter, "status" => status)
    end

    selected = mapping_array(profile["selected_skills"], reporter, "#{display_path(path)} selected_skills", allow_nil: true)
    selected.each do |selection|
      skill_id = selection["skill_id"]
      if !skill_id.is_a?(String) || skill_id.empty?
        reporter.error("#{display_path(path)} selected_skills[].skill_id must be a non-empty string")
        next
      end
      unless safe_non_path_identifier?(skill_id)
        reporter.error("#{display_path(path)} selected_skills[].skill_id must be a safe non-path identifier")
        next
      end
      reporter.error("#{display_path(path)} selected skill #{skill_id} is not in registry") unless registry_by_id.key?(skill_id)
      expose_to = string_array(selection["expose_to"], reporter, "#{display_path(path)} #{skill_id} expose_to")
      reporter.error("#{display_path(path)} #{skill_id} expose_to must list at least one consumer") if expose_to.empty?
      expose_to.each do |consumer|
        unless safe_non_path_identifier?(consumer)
          reporter.error("#{display_path(path)} #{skill_id} expose_to entries must be safe non-path identifiers")
          next
        end
        reporter.error("#{display_path(path)} #{skill_id} exposes to unknown consumer #{consumer}") unless normalized_roots.key?(consumer)
      end
      state = selection["state"]
      if !state.nil? && !state.is_a?(String)
        reporter.error("#{display_path(path)} #{skill_id} state must be a string when provided")
      elsif state.is_a?(String) && !state.empty? && !safe_non_path_identifier?(state)
        reporter.error("#{display_path(path)} #{skill_id} state must be a safe non-path identifier")
      end
      selection["expose_to"] = expose_to
    end

    profiles << {
      path: File.expand_path(path),
      id: profile_id.to_s,
      status: profile_status.to_s,
      consumer_roots: normalized_roots,
      selected_skills: selected
    }
  end

  profiles
end

def selected_state_blocked?(state)
  state.to_s.match?(/pending|blocked|disabled|manual/i)
end

def blocked_state_reason_label(states)
  unique_states = Array(states).map(&:to_s).reject(&:empty?).uniq.sort
  return nil if unique_states.empty?
  return unique_states.first if unique_states.length == 1

  "one of #{unique_states.join(', ')}"
end

def redacted_unsafe_adapter_name(value)
  return "<unsafe-adapter-name>" if windows_local_path?(value)

  value
end

def lock_summary(skill, locked)
  if skill[:source_type] == "registry-local"
    digest = locked && locked["digest_sha256"].to_s
    digest.empty? ? nil : "sha256:#{digest[0, 12]}"
  else
    tag = locked && locked["pinned_tag"].to_s
    commit = locked && locked["observed_commit"].to_s
    return nil if tag.empty? && commit.empty?

    tag_summary = tag.empty? ? nil : "tag:#{redact_local_path_fragments(tag)}"
    [tag_summary, commit.empty? ? nil : "commit:#{commit[0, 12]}"].compact.join(" ")
  end
end

def inspect_entry(target, source_absolute)
  return [:create, "adapter is missing"] unless File.exist?(target) || File.symlink?(target)

  if File.symlink?(target)
    link_target = File.readlink(target)
    real_target = File.realpath(target)
    source_real = File.realpath(source_absolute)
    if real_target == source_real
      [:keep, "adapter already points at registry source"]
    else
      [:update, "adapter symlink points at #{display_link_target(link_target).inspect}"]
    end
  elsif File.directory?(target)
    [:manual_review, "directory exists and is not a symlink adapter"]
  elsif File.file?(target)
    [:manual_review, "file exists and is not a symlink adapter"]
  else
    [:manual_review, "path exists and is not a supported adapter"]
  end
rescue Errno::ENOENT
  [:update, "adapter symlink is broken"]
rescue SystemCallError => error
  [:manual_review, "could not inspect adapter: #{redact_local_paths(error.message, known_paths: [target])}"]
end

def action_record(profile:, consumer:, skill:, exported_name:, target:, source:, action:, status:, reason:, adapter:, lock:, root:, client_status: nil, management: nil, target_path: nil, source_path: nil, root_path: nil)
  {
    "profile" => profile[:id],
    "consumer" => consumer,
    "skill_id" => skill && skill[:id],
    "exported_name" => exported_name,
    "action" => action.to_s.tr("_", "-"),
    "status" => status,
    "adapter" => adapter,
    "target" => target,
    "source" => source,
    "reason" => reason,
    "lock" => lock,
    "root" => root,
    "client_status" => client_status,
    "management" => management || manual_review_management("no upstream manager recommendation is available for this action"),
    "_target_path" => target_path,
    "_source_path" => source_path,
    "_root_path" => root_path
  }.compact
end

def public_operation(operation)
  operation.reject { |key, _value| key.start_with?("_") }
end

def public_operations(operations)
  operations.map { |operation| public_operation(operation) }
end

def action_summary(operations)
  operations.each_with_object(Hash.new(0)) { |operation, memo| memo[operation["action"]] += 1 }
end

def management_summary(operations)
  operations.each_with_object(Hash.new(0)) do |operation, memo|
    owner = operation.dig("management", "owner") || "unclassified"
    memo[owner] += 1
  end
end

def manager_agent_for_consumer(consumer, root_path)
  normalized_consumer = consumer.to_s.downcase
  normalized_root = File.expand_path(root_path.to_s).downcase

  return "claude-code" if normalized_consumer.include?("claude") || normalized_root.end_with?("/.claude/skills")
  return "antigravity" if normalized_consumer.include?("antigravity") || normalized_root.include?("/.gemini/antigravity/")
  return "gemini-cli" if normalized_consumer.include?("gemini") || normalized_root.end_with?("/.gemini/skills")
  return "cursor" if normalized_consumer.include?("cursor") || normalized_root.end_with?("/.cursor/skills")
  return "codex" if normalized_consumer.include?("codex") || normalized_consumer == "agents_user"
  return "codex" if normalized_root.end_with?("/.codex/skills") || normalized_root.end_with?("/.agents/skills")

  nil
end

def global_manager_scope?(root_path)
  expanded = File.expand_path(root_path.to_s)
  home = File.expand_path("~")
  global_roots = [
    File.join(home, ".agents", "skills"),
    File.join(home, ".codex", "skills"),
    File.join(home, ".claude", "skills"),
    File.join(home, ".cursor", "skills")
  ]

  return true if global_roots.include?(expanded)
  gemini_root = File.join(home, ".gemini", "")
  return true if expanded.start_with?(gemini_root) && expanded.end_with?("/skills")

  false
end

def manager_command(operation, source:, skill_name:, agent:, scope:)
  tokens =
    case operation
    when "add"
      ["npx", "--yes", DEFAULT_SKILLS_CLI_PACKAGE, "add", source, "--skill", skill_name, "--agent", agent]
    when "remove"
      ["npx", "--yes", DEFAULT_SKILLS_CLI_PACKAGE, "remove", "--skill", skill_name, "--agent", agent]
    else
      return nil
    end

  tokens << "--global" if scope == "global"
  tokens << "--yes"
  Shellwords.join(tokens)
end

def no_management_action(reason)
  {
    "owner" => "none",
    "reason" => reason
  }
end

def manual_review_management(reason)
  {
    "owner" => "manual-review",
    "reason" => reason
  }
end

def upstream_manager_management(operation:, command:, agent:, scope:, reason:)
  {
    "owner" => "upstream-manager",
    "operation" => operation,
    "agent" => agent,
    "scope" => scope,
    "command" => command,
    "reason" => reason
  }
end

def manager_actionable_status?(status, reason)
  return true if status == "planned"

  status == "blocked" && reason.to_s.include?("is not supported by the report-only sync planner")
end

def desired_manager_recommendation(skill:, exported_name:, consumer:, root_path:, action:, status:, reason:, adapter:, selection_state:, registry_metadata:)
  return no_management_action("adapter already matches the reviewed plan") if status == "ok"
  return manual_review_management("selected skill state is #{selection_state}") if selected_state_blocked?(selection_state)
  return manual_review_management(reason || "planner action requires manual review") unless manager_actionable_status?(status, reason)
  unless skill && skill[:source_type] == "registry-local"
    return manual_review_management("non-registry-local skills need source review before manager command generation")
  end

  manager_source = registry_metadata[:manager_source]
  return manual_review_management("registry.manager_source is not declared") if manager_source.to_s.empty?

  agent = manager_agent_for_consumer(consumer, root_path)
  return manual_review_management("consumer #{consumer} does not map to a supported upstream skills agent") if agent.nil?
  return manual_review_management("consumer root is not a recognized global skills root") unless global_manager_scope?(root_path)

  manager_skill_name = skill[:manager_skill_name].to_s
  return manual_review_management("registry-local SKILL.md name is unavailable for upstream manager selection") if manager_skill_name.empty?
  return manual_review_management("registry exports #{exported_name}, but upstream manager selects #{manager_skill_name}") if exported_name != manager_skill_name

  command = manager_command("add", source: manager_source, skill_name: manager_skill_name, agent: agent, scope: "global")
  upstream_manager_management(
    operation: "add",
    command: command,
    agent: agent,
    scope: "global",
    reason: "use the pinned upstream skills manager to install or repair this global skill"
  )
end

def stale_manager_recommendation(skill:, exported_name:, consumer:, root_path:, action:, status:, reason:, registry_metadata:)
  return no_management_action("no manager action is needed") if status == "ok"
  return manual_review_management(reason || "stale adapter requires manual review") unless action == "remove-stale" && status == "planned"
  unless skill && skill[:source_type] == "registry-local"
    return manual_review_management("non-registry-local stale adapter cleanup needs source review")
  end
  manager_source = registry_metadata[:manager_source]
  return manual_review_management("registry.manager_source is not declared") if manager_source.to_s.empty?

  agent = manager_agent_for_consumer(consumer, root_path)
  return manual_review_management("consumer #{consumer} does not map to a supported upstream skills agent") if agent.nil?
  return manual_review_management("consumer root is not a recognized global skills root") unless global_manager_scope?(root_path)

  manager_skill_name = skill[:manager_skill_name].to_s
  return manual_review_management("registry-local SKILL.md name is unavailable for upstream manager selection") if manager_skill_name.empty?
  return manual_review_management("registry exports #{exported_name}, but upstream manager selects #{manager_skill_name}") if exported_name != manager_skill_name

  command = manager_command("remove", source: manager_source, skill_name: manager_skill_name, agent: agent, scope: "global")
  upstream_manager_management(
    operation: "remove",
    command: command,
    agent: agent,
    scope: "global",
    reason: "use the pinned upstream skills manager to remove this global skill from the selected agent"
  )
end

def duplicate_target_message(profile_id, skill_id, display_target, previous)
  if previous[:profile_id] == profile_id
    "#{profile_id} maps #{display_target} from both #{previous[:skill_id]} and #{skill_id}"
  else
    "#{profile_id} maps #{display_target} from #{skill_id}, but #{previous[:profile_id]} already selects the same target"
  end
end

def build_consumer_root_index(profiles)
  profiles.each_with_object(Hash.new { |memo, key| memo[key] = [] }) do |profile, memo|
    profile_base = File.dirname(profile[:path])
    profile[:consumer_roots].each do |consumer, root_config|
      root_path = root_config["path"]
      next unless valid_path_string?(root_path)

      expanded_root = expand_config_path(root_path, base_dir: profile_base)
      root_key = canonical_existing_path(expanded_root)
      memo[root_key] << {
        profile_id: profile[:id],
        consumer: consumer,
        adapter: root_config["adapter"].to_s
      }
    end
  end
end

def build_blocked_selected_state_index(profiles)
  profiles.each_with_object(Hash.new { |memo, key| memo[key] = [] }) do |profile, memo|
    profile_base = File.dirname(profile[:path])
    root_keys_by_consumer = profile[:consumer_roots].each_with_object({}) do |(consumer, root_config), consumer_roots|
      root_path = root_config["path"]
      next unless valid_path_string?(root_path)

      expanded_root = expand_config_path(root_path, base_dir: profile_base)
      consumer_roots[consumer] = canonical_existing_path(expanded_root)
    end

    profile[:selected_skills].each do |selection|
      state = selection["state"]
      next unless selected_state_blocked?(state)

      Array(selection["expose_to"]).each do |consumer|
        root_key = root_keys_by_consumer[consumer]
        next unless root_key

        memo[[root_key, selection["skill_id"]]] << state
      end
    end
  end
end

def shared_root_stale_conflict_reason(root_entries)
  return nil if root_entries.nil? || root_entries.length < 2

  adapters = root_entries.map { |entry| entry[:adapter] }.uniq.sort
  unsupported = adapters.reject { |adapter| supported_adapter?(adapter) }
  return nil if unsupported.empty? && adapters.length == 1

  profile_adapters = root_entries.map { |entry| "#{entry[:profile_id]}=#{entry[:adapter]}" }.uniq.sort.join(", ")
  "consumer root is shared across loaded profiles with unsupported or conflicting adapters (#{profile_adapters})"
end

def plan_desired_adapters(profile, registry_by_id, lock_by_id, registry_root, registry_metadata, reporter, global_desired_by_target, consumer_root_index)
  desired_by_target = {}
  operations = []
  profile_base = File.dirname(profile[:path])

  profile[:selected_skills].each do |selection|
    skill = registry_by_id[selection["skill_id"]]
    next unless skill

    Array(selection["expose_to"]).each do |consumer|
      root_config = profile[:consumer_roots][consumer]
      next unless root_config

      root_path = root_config["path"]
      next unless valid_path_string?(root_path)

      expanded_root = expand_config_path(root_path, base_dir: profile_base)
      root_key = canonical_existing_path(expanded_root)
      adapter = root_config["adapter"].to_s
      root_exists = File.exist?(expanded_root) || File.symlink?(expanded_root)
      root_is_directory = File.directory?(expanded_root)
      root_listing_error = root_exists && root_is_directory ? consumer_root_listing_error(expanded_root) : nil
      root_obstruction = root_exists ? nil : obstructing_ancestor(expanded_root)
      shared_root_conflict = shared_root_stale_conflict_reason(consumer_root_index[root_key])
      client = infer_client(consumer)
      client_status = client && skill[:clients][client]
      Array(skill[:exported_names]).each do |exported_name|
        target = File.join(expanded_root, exported_name)
        target_key = canonical_path_for_display(target)
        display_target = display_path(target, root: registry_root)
        previous = desired_by_target[target_key] || global_desired_by_target[target_key]
        if previous
          reporter.error(duplicate_target_message(profile[:id], skill[:id], display_target, previous))
          next
        end
        desired_by_target[target_key] = {
          profile_id: profile[:id],
          skill_id: skill[:id],
          consumer: consumer,
          exported_name: exported_name,
          adapter: adapter
        }

        lock = lock_summary(skill, lock_by_id[skill[:id]])
        display_root = display_path(expanded_root, root: registry_root)
        source_display = nil
        action = nil
        status = "planned"
        reason = nil

        if selected_state_blocked?(selection["state"])
          action = "blocked"
          status = "blocked"
          reason = "selected skill state is #{selection["state"]}"
        elsif !supported_adapter?(adapter)
          action = "blocked"
          status = "blocked"
          reason = "adapter type #{adapter.inspect} is not supported by the report-only sync planner"
        elsif root_obstruction
          action = "blocked"
          status = "blocked"
          reason = "consumer root is obstructed by ancestor #{display_path(root_obstruction, root: registry_root)} that is not a directory"
        elsif root_exists && !root_is_directory
          action = "blocked"
          status = "blocked"
          reason = "consumer root exists but is not a directory"
        elsif root_listing_error
          action = "manual-review"
          status = "blocked"
          reason = "could not inspect consumer root: #{root_listing_error}"
        elsif skill[:source_type] != "registry-local"
          action = "blocked"
          status = "blocked"
          reason = "external-git source must be imported or otherwise materialized before adapter creation"
        elsif !File.directory?(skill[:source_absolute])
          action = "blocked"
          status = "blocked"
          reason = "registry source directory is missing"
        elsif shared_root_conflict
          action = "manual-review"
          status = "blocked"
          reason = shared_root_conflict
        else
          source_display = display_path(skill[:source_absolute], root: registry_root)
          action, reason = inspect_entry(target, skill[:source_absolute])
          status = action == :keep ? "ok" : "planned"
          if action == :manual_review
            action = "manual-review"
            status = "blocked"
          elsif !root_exists
            reason = "consumer root is missing; upstream manager install is expected to create or repair it"
          end
        end

        operations << action_record(
          profile: profile,
          consumer: consumer,
          skill: skill,
          exported_name: exported_name,
          target: display_target,
          source: source_display,
          action: action,
          status: status,
          reason: reason,
          adapter: adapter,
          lock: lock,
          root: display_root,
          client_status: client_status,
          management: desired_manager_recommendation(
            skill: skill,
            exported_name: exported_name,
            consumer: consumer,
            root_path: expanded_root,
            action: action.to_s.tr("_", "-"),
            status: status,
            reason: reason,
            adapter: adapter,
            selection_state: selection["state"],
            registry_metadata: registry_metadata
          ),
          target_path: target,
          source_path: source_display ? skill[:source_absolute] : nil,
          root_path: expanded_root
        )
      end
    end
  end

  [operations, desired_by_target]
end

def plan_stale_adapters(profile, registry_by_id, registry_root, registry_metadata, desired_by_target, seen_stale_targets, consumer_root_index, blocked_selected_states_by_root_and_skill)
  registry_source_entries = registry_local_source_entries(registry_by_id)
  exported_names = registry_by_id.values.each_with_object({}) do |skill, memo|
    skill[:exported_names].each { |name| memo[name] = skill }
  end
  selected_states_by_consumer_and_skill = profile[:selected_skills].each_with_object({}) do |selection, memo|
    state = selection["state"]
    next unless selected_state_blocked?(state)

    Array(selection["expose_to"]).each do |consumer|
      memo[[consumer, selection["skill_id"]]] = state
    end
  end
  profile_base = File.dirname(profile[:path])
  operations = []

  profile[:consumer_roots].each do |consumer, root_config|
    root_path = root_config["path"]
    next unless valid_path_string?(root_path)

    expanded_root = expand_config_path(root_path, base_dir: profile_base)
    adapter = root_config["adapter"].to_s
    root_key = canonical_existing_path(expanded_root)
    root_display = display_path(expanded_root, root: registry_root)
    shared_root_conflict = shared_root_stale_conflict_reason(consumer_root_index[root_key])
    next unless File.directory?(expanded_root)

    entry_names =
      begin
        Dir.children(expanded_root).sort
      rescue SystemCallError => error
        root_failure_key = "#{root_key}\0root-listing"
        next if seen_stale_targets.key?(root_failure_key)

        operations << action_record(
          profile: profile,
          consumer: consumer,
          skill: nil,
          exported_name: "*",
          target: root_display,
          source: nil,
          action: "manual-review",
          status: "blocked",
          reason: "could not inspect consumer root: #{redact_local_paths(error.message, known_paths: [expanded_root])}",
          adapter: adapter,
          lock: nil,
          root: root_display
        )
        seen_stale_targets[root_failure_key] = true
        next
      end

    entry_names.each do |entry_name|
      target = File.join(expanded_root, entry_name)
      target_key = canonical_path_for_display(target)
      next if desired_by_target.key?(target_key)
      next if seen_stale_targets.key?(target_key)

      target_display = display_path(target, root: registry_root)
      unless safe_adapter_name?(entry_name)
        if File.symlink?(target)
          begin
            target_real = File.realpath(target)
            matched_registry_source = registry_source_entries.find { |entry| path_within?(target_real, entry[:source_root]) }
            if matched_registry_source
              display_exported_name = redacted_unsafe_adapter_name(entry_name)
              operations << action_record(
                profile: profile,
                consumer: consumer,
                skill: matched_registry_source[:skill],
                exported_name: display_exported_name,
                target: File.join(root_display, display_exported_name),
                source: nil,
                action: "manual-review",
                status: "blocked",
                reason: "registry-managed symlink uses an unsafe adapter name and requires manual review",
                adapter: adapter,
                lock: nil,
                root: root_display
              )
              seen_stale_targets[target_key] = true
            end
          rescue SystemCallError
            nil
          end
        end
        next
      end

      skill = exported_names[entry_name]
      append_operation = lambda do |action:, status:, reason:, skill_record: skill|
        operations << action_record(
          profile: profile,
          consumer: consumer,
          skill: skill_record,
          exported_name: entry_name,
          target: target_display,
          source: nil,
          action: action,
          status: status,
          reason: reason,
          adapter: adapter,
          lock: nil,
          root: root_display,
          management: stale_manager_recommendation(
            skill: skill_record,
            exported_name: entry_name,
            consumer: consumer,
            root_path: expanded_root,
            action: action,
            status: status,
            reason: reason,
            registry_metadata: registry_metadata
          )
        )
        seen_stale_targets[target_key] = true
      end

      if skill && skill[:source_type] != "registry-local"
        append_operation.call(
          action: "manual-review",
          status: "blocked",
          reason: "registry-named entry maps to an external-git source and is not managed by the report-only sync planner"
        )
        next
      end

      if File.symlink?(target)
        begin
          target_real = File.realpath(target)
          matched_registry_source = registry_source_entries.find { |entry| path_within?(target_real, entry[:source_root]) }
          skill ||= matched_registry_source && matched_registry_source[:skill]
          next unless skill
          selected_state = blocked_state_reason_label(
            blocked_selected_states_by_root_and_skill[[root_key, skill[:id]]] ||
            selected_states_by_consumer_and_skill[[consumer, skill[:id]]]
          )

          stale_export_name = !exported_names.key?(entry_name)
          next if stale_export_name && !matched_registry_source

          expected_source_root =
            if stale_export_name
              matched_registry_source[:source_root]
            else
              File.realpath(skill[:source_absolute])
            end

          if target_real == expected_source_root
            if selected_state
              append_operation.call(
                action: "manual-review",
                status: "blocked",
                reason:
                  if stale_export_name
                    "selected skill state is #{selected_state}, so stale adapter rename requires manual review"
                  else
                    "selected skill state is #{selected_state}, so stale adapter cleanup requires manual review"
                  end
              )
            elsif shared_root_conflict
              append_operation.call(
                action: "manual-review",
                status: "blocked",
                reason:
                  if stale_export_name
                    "registry adapter name is no longer exported by the registry, but #{shared_root_conflict}"
                  else
                    "registry adapter exists in this consumer root but #{shared_root_conflict}"
                  end
              )
            elsif supported_adapter?(adapter)
              append_operation.call(
                action: "remove-stale",
                status: "planned",
                reason:
                  if stale_export_name
                    "registry adapter name is no longer exported by the registry but still points at the skill source"
                  else
                    "registry adapter exists in this consumer root but is not selected by the profile"
                  end
              )
            else
              append_operation.call(
                action: "manual-review",
                status: "blocked",
                reason:
                  if stale_export_name
                    "registry adapter name is no longer exported by the registry and adapter type #{adapter.inspect} is not supported by the report-only sync planner"
                  else
                    "registry adapter exists in this consumer root but adapter type #{adapter.inspect} is not supported by the report-only sync planner"
                  end
              )
            end
          elsif path_within?(target_real, expected_source_root)
            append_operation.call(
              action: "manual-review",
              status: "blocked",
              reason:
                if stale_export_name
                  "registry adapter name is no longer exported by the registry and the symlink points to a subpath inside the skill source"
                else
                  "registry-named symlink points to a subpath inside the skill source and is not selected by the profile"
                end
            )
          else
            append_operation.call(
              action: "manual-review",
              status: "blocked",
              reason: "registry-named symlink does not point at the expected skill source"
            )
          end
        rescue SystemCallError
          next unless skill

          append_operation.call(
            action: "manual-review",
            status: "blocked",
            reason: "broken registry-named symlink is not selected by the profile"
          )
        end
      elsif skill && File.exist?(target)
        append_operation.call(
          action: "manual-review",
          status: "blocked",
          reason: "registry-named non-symlink entry is not selected by the profile"
        )
      end
    end
  end

  operations
end

def build_plan(profiles, registry_by_id, lock_by_id, registry_root, registry_metadata, reporter)
  global_desired_by_target = {}
  global_stale_targets = {}
  consumer_root_index = build_consumer_root_index(profiles)
  blocked_selected_states_by_root_and_skill = build_blocked_selected_state_index(profiles)
  operations = []
  profiles.each do |profile|
    desired_ops, desired_by_target = plan_desired_adapters(
      profile,
      registry_by_id,
      lock_by_id,
      registry_root,
      registry_metadata,
      reporter,
      global_desired_by_target,
      consumer_root_index
    )
    global_desired_by_target.merge!(desired_by_target)
    operations.concat(desired_ops)
  end
  profiles.each do |profile|
    operations.concat(
      plan_stale_adapters(
        profile,
        registry_by_id,
        registry_root,
        registry_metadata,
        global_desired_by_target,
        global_stale_targets,
        consumer_root_index,
        blocked_selected_states_by_root_and_skill
      )
    )
  end
  operations.sort_by { |operation| [operation["profile"], operation["consumer"], operation["target"], operation["action"]] }
end

def print_human_plan(registry_path, lock_path, profile_paths, operations, reporter, registry_root)
  puts "# Skills Sync Plan"
  puts
  puts "Mode: report-only; no filesystem changes were made"
  puts "Registry: #{display_path(registry_path, root: registry_root)}"
  puts "Lock: #{display_path(lock_path, root: registry_root)}"
  puts "Profiles:"
  profile_paths.each { |path| puts "- #{display_path(path, root: registry_root)}" }
  puts

  unless reporter.errors.empty?
    puts "## Errors"
    reporter.errors.each { |message| puts "- error: #{message}" }
    return if operations.empty?

    puts
  end

  unless reporter.warnings.empty?
    puts "## Warnings"
    reporter.warnings.each { |message| puts "- warning: #{message}" }
    puts
  end

  puts "## Actions"
  if operations.empty?
    puts "- no adapter actions"
  else
    operations.each do |operation|
      parts = [
        operation["action"],
        operation["status"],
        "#{operation["consumer"]}/#{operation["exported_name"]}",
        "target=#{operation["target"]}"
      ]
      parts << "source=#{operation["source"]}" if operation["source"]
      parts << "lock=#{operation["lock"]}" if operation["lock"]
      parts << "client=#{operation["client_status"]}" if operation["client_status"]
      if operation["management"]
        management_label = operation["management"]["owner"].to_s
        operation_label = operation["management"]["operation"].to_s
        management_label = "#{management_label}:#{operation_label}" unless operation_label.empty?
        parts << "management=#{management_label}"
        parts << "manager_command=#{operation["management"]["command"]}" if operation["management"]["command"]
        parts << "manager_reason=#{operation["management"]["reason"]}" if operation["management"]["reason"]
      end
      parts << "reason=#{operation["reason"]}" if operation["reason"]
      puts "- #{parts.join(" | ")}"
    end
  end

  counts = action_summary(operations)
  blocked_count = operations.count { |operation| operation["status"] == "blocked" }
  puts
  puts "## Summary"
  if counts.empty?
    puts "- total: 0"
  else
    puts "- total: #{operations.length}"
    counts.sort.each { |action, count| puts "- #{action}: #{count}" }
  end
  management_summary(public_operations(operations)).sort.each { |owner, count| puts "- management #{owner}: #{count}" }
  puts "- blocked/manual-review: #{blocked_count}"
end

options = {
  plan: false,
  registry: ROOT.join("skills.registry.yaml").to_s,
  lock: nil,
  profiles: [],
  json: false
}

parser = OptionParser.new do |opts|
  opts.banner = "usage: scripts/skills_sync.rb --plan [options]"
  opts.on("--plan", "Print a report-only adapter sync plan") { options[:plan] = true }
  opts.on("--registry PATH", "Registry manifest path") { |value| options[:registry] = value }
  opts.on("--lock PATH", "Lock file path") { |value| options[:lock] = value }
  opts.on("--profile PATH", "Profile path; can be repeated") { |value| options[:profiles] << value }
  opts.on("--json", "Print machine-readable JSON") { options[:json] = true }
end
parser.parse!

unless options[:plan]
  warn "choose --plan"
  warn parser.to_s
  exit 2
end

reporter = Reporter.new
registry_path = File.expand_path(options[:registry])
registry_by_id, registry_root, registry_metadata = load_registry(registry_path, reporter)
registry_root ||= Pathname.new(File.dirname(registry_path))
registry_metadata ||= {}
lock_path =
  if options[:lock]
    File.expand_path(options[:lock], registry_root.to_s)
  else
    registry_root.join("skills.lock.yaml").to_s
  end
lock_by_id = load_lock(lock_path, registry_root, registry_by_id, reporter)
selected_profile_paths = profile_paths(options, registry_path)
if selected_profile_paths.empty?
  reporter.error("at least one profile YAML must be loaded; pass --profile or add files under profiles/")
end
profiles = load_profiles(selected_profile_paths, registry_by_id, reporter)
operations = reporter.errors.empty? ? build_plan(profiles, registry_by_id, lock_by_id, registry_root, registry_metadata, reporter) : []
public_actions = public_operations(operations)

if options[:json]
  puts JSON.pretty_generate(
    {
      "mode" => "plan",
      "changed_filesystem" => false,
      "registry" => display_path(registry_path, root: registry_root),
      "lock" => display_path(lock_path, root: registry_root),
      "profiles" => selected_profile_paths.map { |path| display_path(path, root: registry_root) },
      "errors" => reporter.errors,
      "warnings" => reporter.warnings,
      "actions" => public_actions,
      "summary" => action_summary(public_actions),
      "management_summary" => management_summary(public_actions)
    }
  )
else
  print_human_plan(
    registry_path,
    lock_path,
    selected_profile_paths,
    operations,
    reporter,
    registry_root
  )
end

exit(reporter.errors.empty? ? 0 : 1)
