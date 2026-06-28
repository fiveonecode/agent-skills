#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "find"
require "optparse"
require "open3"
require "pathname"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze

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
    return if @quiet

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
  reporter.error("#{display_path(path)} could not be read: #{error.message}")
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

def expand_config_path(path, base_dir: ROOT)
  value = path.to_s
  return File.expand_path(value.delete_prefix("~/"), Dir.home) if value.start_with?("~/")

  File.expand_path(value, base_dir)
end

def safe_relative_path?(path)
  value = path.to_s
  return false if value.empty?
  return false if value.start_with?("/")

  Pathname.new(value).cleanpath.each_filename.none? { |part| part == ".." }
rescue ArgumentError
  false
end

def safe_adapter_name?(name)
  value = name.to_s
  return false if value.empty?
  return false if value.start_with?("/")

  parts = Pathname.new(value).cleanpath.each_filename.to_a
  parts.length == 1 && parts.none? { |part| part.empty? || part == "." || part == ".." }
rescue ArgumentError
  false
end

def path_within?(path, root)
  path_value = Pathname.new(path).to_s
  root_value = Pathname.new(root).to_s
  path_value == root_value || path_value.start_with?("#{root_value}/")
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
  reporter.error("#{display_path(dir)} could not be hashed cleanly: #{error.message}")
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
  reporter.error("#{display_path(path)} could not be read: #{error.message}")
  {}
end

def git_status_entries(root)
  stdout, _stderr, status = Open3.capture3("git", "-C", root.to_s, "status", "--porcelain")
  return [] unless status.success?

  stdout.lines.map(&:chomp).reject(&:empty?)
end

def git_path_status_entries(root, pathspec)
  stdout, _stderr, status = Open3.capture3(
    "git",
    "-C",
    root.to_s,
    "status",
    "--porcelain",
    "--ignored=matching",
    "--untracked-files=all",
    "--",
    pathspec.to_s
  )
  return [] unless status.success?

  stdout.lines.map(&:chomp).reject(&:empty?)
end

def git_ls_remote_tag(url, tag)
  stdout, stderr, status = Open3.capture3(
    "git",
    "ls-remote",
    "--tags",
    url.to_s,
    "refs/tags/#{tag}",
    "refs/tags/#{tag}^{}"
  )
  [stdout.lines.map { |line| line.split(/\s+/, 2).first }.compact, stderr, status]
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
    consumer_name = consumer.to_s
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

  reporter.error("registry.id is required") if id.to_s.empty?
  reporter.error("registry.name is required") if name.to_s.empty?
  reporter.error("skills must be a non-empty array") unless raw_skills.is_a?(Array) && !raw_skills.empty?

  ids = {}
  resolved = {}
  exported_name_owners = {}

  skills.each do |skill|
    unless skill["id"].is_a?(String)
      reporter.error("skill entry id must be a string")
      next
    end

    skill_id = skill["id"].to_s
    source = skill["source"] || {}
    exported_names = string_array(skill["exported_names"], reporter, "#{skill_id}: exported_names")

    if skill_id.empty?
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
      if exported_name.empty?
        reporter.error("#{skill_id}: exported_names entries must not be empty")
        next
      end

      unless safe_adapter_name?(exported_name)
        reporter.error("#{skill_id}: exported_name #{exported_name} must be a safe adapter directory name")
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
        unreviewed = git_path_status_entries(registry_root, source_path)
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
      name = metadata["name"].to_s
      description = metadata["description"].to_s
      reporter.error("#{skill_id}: SKILL.md front matter name is required") if name.empty?
      reporter.error("#{skill_id}: SKILL.md front matter description is required") if description.empty?
      reporter.warn("#{skill_id}: exported_names does not include SKILL.md name #{name}") if !name.empty? && !exported_names.include?(name)

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
      next if invalid_source_field

      url = source["url"].to_s
      source_path = source["path"].to_s
      tag = source["pinned_tag"].to_s
      observed_commit = source["observed_commit"].to_s
      reporter.error("#{skill_id}: external-git source.url is required") if url.empty?
      reporter.warn("#{skill_id}: external-git source.path is missing; assuming repository root") if source_path.empty?
      if !source_path.empty? && !safe_relative_path?(source_path)
        reporter.error("#{skill_id}: external-git source.path must be a safe relative path")
        next
      end
      reporter.error("#{skill_id}: external-git pinned_tag is required") if tag.empty?
      reporter.warn("#{skill_id}: external-git observed_commit is missing") if observed_commit.empty?

      if options[:check_upstream] && !url.empty? && !tag.empty?
        hashes, stderr, status = git_ls_remote_tag(url, tag)
        if status.success? && hashes.any?
          if !observed_commit.empty? && !hashes.include?(observed_commit)
            reporter.warn("#{skill_id}: pinned tag #{tag} no longer resolves to observed_commit #{observed_commit[0, 12]}")
          else
            reporter.ok("#{skill_id}: upstream tag #{tag} resolves to #{hashes.first[0, 12]}")
          end
        else
          reporter.warn("#{skill_id}: could not resolve upstream tag #{tag}: #{stderr.strip}")
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
    status_entries = git_status_entries(registry_root)
    if status_entries.empty?
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

