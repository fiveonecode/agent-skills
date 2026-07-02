#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
CATALOG_SCHEMA_VERSION = "0.1"
GENERATOR = "scripts/skills_catalog.rb"
DEFAULT_SKILLS_CLI_PACKAGE = "skills@1.5.14"

PUBLIC_UNSAFE_PATTERNS = {
  "macOS user path" => %r{/Users/[A-Za-z0-9._-]+},
  "Linux user path" => %r{/home/[A-Za-z0-9._-]+},
  "root home path" => %r{/root(?:/|\b)},
  "Windows user path" => %r{[A-Za-z]:[\\/]+Users[\\/]+[^\\/\s]+},
  "mac temp path" => %r{/var/folders/},
  "file URL" => %r{file://},
  "HTTP credentials" => %r{https?://[^/\s]*@}i,
  "GitHub token" => %r{github_pat_|ghp_|gho_|ghu_|ghs_|ghr_},
  "OpenAI key" => %r{sk-[A-Za-z0-9_-]{20,}},
  "AWS access key" => %r{\b(?:A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}\b},
  "Bearer token" => %r{\bAuthorization:\s*Bearer\s+[A-Za-z0-9._~+\/-]{20,}\b}i,
  "private key" => %r{BEGIN [A-Z ]*PRIVATE KEY}
}.freeze

class Reporter
  attr_reader :errors

  def initialize
    @errors = []
  end

  def error(message)
    @errors << message
  end
end

def load_yaml_file(path, reporter)
  parsed = YAML.safe_load(File.read(path), aliases: false, filename: path)
  parsed.nil? ? {} : parsed
rescue Psych::Exception => error
  reporter.error("#{display_path(path)} is not valid YAML: #{error.message}")
  nil
rescue Errno::ENOENT
  reporter.error("#{display_path(path)} does not exist")
  nil
rescue SystemCallError => error
  reporter.error("#{display_path(path)} could not be read: #{error.message}")
  nil
end

def display_path(path, root: ROOT)
  expanded = File.expand_path(path.to_s)
  root_path = File.expand_path(root.to_s)
  return "." if expanded == root_path
  return "./#{expanded.delete_prefix("#{root_path}/")}" if expanded.start_with?("#{root_path}/")

  path.to_s
end

def contains_control_characters?(value)
  value.is_a?(String) && /[\x00-\x1F\x7F]/.match?(value)
end

def valid_string?(value)
  value.is_a?(String) && !value.strip.empty? && !contains_control_characters?(value)
end

def valid_text_string?(value)
  value.is_a?(String) &&
    !value.strip.empty? &&
    !value.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
end

def normalize_text(value)
  value.to_s.strip.split(/\s+/).join(" ")
end

def safe_relative_path?(value)
  return false unless valid_string?(value)
  return false if value.start_with?("/") || value.include?("\\")

  path = Pathname.new(value)
  return false if path.each_filename.any? { |part| part == ".." }

  path.cleanpath.each_filename.none? { |part| part == ".." }
rescue ArgumentError
  false
end

def top_level_skill_path?(value)
  return false unless safe_relative_path?(value)

  parts = Pathname.new(value).each_filename.to_a
  parts.length == 1 && parts.first == value
rescue ArgumentError
  false
end

def safe_adapter_name?(value)
  return false unless valid_string?(value)
  return false if value.start_with?("/") || value.include?("\\")
  return false if [".", ".."].include?(value)

  path = Pathname.new(value)
  path.cleanpath.to_s == value &&
    path.each_filename.to_a.length == 1 &&
    path.each_filename.first == value
rescue ArgumentError
  false
end

def string_array(value, reporter, label)
  unless value.is_a?(Array)
    reporter.error("#{label} must be an array of strings")
    return []
  end

  value.each_with_index.each_with_object([]) do |(entry, index), memo|
    if valid_string?(entry)
      memo << entry
    else
      reporter.error("#{label}[#{index}] must be a non-empty string without control characters")
    end
  end
end

def string_mapping(value, reporter, label, allow_nil: false)
  return {} if value.nil? && allow_nil
  unless value.is_a?(Hash)
    reporter.error("#{label} must be a mapping")
    return {}
  end

  value.each_with_object({}) do |(key, raw), memo|
    if valid_string?(key) && valid_string?(raw)
      memo[key] = raw
    else
      reporter.error("#{label} entries must be non-empty strings without control characters")
    end
  end.sort.to_h
end

def mapping(value, reporter, label, allow_nil: false)
  return {} if value.nil? && allow_nil
  return value if value.is_a?(Hash)

  reporter.error("#{label} must be a mapping")
  {}
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

  metadata = YAML.safe_load(lines[1, closing].join("\n"), aliases: false, filename: path) || {}
  return metadata if metadata.is_a?(Hash)

  reporter.error("#{display_path(path)} front matter must be a mapping")
  {}
rescue Psych::Exception => error
  reporter.error("#{display_path(path)} front matter is not valid YAML: #{error.message}")
  {}
rescue SystemCallError => error
  reporter.error("#{display_path(path)} could not be read: #{error.message}")
  {}
end

def valid_sha256_hex?(value)
  value.is_a?(String) && /\A[0-9a-f]{64}\z/i.match?(value)
end

def valid_git_object_id?(value)
  value.is_a?(String) && /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i.match?(value) && !value.match?(/\A0+\z/)
end

def index_lock_entries(lock, reporter)
  raw = lock["skills"]
  unless raw.is_a?(Array)
    reporter.error("skills.lock.yaml skills must be an array")
    return {}
  end

  raw.each_with_object({}) do |entry, memo|
    unless entry.is_a?(Hash) && valid_string?(entry["id"])
      reporter.error("skills.lock.yaml entries must include non-empty string id")
      next
    end

    skill_id = entry["id"]
    reporter.error("skills.lock.yaml duplicate lock entry #{skill_id}") if memo.key?(skill_id)
    memo[skill_id] = entry
  end
end

def require_lock_field(lock_entry, skill_id, field, reporter)
  value = lock_entry[field]
  reporter.error("#{skill_id}: lock #{field} is required") unless valid_string?(value)
  value.to_s
end

def compare_lock_field(lock_entry, skill_id, field, expected, reporter)
  actual = lock_entry[field]
  return if actual == expected

  reporter.error("#{skill_id}: lock #{field} differs from registry metadata")
end

def compare_lock_array(lock_entry, skill_id, field, expected, reporter)
  actual = lock_entry[field]
  return if actual == expected

  reporter.error("#{skill_id}: lock #{field} differs from registry metadata")
end

def install_command(manager_source, skill_name)
  [
    "npx --yes #{DEFAULT_SKILLS_CLI_PACKAGE} add #{manager_source}",
    "--skill #{skill_name}",
    "--agent codex",
    "--global",
    "--yes"
  ].join(" ")
end

def catalog_description(skill, metadata)
  catalog = skill["catalog"]
  if catalog.is_a?(Hash) && valid_text_string?(catalog["description"])
    return normalize_text(catalog["description"])
  end

  description = metadata["description"]
  return normalize_text(description) if valid_text_string?(description)

  ""
end

def catalog_name(skill, metadata, exported_names)
  catalog = skill["catalog"]
  if catalog.is_a?(Hash) && valid_string?(catalog["name"])
    return catalog["name"].strip
  end

  name = metadata["name"]
  return name.strip if valid_string?(name)

  exported_names.first || skill["id"]
end

def external_git_url_public?(value)
  return false unless valid_string?(value)
  return false if value.match?(%r{\Afile:}i)
  return false if value.match?(%r{https?://[^/\s]*@}i)
  return false if value.start_with?("/") || value.start_with?("~")

  true
end

def build_catalog(registry, lock, registry_path, lock_path, reporter)
  registry_root = Pathname.new(File.dirname(File.expand_path(registry_path))).cleanpath
  registry_metadata = mapping(registry["registry"], reporter, "registry metadata")
  registry_id = registry_metadata["id"]
  registry_name = registry_metadata["name"]
  registry_status = registry["status"]
  manager_source = registry_metadata["manager_source"]
  raw_skills = registry["skills"]

  reporter.error("registry.id is required") unless valid_string?(registry_id)
  reporter.error("registry.name is required") unless valid_string?(registry_name)
  reporter.error("registry.status is required") unless valid_string?(registry_status)
  reporter.error("registry.manager_source is required for public install commands") unless valid_string?(manager_source)
  unless raw_skills.is_a?(Array)
    reporter.error("skills.registry.yaml skills must be an array")
    raw_skills = []
  end

  lock_by_id = index_lock_entries(lock, reporter)
  catalog_skills = []

  raw_skills.each_with_index do |skill, index|
    unless skill.is_a?(Hash)
      reporter.error("skills[#{index}] must be a mapping")
      next
    end

    skill_id = skill["id"]
    unless valid_string?(skill_id)
      reporter.error("skills[#{index}].id is required")
      next
    end

    status = skill["status"]
    reporter.error("#{skill_id}: status is required") unless valid_string?(status)
    source = mapping(skill["source"], reporter, "#{skill_id}: source")
    source_type = source["type"]
    exported_names = string_array(skill["exported_names"], reporter, "#{skill_id}: exported_names")
    exported_names.each do |name|
      reporter.error("#{skill_id}: exported_names entries must be safe adapter names") unless safe_adapter_name?(name)
    end
    reporter.error("#{skill_id}: exported_names must not be empty") if exported_names.empty?
    clients = string_mapping(skill["clients"], reporter, "#{skill_id}: clients", allow_nil: true)
    scopes = string_array(skill["scopes"], reporter, "#{skill_id}: scopes")
    update_policy = skill["update_policy"]
    reporter.error("#{skill_id}: update_policy is required") unless valid_string?(update_policy)

    lock_entry = lock_by_id[skill_id]
    if lock_entry.nil?
      reporter.error("#{skill_id}: missing lock entry")
      lock_entry = {}
    end
    compare_lock_field(lock_entry, skill_id, "source_type", source_type, reporter)
    compare_lock_array(lock_entry, skill_id, "exported_names", exported_names, reporter)

    metadata = {}
    source_catalog = nil
    lock_catalog = nil

    case source_type
    when "registry-local"
      source_path = source["path"]
      unless top_level_skill_path?(source_path)
        reporter.error("#{skill_id}: registry-local source.path must name a top-level skill directory")
      end

      skill_file = registry_root.join(source_path.to_s, "SKILL.md")
      metadata = frontmatter(skill_file.to_s, reporter)
      digest = require_lock_field(lock_entry, skill_id, "digest_sha256", reporter)
      reporter.error("#{skill_id}: lock digest_sha256 must be a 64-character SHA-256") unless digest.empty? || valid_sha256_hex?(digest)
      compare_lock_field(lock_entry, skill_id, "path", source_path, reporter)
      source_catalog = {
        "type" => "registry-local",
        "path" => source_path
      }
      lock_catalog = {
        "source_type" => "registry-local",
        "path" => lock_entry["path"],
        "digest_sha256" => digest
      }
    when "external-git"
      url = source["url"]
      path = source["path"]
      pinned_tag = source["pinned_tag"]
      observed_commit = source["observed_commit"]
      observed_at = source["observed_at"]

      reporter.error("#{skill_id}: external-git source.url must be a public, credential-free URL") unless external_git_url_public?(url)
      reporter.error("#{skill_id}: external-git source.path must be a safe relative path") unless safe_relative_path?(path)
      reporter.error("#{skill_id}: external-git source.pinned_tag is required") unless valid_string?(pinned_tag)
      reporter.error("#{skill_id}: external-git source.observed_commit must be a full git object id") unless valid_git_object_id?(observed_commit)
      reporter.error("#{skill_id}: external-git source.observed_at is required") unless valid_string?(observed_at)

      %w[url path pinned_tag observed_commit].each do |field|
        require_lock_field(lock_entry, skill_id, field, reporter)
        compare_lock_field(lock_entry, skill_id, field, source[field], reporter)
      end

      source_catalog = {
        "type" => "external-git",
        "url" => url,
        "path" => path,
        "pinned_tag" => pinned_tag,
        "observed_commit" => observed_commit,
        "observed_at" => observed_at
      }
      lock_catalog = {
        "source_type" => "external-git",
        "url" => lock_entry["url"],
        "path" => lock_entry["path"],
        "pinned_tag" => lock_entry["pinned_tag"],
        "observed_commit" => lock_entry["observed_commit"]
      }
    else
      reporter.error("#{skill_id}: source.type must be registry-local or external-git")
    end

    name = catalog_name(skill, metadata, exported_names)
    description = catalog_description(skill, metadata)
    reporter.error("#{skill_id}: catalog description is required") unless valid_string?(description)

    install = nil
    if status == "active" && clients["codex"] == "supported" && valid_string?(manager_source) && safe_adapter_name?(exported_names.first)
      install = {
        "manager_package" => DEFAULT_SKILLS_CLI_PACKAGE,
        "registry_source" => manager_source,
        "skill" => exported_names.first,
        "codex_global_command" => install_command(manager_source, exported_names.first)
      }
    end

    entry = {
      "id" => skill_id,
      "name" => name,
      "description" => description,
      "status" => status,
      "source" => source_catalog,
      "exported_names" => exported_names,
      "clients" => clients,
      "scopes" => scopes,
      "update_policy" => update_policy,
      "lock" => lock_catalog
    }
    entry["install"] = install if install
    catalog_skills << entry
  end

  registry_skill_ids = raw_skills.each_with_object([]) do |entry, memo|
    memo << entry["id"] if entry.is_a?(Hash) && entry["id"].is_a?(String)
  end
  stale_locks = lock_by_id.keys - registry_skill_ids
  stale_locks.sort.each do |skill_id|
    reporter.error("skills.lock.yaml stale lock entry #{skill_id} is not present in skills.registry.yaml")
  end

  catalog = {
    "schema_version" => CATALOG_SCHEMA_VERSION,
    "generated_by" => GENERATOR,
    "registry" => {
      "id" => registry_id,
      "name" => registry_name,
      "status" => registry_status,
      "manager_source" => manager_source,
      "source_files" => [
        Pathname.new(registry_path).relative_path_from(registry_root).to_s,
        Pathname.new(lock_path).relative_path_from(registry_root).to_s
      ]
    },
    "skills" => catalog_skills
  }

  catalog
end

def json_document(catalog)
  "#{JSON.pretty_generate(catalog)}\n"
end

def md_escape(value)
  value.to_s.gsub("|", "\\|").gsub("\n", " ")
end

def code_span(value)
  "`#{md_escape(value)}`"
end

def markdown_document(catalog)
  registry = catalog.fetch("registry")
  skills = catalog.fetch("skills")
  active_installable = skills.select { |skill| skill.key?("install") }
  lines = []

  lines << "# Skills Catalog"
  lines << ""
  lines << "This file is generated. Edit `skills.registry.yaml`, `skills.lock.yaml`,"
  lines << "or registered `SKILL.md` front matter, then run"
  lines << "`scripts/skills_catalog.rb --write`."
  lines << ""
  lines << "- Registry: #{registry.fetch("name")} (#{code_span(registry.fetch("id"))})"
  lines << "- Status: #{code_span(registry.fetch("status"))}"
  lines << "- Manager source: #{code_span(registry.fetch("manager_source"))}"
  lines << "- Covered skills: #{skills.length}"
  lines << ""
  lines << "## Registry-Covered Skills"
  lines << ""
  lines << "| Skill | Status | Source | Exports | Clients | Scopes | Update Policy | Description |"
  lines << "| --- | --- | --- | --- | --- | --- | --- | --- |"

  skills.each do |skill|
    source = skill.fetch("source")
    source_label =
      if source.fetch("type") == "external-git"
        "external-git:#{source.fetch("path")}@#{source.fetch("pinned_tag")}"
      else
        "registry-local:#{source.fetch("path")}"
      end
    clients = skill.fetch("clients").map { |client, status| "#{client}=#{status}" }.join(", ")
    lines << [
      code_span(skill.fetch("id")),
      code_span(skill.fetch("status")),
      code_span(source_label),
      skill.fetch("exported_names").map { |name| code_span(name) }.join(", "),
      md_escape(clients),
      skill.fetch("scopes").map { |scope| code_span(scope) }.join(", "),
      code_span(skill.fetch("update_policy")),
      md_escape(skill.fetch("description"))
    ].join(" | ").prepend("| ") + " |"
  end

  lines << ""
  lines << "## Installable Active Skills"
  lines << ""
  if active_installable.empty?
    lines << "No active Codex-supported skills currently emit public install commands."
  else
    lines << "The commands below use the pinned upstream skills manager package."
    lines << ""
    lines << "```bash"
    active_installable.each do |skill|
      lines << skill.fetch("install").fetch("codex_global_command")
    end
    lines << "```"
  end

  lines << ""
  lines.join("\n")
end

def public_safety_scan(text, label, reporter)
  PUBLIC_UNSAFE_PATTERNS.each do |name, pattern|
    reporter.error("#{label} contains #{name}") if text.match?(pattern)
  end
end

def write_if_changed(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

def check_file(path, expected, reporter)
  actual = File.exist?(path) ? File.read(path) : nil
  return if actual == expected

  reporter.error("#{display_path(path)} catalog drift; run #{GENERATOR} --write")
end

options = {
  registry: ROOT.join("skills.registry.yaml").to_s,
  lock: ROOT.join("skills.lock.yaml").to_s,
  json_output: ROOT.join("skills.catalog.json").to_s,
  markdown_output: ROOT.join("docs/skills-catalog.md").to_s,
  mode: :check
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{GENERATOR} [--check|--write|--json|--markdown]"
  opts.on("--registry PATH", "Registry manifest path") { |value| options[:registry] = value }
  opts.on("--lock PATH", "Lock file path") { |value| options[:lock] = value }
  opts.on("--json-output PATH", "Generated JSON catalog path") { |value| options[:json_output] = value }
  opts.on("--markdown-output PATH", "Generated Markdown catalog path") { |value| options[:markdown_output] = value }
  opts.on("--check", "Verify checked-in generated catalog artifacts") { options[:mode] = :check }
  opts.on("--write", "Write generated catalog artifacts") { options[:mode] = :write }
  opts.on("--json", "Print generated JSON catalog") { options[:mode] = :json }
  opts.on("--markdown", "Print generated Markdown catalog") { options[:mode] = :markdown }
end

parser.parse!

reporter = Reporter.new
registry = load_yaml_file(options[:registry], reporter)
lock = load_yaml_file(options[:lock], reporter)
catalog = build_catalog(registry || {}, lock || {}, options[:registry], options[:lock], reporter)

unless reporter.errors.empty?
  warn reporter.errors.join("\n")
  exit 1
end

json = json_document(catalog)
markdown = markdown_document(catalog)
public_safety_scan(json, "generated catalog JSON", reporter)
public_safety_scan(markdown, "generated catalog Markdown", reporter)

unless reporter.errors.empty?
  warn reporter.errors.join("\n")
  exit 1
end

case options[:mode]
when :check
  check_file(options[:json_output], json, reporter)
  check_file(options[:markdown_output], markdown, reporter)
when :write
  write_if_changed(options[:json_output], json)
  write_if_changed(options[:markdown_output], markdown)
when :json
  print json
when :markdown
  print markdown
end

unless reporter.errors.empty?
  warn reporter.errors.join("\n")
  exit 1
end
