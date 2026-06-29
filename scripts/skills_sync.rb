#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "optparse"
require "pathname"
require "uri"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze

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

def redact_local_paths(message)
  return message.to_s if show_local_paths?

  message.to_s.gsub(%r{(?<![[:alnum:]_.-])/(?:[^[:space:]'"]+)}, "<absolute-path>")
end

def display_link_target(target)
  value = target.to_s
  return value unless value.start_with?("/") || value.start_with?("~")
  return value if show_local_paths?

  "<absolute-path>"
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
  reporter.error("#{display_path(path)} could not be read: #{redact_local_paths(error.message)}")
  nil
end

def contains_control_characters?(value)
  value.is_a?(String) && /[\x00-\x1F\x7F]/.match?(value)
end

def valid_path_string?(value)
  return false unless value.is_a?(String) && !value.empty?
  return false if contains_control_characters?(value)
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
  return false if [".", ".."].include?(value)

  path = Pathname.new(value)
  path.cleanpath.to_s == value &&
    path.each_filename.to_a.length == 1 &&
    path.each_filename.first == value
rescue ArgumentError
  false
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

def windows_drive_letter_path?(value)
  value.is_a?(String) && /\A[a-z]:(?:[\\\/]|[^\\\/]|$)/i.match?(value)
end

def windows_unc_path?(value)
  value.is_a?(String) && (value.start_with?("\\\\") || value.match?(%r{\A//[^/\\]}))
end

def windows_local_path?(value)
  windows_drive_letter_path?(value) || windows_unc_path?(value)
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

def load_registry(path, reporter)
  registry = load_yaml_file(path, reporter)
  unless registry.is_a?(Hash)
    reporter.error("#{display_path(path)} must contain a top-level mapping") unless registry.nil?
    return [{}, nil]
  end

  registry_root = Pathname.new(File.dirname(File.expand_path(path))).realpath
  registry_root_real = registry_root.realpath
  registry_metadata = mapping(registry["registry"], reporter, "registry metadata", allow_nil: true)
  registry_id = registry_metadata["id"]
  registry_name = registry_metadata["name"]
  reporter.error("registry.id must be a string") unless registry_id.nil? || registry_id.is_a?(String)
  reporter.error("registry.name must be a string") unless registry_name.nil? || registry_name.is_a?(String)
  reporter.error("registry.id is required") if !registry_id.is_a?(String) || registry_id.empty?
  reporter.error("registry.name is required") if !registry_name.is_a?(String) || registry_name.empty?

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

  skills.each do |skill|
    skill_id = skill["id"]
    if !skill_id.is_a?(String) || skill_id.strip.empty? || contains_control_characters?(skill_id)
      reporter.error("skill entry id must be a non-empty string without control characters")
      next
    end

    if by_id.key?(skill_id)
      reporter.error("duplicate skill id #{skill_id}")
      next
    end

    source = mapping(skill["source"], reporter, "#{skill_id}: source")
    exported_names = string_array(skill["exported_names"], reporter, "#{skill_id}: exported_names")
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

    source_type = source["type"]
    case source_type
    when "registry-local"
      source_path = source["path"]
      unless safe_adapter_name?(source_path)
        reporter.error("#{skill_id}: registry-local source.path must name a top-level skill directory")
        next
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
        exported_names: exported_names,
        clients: skill["clients"].is_a?(Hash) ? skill["clients"] : {}
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
        clients: skill["clients"].is_a?(Hash) ? skill["clients"] : {}
      }
    else
      reporter.error("#{skill_id}: unsupported source.type #{source_type.inspect}")
    end
  end

  [by_id, registry_root]
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
        reporter.error("#{skill_id}: lock #{field} differs from registry") if locked[field] != skill[field.to_sym]
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
  paths.each do |path|
    profile = load_yaml_file(path, reporter)
    unless profile.is_a?(Hash)
      reporter.error("#{display_path(path)} must contain a top-level mapping") unless profile.nil?
      next
    end

    profile_metadata = mapping(profile["profile"], reporter, "#{display_path(path)} profile", allow_nil: true)
    profile_id = profile_metadata["id"]
    reporter.error("#{display_path(path)} profile.id is required") if !profile_id.is_a?(String) || profile_id.empty?

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
      config = mapping(root_config, reporter, "#{display_path(path)} consumer_roots.#{consumer}")
      root_path = config["path"]
      reporter.error("#{display_path(path)} consumer_roots.#{consumer} path must be a non-empty valid path") unless valid_path_string?(root_path)
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
      reporter.error("#{display_path(path)} selected skill #{skill_id} is not in registry") unless registry_by_id.key?(skill_id)
      expose_to = string_array(selection["expose_to"], reporter, "#{display_path(path)} #{skill_id} expose_to")
      reporter.error("#{display_path(path)} #{skill_id} expose_to must list at least one consumer") if expose_to.empty?
      expose_to.each do |consumer|
        reporter.error("#{display_path(path)} #{skill_id} exposes to unknown consumer #{consumer}") unless normalized_roots.key?(consumer)
      end
      selection["expose_to"] = expose_to
    end

    profiles << {
      path: File.expand_path(path),
      id: profile_id.to_s,
      consumer_roots: normalized_roots,
      selected_skills: selected
    }
  end

  profiles
end

def selected_state_blocked?(state)
  state.to_s.match?(/pending|blocked|disabled|manual/i)
end

def lock_summary(skill, locked)
  if skill[:source_type] == "registry-local"
    digest = locked && locked["digest_sha256"].to_s
    digest.empty? ? nil : "sha256:#{digest[0, 12]}"
  else
    tag = locked && locked["pinned_tag"].to_s
    commit = locked && locked["observed_commit"].to_s
    return nil if tag.empty? && commit.empty?

    [tag.empty? ? nil : "tag:#{tag}", commit.empty? ? nil : "commit:#{commit[0, 12]}"].compact.join(" ")
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
  [:manual_review, "could not inspect adapter: #{redact_local_paths(error.message)}"]
end

def action_record(profile:, consumer:, skill:, exported_name:, target:, source:, action:, status:, reason:, adapter:, lock:, root:, client_status: nil)
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
    "client_status" => client_status
  }.compact
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
      root_key = canonical_path_for_display(expanded_root)
      memo[root_key] << {
        profile_id: profile[:id],
        consumer: consumer,
        adapter: root_config["adapter"].to_s
      }
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

def plan_desired_adapters(profile, registry_by_id, lock_by_id, registry_root, reporter, global_desired_by_target)
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
      adapter = root_config["adapter"].to_s
      root_exists = File.exist?(expanded_root) || File.symlink?(expanded_root)
      root_is_directory = File.directory?(expanded_root)
      root_obstruction = root_exists ? nil : obstructing_ancestor(expanded_root)
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
        elsif skill[:source_type] != "registry-local"
          action = "blocked"
          status = "blocked"
          reason = "external-git source must be imported or otherwise materialized before adapter creation"
        elsif !File.directory?(skill[:source_absolute])
          action = "blocked"
          status = "blocked"
          reason = "registry source directory is missing"
        else
          source_display = display_path(skill[:source_absolute], root: registry_root)
          action, reason = inspect_entry(target, skill[:source_absolute])
          status = action == :keep ? "ok" : "planned"
          if action == :manual_review
            action = "manual-review"
            status = "blocked"
          elsif !root_exists
            reason = "consumer root is missing; apply would create it before linking"
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
          client_status: client_status
        )
      end
    end
  end

  [operations, desired_by_target]
end

def plan_stale_adapters(profile, registry_by_id, registry_root, desired_by_target, seen_stale_targets, consumer_root_index)
  registry_source_entries = registry_by_id.values.each_with_object([]) do |skill, memo|
    next unless skill[:source_type] == "registry-local"

    source_root = File.realpath(skill[:source_absolute])
    memo << { skill: skill, source_root: source_root }
  rescue SystemCallError
    next
  end
  exported_names = registry_by_id.values.each_with_object({}) do |skill, memo|
    skill[:exported_names].each { |name| memo[name] = skill }
  end
  profile_base = File.dirname(profile[:path])
  operations = []

  profile[:consumer_roots].each do |consumer, root_config|
    root_path = root_config["path"]
    next unless valid_path_string?(root_path)

    expanded_root = expand_config_path(root_path, base_dir: profile_base)
    adapter = root_config["adapter"].to_s
    root_key = canonical_path_for_display(expanded_root)
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
          reason: "could not inspect consumer root: #{redact_local_paths(error.message)}",
          adapter: adapter,
          lock: nil,
          root: root_display
        )
        seen_stale_targets[root_failure_key] = true
        next
      end

    entry_names.each do |entry_name|
      next unless safe_adapter_name?(entry_name)

      target = File.join(expanded_root, entry_name)
      target_key = canonical_path_for_display(target)
      next if desired_by_target.key?(target_key)
      next if seen_stale_targets.key?(target_key)

      skill = exported_names[entry_name]
      target_display = display_path(target, root: registry_root)
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
          root: root_display
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

          stale_export_name = !exported_names.key?(entry_name)
          next if stale_export_name && !matched_registry_source

          expected_source_root =
            if stale_export_name
              matched_registry_source[:source_root]
            else
              File.realpath(skill[:source_absolute])
            end

          if target_real == expected_source_root
            if shared_root_conflict
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

def build_plan(profiles, registry_by_id, lock_by_id, registry_root, reporter)
  global_desired_by_target = {}
  global_stale_targets = {}
  consumer_root_index = build_consumer_root_index(profiles)
  operations = []
  profiles.each do |profile|
    desired_ops, desired_by_target = plan_desired_adapters(
      profile,
      registry_by_id,
      lock_by_id,
      registry_root,
      reporter,
      global_desired_by_target
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
        global_desired_by_target,
        global_stale_targets,
        consumer_root_index
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
    return
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
      parts << "reason=#{operation["reason"]}" if operation["reason"]
      puts "- #{parts.join(" | ")}"
    end
  end

  counts = operations.each_with_object(Hash.new(0)) { |operation, memo| memo[operation["action"]] += 1 }
  blocked_count = operations.count { |operation| operation["status"] == "blocked" }
  puts
  puts "## Summary"
  if counts.empty?
    puts "- total: 0"
  else
    puts "- total: #{operations.length}"
    counts.sort.each { |action, count| puts "- #{action}: #{count}" }
  end
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
  warn parser.to_s
  exit 2
end

reporter = Reporter.new
registry_path = File.expand_path(options[:registry])
registry_by_id, registry_root = load_registry(registry_path, reporter)
registry_root ||= Pathname.new(File.dirname(registry_path))
lock_path =
  if options[:lock]
    File.expand_path(options[:lock], registry_root.to_s)
  else
    registry_root.join("skills.lock.yaml").to_s
  end
lock_by_id = load_lock(lock_path, registry_root, registry_by_id, reporter)
selected_profile_paths = profile_paths(options, registry_path)
profiles = load_profiles(selected_profile_paths, registry_by_id, reporter)
operations = reporter.errors.empty? ? build_plan(profiles, registry_by_id, lock_by_id, registry_root, reporter) : []

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
      "actions" => operations,
      "summary" => operations.each_with_object(Hash.new(0)) { |operation, memo| memo[operation["action"]] += 1 }
    }
  )
else
  print_human_plan(registry_path, lock_path, selected_profile_paths, operations, reporter, registry_root)
end

exit(reporter.errors.empty? ? 0 : 1)