def validate_lock(lock_path, registry_root, resolved, reporter)
  path = Pathname.new(File.expand_path(lock_path, registry_root)).cleanpath
  lock_label = display_path(path)
  unless path.file?
    reporter.warn("#{lock_label} is missing; run with --print-lock to create a reviewed lock candidate")
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
  locked_by_id = entries.each_with_object({}) do |entry, memo|
    skill_id = entry["id"].to_s
    if skill_id.empty?
      reporter.error("#{lock_label}: lock entries must include non-empty id")
      next
    end

    if memo.key?(skill_id)
      reporter.error("#{lock_label}: duplicate lock entry id #{skill_id}")
      next
    end

    memo[skill_id] = entry
  end
  (locked_by_id.keys - resolved.keys).sort.each do |skill_id|
    reporter.warn("#{lock_label}: stale lock entry #{skill_id} is not present in the registry")
  end

  resolved.each do |skill_id, entry|
    locked = locked_by_id[skill_id]
    if locked.nil?
      reporter.warn("#{lock_label}: missing lock entry for #{skill_id}")
      next
    end

    unless locked["exported_names"].is_a?(Array) && locked["exported_names"].all? { |name| name.is_a?(String) }
      reporter.error("#{lock_label}: #{skill_id} lock exported_names must be an array of strings")
      next
    end

    case entry["source_type"]
    when "registry-local"
      next unless validate_lock_scalar_fields(locked, %w[source_type path digest_sha256], lock_label, skill_id, reporter)

      mismatches = lock_field_mismatches(locked, entry, %w[source_type path digest_sha256 exported_names])
      if mismatches.empty?
        reporter.ok("#{lock_label}: #{skill_id} digest matches")
      else
        reporter.warn("#{lock_label}: #{skill_id} differs from current source fields: #{mismatches.join(", ")}")
      end
    when "external-git"
      next unless validate_lock_scalar_fields(locked, %w[source_type url path pinned_tag observed_commit], lock_label, skill_id, reporter)

      mismatches = lock_field_mismatches(locked, entry, %w[source_type url path pinned_tag observed_commit exported_names])
      if mismatches.empty?
        reporter.ok("#{lock_label}: #{skill_id} external pin matches")
      else
        reporter.warn("#{lock_label}: #{skill_id} differs from registry fields: #{mismatches.join(", ")}")
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
    id = profile_metadata["id"].to_s
    consumer_roots = profile["consumer_roots"]
    normalized_consumer_roots = normalize_consumer_roots(consumer_roots, reporter, "#{display_path(expanded)}")
    selected_skills = mapping_array(profile["selected_skills"], reporter, "#{display_path(expanded)} selected_skills", allow_nil: true)

    reporter.error("#{display_path(expanded)} profile.id is required") if id.empty?
    reporter.error("#{display_path(expanded)} consumer_roots must be a mapping") unless consumer_roots.is_a?(Hash)

    root_keys = normalized_consumer_roots.keys
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

        consumer_path = normalized_consumer_roots[consumer]["path"]
        unless consumer_path.is_a?(String) && !consumer_path.empty?
          reporter.error("#{display_path(expanded)} consumer_roots.#{consumer} path must be a non-empty string")
        end
      end

      selection["expose_to"] = expose_to
    end

    reporter.ok("#{id.empty? ? display_path(expanded) : id}: #{selected_skills.length} selected skills, #{root_keys.length} consumer roots")
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
          reporter.info("#{consumer}: #{display_path(expanded_root)} is missing")
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

def repo_skill_entrypoints(projects_root)
  return [] unless File.directory?(projects_root)

  scan_root = File.realpath(projects_root)
  stdout, _stderr, status = Open3.capture3(
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
  return [] unless status.success?

  stdout.lines.map(&:chomp).select do |entry|
    parts = entry.split(File::SEPARATOR)
    skill_index = parts.rindex("skills")
    agents_index = skill_index && skill_index - 1
    skill_index && agents_index && parts[agents_index] == ".agents" && parts.length == skill_index + 3
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
  repo_skill_entrypoints(projects_root).each do |file|
    name = file.split("/.agents/skills/", 2).last.split("/", 2).first
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
  print_lock: false
}

parser = OptionParser.new do |opts|
  opts.banner = "usage: scripts/skills_doctor.rb [options]"
  opts.on("--registry PATH", "Registry manifest path") { |value| options[:registry] = value }
  opts.on("--profile PATH", "Profile path; can be repeated") { |value| options[:profiles] << value }
  opts.on("--projects-root PATH", "Projects root for repo-local duplicate scan") { |value| options[:projects_root] = value }
  opts.on("--lock PATH", "Lock file to validate if present") { |value| options[:lock] = value }
  opts.on("--check-upstream", "Resolve external git tags") { options[:check_upstream] = true }
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
