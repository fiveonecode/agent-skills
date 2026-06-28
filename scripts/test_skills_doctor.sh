#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
real_git="$(command -v git)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  printf '%s\n' "$haystack" | grep -F -q -- "$needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if printf '%s\n' "$haystack" | grep -F -q -- "$needle"; then
    echo "unexpected output: $needle" >&2
    exit 1
  fi
}

expect_failure() {
  local output
  if output="$("$@" 2>&1)"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi

  printf '%s' "$output"
}

basic_dir="$tmp_dir/basic"
mkdir -p "$basic_dir/example-skill" "$basic_dir/profiles/machine"

cat >"$basic_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$basic_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: fixture-skills
  name: Fixture Skills
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$basic_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: fixture-profile
consumer_roots:
  fixture_user:
    path: ./missing-consumer-root
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
    state: active
YAML

basic_output="$(
  PROJECTS_ROOT="$basic_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$basic_dir/skills.registry.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml" \
    --projects-root "$basic_dir/projects"
)"

assert_contains "$basic_output" "fixture-profile: 1 selected skills, 1 consumer roots"
assert_contains "$basic_output" "example-skill: registry-local example-skill digest"

lock_output="$(
  ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$basic_dir/skills.registry.yaml" \
    --print-lock
)"

assert_contains "$lock_output" "generated_by: scripts/skills_doctor.rb --print-lock"
assert_contains "$lock_output" "digest_sha256:"

alt_dir="$tmp_dir/alternate"
mkdir -p "$alt_dir/alt-skill" "$alt_dir/profiles/machine/consumer-root"
ln -s "$alt_dir/alt-skill" "$alt_dir/profiles/machine/consumer-root/alt-adapter"

cat >"$alt_dir/alt-skill/SKILL.md" <<'SKILL'
---
name: alt-adapter
description: Alternate fixture skill.
---

# Alternate Skill
SKILL

cat >"$alt_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: alternate-skills
  name: Alternate Skills
skills:
  - id: alt-skill
    status: active
    source:
      type: registry-local
      path: alt-skill
    exported_names:
      - alt-adapter
YAML

cat >"$alt_dir/profiles/machine/default.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: alt-profile
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: alt-skill
    expose_to:
      - fixture_user
    state: active
YAML

alt_output="$(
  PROJECTS_ROOT="$alt_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$alt_dir/skills.registry.yaml" \
    --projects-root "$alt_dir/projects"
)"

assert_contains "$alt_output" "alt-profile: 1 selected skills, 1 consumer roots"
assert_contains "$alt_output" "fixture_user: alt-adapter symlink points at registry source"
assert_not_contains "$alt_output" "is not in registry"

bad_source_dir="$tmp_dir/bad-source"
mkdir -p "$bad_source_dir"

cat >"$bad_source_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-source
  name: Bad Source
skills:
  - id: broken-skill
    status: active
    source: []
    exported_names:
      - broken-skill
YAML

bad_source_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_source_dir/skills.registry.yaml" --projects-root "$bad_source_dir/projects")"
assert_contains "$bad_source_output" "broken-skill: source must be a mapping"
assert_not_contains "$bad_source_output" "TypeError"

bad_registry_path="$tmp_dir/not-a-map.yaml"
printf '[]\n' >"$bad_registry_path"

bad_registry_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_registry_path" --print-lock)"
assert_contains "$bad_registry_output" "must contain a top-level mapping"
assert_not_contains "$bad_registry_output" "schema_version:"

lock_dir="$tmp_dir/lock-check"
mkdir -p "$lock_dir/lock-skill"

cat >"$lock_dir/lock-skill/SKILL.md" <<'SKILL'
---
name: lock-adapter
description: Lock fixture skill.
---

# Lock Skill
SKILL

cat >"$lock_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: lock-check
  name: Lock Check
skills:
  - id: lock-skill
    status: active
    source:
      type: registry-local
      path: lock-skill
    exported_names:
      - lock-adapter
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$lock_dir/skills.registry.yaml" --print-lock >"$lock_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["path"] = "renamed-skill"
  lock["skills"][0]["exported_names"] = ["other-adapter"]
  lock["skills"][0]["source_type"] = "external-git"
  lock["skills"] << {
    "id" => "stale-skill",
    "source_type" => "registry-local",
    "path" => ["stale-skill"],
    "digest_sha256" => "deadbeef",
    "exported_names" => "stale-skill"
  }
  File.write(ARGV[1], lock.to_yaml)
' "$lock_dir/good.lock.yaml" "$lock_dir/bad.lock.yaml"

lock_check_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$lock_dir/skills.registry.yaml" --lock "$lock_dir/bad.lock.yaml" --projects-root "$lock_dir/projects")"

assert_contains "$lock_check_output" "stale lock entry stale-skill is not present in the registry"
assert_contains "$lock_check_output" "stale-skill lock exported_names must be an array of strings"
assert_contains "$lock_check_output" "lock-skill lock url must be a string"

bad_lock_digest_dir="$tmp_dir/bad-lock-digest"
mkdir -p "$bad_lock_digest_dir/example-skill"

cat >"$bad_lock_digest_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Bad lock digest fixture.
---

# Example Skill
SKILL

cat >"$bad_lock_digest_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-digest
  name: Bad Lock Digest
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_digest_dir/skills.registry.yaml" --print-lock >"$bad_lock_digest_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["digest_sha256"] = "bad"
  File.write(ARGV[1], lock.to_yaml)
' "$bad_lock_digest_dir/good.lock.yaml" "$bad_lock_digest_dir/bad.lock.yaml"

bad_lock_digest_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_digest_dir/skills.registry.yaml" --lock "$bad_lock_digest_dir/bad.lock.yaml" --projects-root "$bad_lock_digest_dir/projects")"
assert_contains "$bad_lock_digest_output" "example-skill lock digest_sha256 must be a 64-character hex SHA-256"

duplicate_dir="$tmp_dir/duplicates"
mkdir -p "$duplicate_dir/source-skill" "$duplicate_dir/projects/app/.agents/skills/adapter-alias"

cat >"$duplicate_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate fixture skill.
---

# Duplicate Skill
SKILL

cat >"$duplicate_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-check
  name: Duplicate Check
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$duplicate_dir/projects/app/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Repo-local duplicate.
---

# Repo-local Duplicate
SKILL

duplicate_output="$(
  PROJECTS_ROOT="$duplicate_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_dir/skills.registry.yaml" \
    --projects-root "$duplicate_dir/projects"
)"

assert_contains "$duplicate_output" "source-skill: 1 repo-local copies found"

registry_meta_dir="$tmp_dir/registry-meta"
mkdir -p "$registry_meta_dir/example-skill"

cat >"$registry_meta_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$registry_meta_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry: []
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

registry_meta_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$registry_meta_dir/skills.registry.yaml" --print-lock)"
assert_contains "$registry_meta_output" "registry metadata must be a mapping"
assert_not_contains "$registry_meta_output" "TypeError"

bad_skill_entry_dir="$tmp_dir/bad-skill-entry"
mkdir -p "$bad_skill_entry_dir/example-skill"

cat >"$bad_skill_entry_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$bad_skill_entry_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-skill-entry
  name: Bad Skill Entry
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
  - bad-entry
YAML

bad_skill_entry_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_skill_entry_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_skill_entry_output" "skills[1] must be a mapping"

bad_frontmatter_dir="$tmp_dir/bad-frontmatter"
mkdir -p "$bad_frontmatter_dir/bad-skill"

cat >"$bad_frontmatter_dir/bad-skill/SKILL.md" <<'SKILL'
---
[]
---

# Bad Skill
SKILL

cat >"$bad_frontmatter_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-frontmatter
  name: Bad Frontmatter
skills:
  - id: bad-skill
    status: active
    source:
      type: registry-local
      path: bad-skill
    exported_names:
      - bad-skill
YAML

bad_frontmatter_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_frontmatter_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_frontmatter_output" "front matter must be a mapping"
assert_not_contains "$bad_frontmatter_output" "TypeError"

profile_meta_dir="$tmp_dir/profile-meta"
mkdir -p "$profile_meta_dir/example-skill" "$profile_meta_dir/profiles/machine"

cat >"$profile_meta_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$profile_meta_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: profile-meta
  name: Profile Meta
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$profile_meta_dir/profiles/machine/bad-profile.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile: []
consumer_roots:
  fixture_user:
    path: ./missing-consumer-root
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

profile_meta_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$profile_meta_dir/skills.registry.yaml" --profile "$profile_meta_dir/profiles/machine/bad-profile.yaml" --projects-root "$profile_meta_dir/projects")"
assert_contains "$profile_meta_output" "profile must be a mapping"
assert_not_contains "$profile_meta_output" "TypeError"

consumer_roots_dir="$tmp_dir/bad-consumer-roots"
mkdir -p "$consumer_roots_dir/example-skill" "$consumer_roots_dir/profiles/machine"

cat >"$consumer_roots_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$consumer_roots_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-consumer-roots
  name: Bad Consumer Roots
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$consumer_roots_dir/profiles/machine/bad-consumer-roots.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-consumer-roots
consumer_roots: []
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

consumer_roots_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$consumer_roots_dir/skills.registry.yaml" --profile "$consumer_roots_dir/profiles/machine/bad-consumer-roots.yaml" --projects-root "$consumer_roots_dir/projects")"
assert_contains "$consumer_roots_output" "consumer_roots must be a mapping"
assert_not_contains "$consumer_roots_output" "TypeError"

selected_skills_dir="$tmp_dir/bad-selected-skills"
mkdir -p "$selected_skills_dir/example-skill" "$selected_skills_dir/profiles/machine"

cat >"$selected_skills_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$selected_skills_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-selected-skills
  name: Bad Selected Skills
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$selected_skills_dir/profiles/machine/bad-selected-skills.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-selected-skills
consumer_roots:
  fixture_user:
    path: ./missing-consumer-root
selected_skills:
  - bad-entry
YAML

selected_skills_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$selected_skills_dir/skills.registry.yaml" --profile "$selected_skills_dir/profiles/machine/bad-selected-skills.yaml" --projects-root "$selected_skills_dir/projects")"
assert_contains "$selected_skills_output" "selected_skills[0] must be a mapping"
assert_not_contains "$selected_skills_output" "TypeError"

bad_profile_doc_dir="$tmp_dir/bad-profile-doc"
mkdir -p "$bad_profile_doc_dir/example-skill" "$bad_profile_doc_dir/profiles/machine"

cat >"$bad_profile_doc_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$bad_profile_doc_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-profile-doc
  name: Bad Profile Doc
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

printf '[]\n' >"$bad_profile_doc_dir/profiles/machine/bad-profile.yaml"

bad_profile_doc_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_profile_doc_dir/skills.registry.yaml" --profile "$bad_profile_doc_dir/profiles/machine/bad-profile.yaml" --projects-root "$bad_profile_doc_dir/projects")"
assert_contains "$bad_profile_doc_output" "must contain a top-level mapping"

bad_lock_doc_dir="$tmp_dir/bad-lock-doc"
mkdir -p "$bad_lock_doc_dir/example-skill"

cat >"$bad_lock_doc_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$bad_lock_doc_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-doc
  name: Bad Lock Doc
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

printf '[]\n' >"$bad_lock_doc_dir/bad.lock.yaml"

bad_lock_doc_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_doc_dir/skills.registry.yaml" --lock "$bad_lock_doc_dir/bad.lock.yaml" --projects-root "$bad_lock_doc_dir/projects")"
assert_contains "$bad_lock_doc_output" "must contain a top-level mapping"
assert_not_contains "$bad_lock_doc_output" "skills doctor passed"

bad_lock_skills_dir="$tmp_dir/bad-lock-skills"
mkdir -p "$bad_lock_skills_dir/example-skill"

cat >"$bad_lock_skills_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$bad_lock_skills_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-skills
  name: Bad Lock Skills
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$bad_lock_skills_dir/bad.lock.yaml" <<'YAML'
schema_version: 0.1
skills: bad
YAML

bad_lock_skills_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_skills_dir/skills.registry.yaml" --lock "$bad_lock_skills_dir/bad.lock.yaml" --projects-root "$bad_lock_skills_dir/projects")"
assert_contains "$bad_lock_skills_output" "skills must be an array"

duplicate_export_dir="$tmp_dir/duplicate-export"
mkdir -p "$duplicate_export_dir/skill-a" "$duplicate_export_dir/skill-b"

cat >"$duplicate_export_dir/skill-a/SKILL.md" <<'SKILL'
---
name: shared-adapter
description: Skill A.
---

# Skill A
SKILL

cat >"$duplicate_export_dir/skill-b/SKILL.md" <<'SKILL'
---
name: shared-adapter
description: Skill B.
---

# Skill B
SKILL

cat >"$duplicate_export_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-export
  name: Duplicate Export
skills:
  - id: skill-a
    status: active
    source:
      type: registry-local
      path: skill-a
    exported_names:
      - shared-adapter
  - id: skill-b
    status: active
    source:
      type: registry-local
      path: skill-b
    exported_names:
      - shared-adapter
YAML

duplicate_export_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$duplicate_export_dir/skills.registry.yaml" --print-lock)"
assert_contains "$duplicate_export_output" "skill-b: exported_name shared-adapter already belongs to skill-a"

bad_exported_names_dir="$tmp_dir/bad-exported-names"
mkdir -p "$bad_exported_names_dir/bad-exported"

cat >"$bad_exported_names_dir/bad-exported/SKILL.md" <<'SKILL'
---
name: bad-exported
description: Bad exported_names fixture.
---

# Bad Exported Names
SKILL

cat >"$bad_exported_names_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-exported-names
  name: Bad Exported Names
skills:
  - id: bad-exported
    status: active
    source:
      type: registry-local
      path: bad-exported
    exported_names:
      bad: entry
YAML

bad_exported_names_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_exported_names_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_exported_names_output" "bad-exported: exported_names must be an array of strings"

control_char_exported_name_dir="$tmp_dir/control-char-exported-name"
mkdir -p "$control_char_exported_name_dir/example-skill"

cat >"$control_char_exported_name_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Control-char exported_names fixture.
---

# Control Char Exported Name
SKILL

cat >"$control_char_exported_name_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: control-char-exported-name
  name: Control Char Exported Name
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - "bad\nname"
YAML

control_char_exported_name_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$control_char_exported_name_dir/skills.registry.yaml" --print-lock)"
assert_contains "$control_char_exported_name_output" 'example-skill: exported_name "bad\nname" must be a safe adapter directory name'
assert_not_contains "$control_char_exported_name_output" "generated_by: scripts/skills_doctor.rb --print-lock"

bad_external_git_dir="$tmp_dir/bad-external-git"
mkdir -p "$bad_external_git_dir"

cat >"$bad_external_git_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-external-git
  name: Bad External Git
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://github.com/twostraws/SwiftUI-Agent-Skill.git
      path: ../../outside
      pinned_tag: 1.1.0
      observed_commit: be297ff80dddec529af1f9b1f1f114aab6c9d11c
    exported_names:
      - swiftui-pro
YAML

bad_external_git_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_external_git_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_external_git_output" "swiftui-pro: external-git source.path must be a safe relative path"

symlink_source_dir="$tmp_dir/symlink-source"
mkdir -p "$symlink_source_dir/real-skill"
ln -s "$symlink_source_dir/real-skill" "$symlink_source_dir/linked-skill"

cat >"$symlink_source_dir/real-skill/SKILL.md" <<'SKILL'
---
name: symlinked-skill
description: Symlinked skill fixture.
---

# Symlinked Skill
SKILL

cat >"$symlink_source_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-source
  name: Symlink Source
skills:
  - id: symlinked-skill
    status: active
    source:
      type: registry-local
      path: linked-skill
    exported_names:
      - symlinked-skill
YAML

symlink_source_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$symlink_source_dir/skills.registry.yaml" --print-lock)"
assert_contains "$symlink_source_output" "symlinked-skill: registry-local source.path must not be a symlink"

bad_root_config_dir="$tmp_dir/bad-root-config"
mkdir -p "$bad_root_config_dir/example-skill" "$bad_root_config_dir/profiles/machine"

cat >"$bad_root_config_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$bad_root_config_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-root-config
  name: Bad Root Config
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$bad_root_config_dir/profiles/machine/bad-root-config.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-root-config
consumer_roots:
  fixture_user: []
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

bad_root_config_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_root_config_dir/skills.registry.yaml" --profile "$bad_root_config_dir/profiles/machine/bad-root-config.yaml" --projects-root "$bad_root_config_dir/projects")"
assert_contains "$bad_root_config_output" "consumer_roots.fixture_user must be a mapping"
assert_not_contains "$bad_root_config_output" "TypeError"

bad_exported_path_dir="$tmp_dir/bad-exported-path"
mkdir -p "$bad_exported_path_dir/example-skill"

cat >"$bad_exported_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$bad_exported_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-exported-path
  name: Bad Exported Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - ../outside
      - nested/name
YAML

bad_exported_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_exported_path_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_exported_path_output" "example-skill: exported_name ../outside must be a safe adapter directory name"
assert_contains "$bad_exported_path_output" "example-skill: exported_name nested/name must be a safe adapter directory name"

duplicate_lock_id_dir="$tmp_dir/duplicate-lock-id"
mkdir -p "$duplicate_lock_id_dir/example-skill"

cat >"$duplicate_lock_id_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$duplicate_lock_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-lock-id
  name: Duplicate Lock Id
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$duplicate_lock_id_dir/skills.registry.yaml" --print-lock >"$duplicate_lock_id_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  duplicate = lock["skills"][0].dup
  duplicate["digest_sha256"] = "deadbeef"
  duplicate["exported_names"] = Array(duplicate["exported_names"]).dup
  lock["skills"].unshift(duplicate)
  File.write(ARGV[1], lock.to_yaml)
' "$duplicate_lock_id_dir/good.lock.yaml" "$duplicate_lock_id_dir/bad.lock.yaml"

duplicate_lock_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$duplicate_lock_id_dir/skills.registry.yaml" --lock "$duplicate_lock_id_dir/bad.lock.yaml" --projects-root "$duplicate_lock_id_dir/projects")"
assert_contains "$duplicate_lock_id_output" "duplicate lock entry id example-skill"

relative_registry_dir="$tmp_dir/relative-registry"
mkdir -p "$relative_registry_dir/relative-skill"

cat >"$relative_registry_dir/relative-skill/SKILL.md" <<'SKILL'
---
name: relative-skill
description: Relative registry fixture.
---

# Relative Registry Skill
SKILL

cat >"$relative_registry_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: relative-registry
  name: Relative Registry
skills:
  - id: relative-skill
    status: active
    source:
      type: registry-local
      path: relative-skill
    exported_names:
      - relative-skill
YAML

relative_registry_output="$(
  cd "$relative_registry_dir"
  ruby "$repo_root/scripts/skills_doctor.rb" --registry skills.registry.yaml --print-lock
)"
assert_contains "$relative_registry_output" "id: relative-skill"
assert_not_contains "$relative_registry_output" "id: harness-engineering"

relative_profile_dir="$tmp_dir/relative-profile"
mkdir -p "$relative_profile_dir/relative-skill" "$relative_profile_dir/profiles/machine"

cat >"$relative_profile_dir/relative-skill/SKILL.md" <<'SKILL'
---
name: relative-skill
description: Relative profile fixture.
---

# Relative Profile Skill
SKILL

cat >"$relative_profile_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: relative-profile
  name: Relative Profile
skills:
  - id: relative-skill
    status: active
    source:
      type: registry-local
      path: relative-skill
    exported_names:
      - relative-skill
YAML

cat >"$relative_profile_dir/profiles/machine/relative.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: relative-profile-fixture
consumer_roots:
  fixture_user:
    path: ./missing-consumer-root
selected_skills:
  - skill_id: relative-skill
    expose_to:
      - fixture_user
YAML

relative_profile_output="$(
  cd "$relative_profile_dir"
  ruby "$repo_root/scripts/skills_doctor.rb" --registry skills.registry.yaml --profile profiles/machine/relative.yaml --projects-root "$relative_profile_dir/projects"
)"
assert_contains "$relative_profile_output" "relative-profile-fixture: 1 selected skills, 1 consumer roots"
assert_not_contains "$relative_profile_output" "example-local-agent-skills"

symlink_parent_dir="$tmp_dir/symlink-parent"
mkdir -p "$symlink_parent_dir/outside-skill"
mkdir -p "$symlink_parent_dir/registry"
ln -s "$symlink_parent_dir" "$symlink_parent_dir/registry/link"

cat >"$symlink_parent_dir/outside-skill/SKILL.md" <<'SKILL'
---
name: outside-skill
description: Symlink parent fixture.
---

# Outside Skill
SKILL

cat >"$symlink_parent_dir/registry/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-parent
  name: Symlink Parent
skills:
  - id: outside-skill
    status: active
    source:
      type: registry-local
      path: link/outside-skill
    exported_names:
      - outside-skill
YAML

symlink_parent_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$symlink_parent_dir/registry/skills.registry.yaml" --print-lock)"
assert_contains "$symlink_parent_output" "outside-skill: registry-local source.path must name a top-level skill directory"

missing_lock_id_dir="$tmp_dir/missing-lock-id"
mkdir -p "$missing_lock_id_dir/example-skill"

cat >"$missing_lock_id_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Missing lock id fixture.
---

# Example Skill
SKILL

cat >"$missing_lock_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-lock-id
  name: Missing Lock Id
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$missing_lock_id_dir/skills.registry.yaml" --print-lock >"$missing_lock_id_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0].delete("id")
  File.write(ARGV[1], lock.to_yaml)
' "$missing_lock_id_dir/good.lock.yaml" "$missing_lock_id_dir/bad.lock.yaml"

missing_lock_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$missing_lock_id_dir/skills.registry.yaml" --lock "$missing_lock_id_dir/bad.lock.yaml" --projects-root "$missing_lock_id_dir/projects")"
assert_contains "$missing_lock_id_output" "lock entries must include non-empty string id"

locked_exported_names_dir="$tmp_dir/locked-exported-names"
mkdir -p "$locked_exported_names_dir/example-skill"

cat >"$locked_exported_names_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Locked exported_names fixture.
---

# Example Skill
SKILL

cat >"$locked_exported_names_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: locked-exported-names
  name: Locked Exported Names
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$locked_exported_names_dir/skills.registry.yaml" --print-lock >"$locked_exported_names_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["exported_names"] = "example-skill"
  File.write(ARGV[1], lock.to_yaml)
' "$locked_exported_names_dir/good.lock.yaml" "$locked_exported_names_dir/bad.lock.yaml"

locked_exported_names_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$locked_exported_names_dir/skills.registry.yaml" --lock "$locked_exported_names_dir/bad.lock.yaml" --projects-root "$locked_exported_names_dir/projects")"
assert_contains "$locked_exported_names_output" "example-skill lock exported_names must be an array of strings"

unsafe_locked_exported_names_dir="$tmp_dir/unsafe-locked-exported-names"
mkdir -p "$unsafe_locked_exported_names_dir/example-skill"

cat >"$unsafe_locked_exported_names_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Unsafe locked exported_names fixture.
---

# Example Skill
SKILL

cat >"$unsafe_locked_exported_names_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-locked-exported-names
  name: Unsafe Locked Exported Names
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_locked_exported_names_dir/skills.registry.yaml" --print-lock >"$unsafe_locked_exported_names_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["exported_names"] = ["../outside"]
  File.write(ARGV[1], lock.to_yaml)
' "$unsafe_locked_exported_names_dir/good.lock.yaml" "$unsafe_locked_exported_names_dir/bad.lock.yaml"

unsafe_locked_exported_names_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_locked_exported_names_dir/skills.registry.yaml" --lock "$unsafe_locked_exported_names_dir/bad.lock.yaml" --projects-root "$unsafe_locked_exported_names_dir/projects")"
assert_contains "$unsafe_locked_exported_names_output" "example-skill lock exported_names entries must be safe adapter directory names"

control_char_locked_exported_names_dir="$tmp_dir/control-char-locked-exported-names"
mkdir -p "$control_char_locked_exported_names_dir/example-skill"

cat >"$control_char_locked_exported_names_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Control-char locked exported_names fixture.
---

# Example Skill
SKILL

cat >"$control_char_locked_exported_names_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: control-char-locked-exported-names
  name: Control Char Locked Exported Names
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$control_char_locked_exported_names_dir/skills.registry.yaml" --print-lock >"$control_char_locked_exported_names_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["exported_names"] = ["bad\nname"]
  File.write(ARGV[1], lock.to_yaml)
' "$control_char_locked_exported_names_dir/good.lock.yaml" "$control_char_locked_exported_names_dir/bad.lock.yaml"

control_char_locked_exported_names_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$control_char_locked_exported_names_dir/skills.registry.yaml" --lock "$control_char_locked_exported_names_dir/bad.lock.yaml" --projects-root "$control_char_locked_exported_names_dir/projects")"
assert_contains "$control_char_locked_exported_names_output" "example-skill lock exported_names entries must be safe adapter directory names"

directory_input_dir="$tmp_dir/directory-input"
mkdir -p "$directory_input_dir"
directory_input_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$directory_input_dir" --print-lock)"
assert_contains "$directory_input_output" "could not be read"
assert_not_contains "$directory_input_output" "$directory_input_dir"
assert_not_contains "$directory_input_output" "Traceback"

deep_duplicate_dir="$tmp_dir/deep-duplicates"
mkdir -p "$deep_duplicate_dir/source-skill" "$deep_duplicate_dir/projects/github.com/org/repo/.agents/skills/adapter-alias"

cat >"$deep_duplicate_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Deep duplicate fixture.
---

# Deep Duplicate Skill
SKILL

cat >"$deep_duplicate_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: deep-duplicates
  name: Deep Duplicates
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$deep_duplicate_dir/projects/github.com/org/repo/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Deep repo-local duplicate.
---

# Deep Repo-local Duplicate
SKILL

deep_duplicate_output="$(
  PROJECTS_ROOT="$deep_duplicate_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$deep_duplicate_dir/skills.registry.yaml" \
    --projects-root "$deep_duplicate_dir/projects"
)"
assert_contains "$deep_duplicate_output" "source-skill: 1 repo-local copies found"

broken_symlink_dir="$tmp_dir/broken-symlink"
mkdir -p "$broken_symlink_dir/example-skill"
ln -s "$broken_symlink_dir/example-skill/missing-target" "$broken_symlink_dir/example-skill/bad-link"

cat >"$broken_symlink_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Broken symlink fixture.
---

# Example Skill
SKILL

cat >"$broken_symlink_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: broken-symlink
  name: Broken Symlink
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

broken_symlink_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$broken_symlink_dir/skills.registry.yaml" --print-lock)"
assert_contains "$broken_symlink_output" "must not be a symlink"
assert_not_contains "$broken_symlink_output" "Traceback"

mode_digest_dir="$tmp_dir/mode-digest"
mkdir -p "$mode_digest_dir/example-skill/scripts"

cat >"$mode_digest_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Mode digest fixture.
---

# Example Skill
SKILL

cat >"$mode_digest_dir/example-skill/scripts/helper.sh" <<'SH'
#!/bin/sh
echo helper
SH

cat >"$mode_digest_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: mode-digest
  name: Mode Digest
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

mode_digest_before="$(ruby "$repo_root/scripts/skills_doctor.rb" --registry "$mode_digest_dir/skills.registry.yaml" --print-lock | ruby -ryaml -e 'puts YAML.safe_load($stdin.read, aliases: false)["skills"][0]["digest_sha256"]')"
chmod +x "$mode_digest_dir/example-skill/scripts/helper.sh"
mode_digest_after="$(ruby "$repo_root/scripts/skills_doctor.rb" --registry "$mode_digest_dir/skills.registry.yaml" --print-lock | ruby -ryaml -e 'puts YAML.safe_load($stdin.read, aliases: false)["skills"][0]["digest_sha256"]')"
if [[ "$mode_digest_before" == "$mode_digest_after" ]]; then
  echo "expected digest to change when executable bit changes" >&2
  exit 1
fi

symlink_file_dir="$tmp_dir/symlink-file"
mkdir -p "$symlink_file_dir/example-skill/references"
printf 'generated outside the skill\n' >"$symlink_file_dir/outside.txt"
ln -s "$symlink_file_dir/outside.txt" "$symlink_file_dir/example-skill/references/generated"

cat >"$symlink_file_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Symlinked file fixture.
---

# Example Skill
SKILL

cat >"$symlink_file_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-file
  name: Symlink File
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

symlink_file_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$symlink_file_dir/skills.registry.yaml" --print-lock)"
assert_contains "$symlink_file_output" "must not be a symlink"
assert_not_contains "$symlink_file_output" "Traceback"

missing_consumer_path_dir="$tmp_dir/missing-consumer-path"
mkdir -p "$missing_consumer_path_dir/example-skill" "$missing_consumer_path_dir/profiles/machine"

cat >"$missing_consumer_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Missing consumer path fixture.
---

# Example Skill
SKILL

cat >"$missing_consumer_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-consumer-path
  name: Missing Consumer Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$missing_consumer_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: missing-consumer-path-profile
consumer_roots:
  fixture_user:
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

missing_consumer_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$missing_consumer_path_dir/skills.registry.yaml" --profile "$missing_consumer_path_dir/profiles/machine/example.yaml" --projects-root "$missing_consumer_path_dir/projects")"
assert_contains "$missing_consumer_path_output" "consumer_roots.fixture_user path must be a non-empty string"
assert_not_contains "$missing_consumer_path_output" "TypeError"

unreadable_skill_dir="$tmp_dir/unreadable-skill"
mkdir -p "$unreadable_skill_dir/example-skill"

cat >"$unreadable_skill_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Unreadable SKILL fixture.
---

# Example Skill
SKILL
chmod 000 "$unreadable_skill_dir/example-skill/SKILL.md"

cat >"$unreadable_skill_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unreadable-skill
  name: Unreadable Skill
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

if [[ "$(id -u)" -eq 0 ]]; then
  chmod 644 "$unreadable_skill_dir/example-skill/SKILL.md"
else
  unreadable_skill_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unreadable_skill_dir/skills.registry.yaml" --print-lock)"
  chmod 644 "$unreadable_skill_dir/example-skill/SKILL.md"
  assert_contains "$unreadable_skill_output" "could not be read"
  assert_not_contains "$unreadable_skill_output" "$unreadable_skill_dir/example-skill/SKILL.md"
  assert_not_contains "$unreadable_skill_output" "Traceback"
fi

hash_redaction_space_dir="$tmp_dir/hash redaction space"
mkdir -p "$hash_redaction_space_dir/example-skill"

cat >"$hash_redaction_space_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Hash redaction fixture.
---

# Example Skill
SKILL

cat >"$hash_redaction_space_dir/example-skill/notes.txt" <<'TEXT'
secret
TEXT
chmod 000 "$hash_redaction_space_dir/example-skill/notes.txt"

cat >"$hash_redaction_space_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: hash-redaction-space
  name: Hash Redaction Space
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

if [[ "$(id -u)" -eq 0 ]]; then
  chmod 644 "$hash_redaction_space_dir/example-skill/notes.txt"
else
  hash_redaction_space_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$hash_redaction_space_dir/skills.registry.yaml" --print-lock)"
  chmod 644 "$hash_redaction_space_dir/example-skill/notes.txt"
  assert_contains "$hash_redaction_space_output" "could not be hashed cleanly"
  assert_not_contains "$hash_redaction_space_output" "$hash_redaction_space_dir/example-skill/notes.txt"
  assert_not_contains "$hash_redaction_space_output" "Traceback"
fi

broken_external_adapter_dir="$tmp_dir/broken-external-adapter"
mkdir -p "$broken_external_adapter_dir/profiles/machine/consumer-root"
ln -s "$broken_external_adapter_dir/missing-target" "$broken_external_adapter_dir/profiles/machine/consumer-root/external-adapter"

cat >"$broken_external_adapter_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: broken-external-adapter
  name: Broken External Adapter
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - external-adapter
YAML

cat >"$broken_external_adapter_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: broken-external-profile
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: external-skill
    expose_to:
      - fixture_user
YAML

broken_external_adapter_output="$(
  PROJECTS_ROOT="$broken_external_adapter_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$broken_external_adapter_dir/skills.registry.yaml" \
    --profile "$broken_external_adapter_dir/profiles/machine/example.yaml" \
    --projects-root "$broken_external_adapter_dir/projects"
)"
assert_contains "$broken_external_adapter_output" "fixture_user: external-adapter adapter symlink is broken"
assert_not_contains "$broken_external_adapter_output" "external skill adapter exists"

symlink_projects_root_dir="$tmp_dir/symlink-projects-root"
mkdir -p "$symlink_projects_root_dir/source-skill" "$symlink_projects_root_dir/real-projects/workspace/.agents/skills/adapter-alias"
ln -s "$symlink_projects_root_dir/real-projects" "$symlink_projects_root_dir/projects-link"

cat >"$symlink_projects_root_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Symlinked projects root fixture.
---

# Symlinked Projects Root
SKILL

cat >"$symlink_projects_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-projects-root
  name: Symlink Projects Root
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$symlink_projects_root_dir/real-projects/workspace/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Repo-local duplicate behind symlinked root.
---

# Repo-local Duplicate
SKILL

symlink_projects_root_output="$(
  PROJECTS_ROOT="$symlink_projects_root_dir/projects-link" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$symlink_projects_root_dir/skills.registry.yaml" \
    --projects-root "$symlink_projects_root_dir/projects-link"
)"
assert_contains "$symlink_projects_root_output" "source-skill: 1 repo-local copies found"

symlink_project_dir_scan_dir="$tmp_dir/symlink-project-dir-scan"
mkdir -p "$symlink_project_dir_scan_dir/source-skill" "$symlink_project_dir_scan_dir/projects" "$symlink_project_dir_scan_dir/real-repo/.agents/skills/adapter-alias"
ln -s "$symlink_project_dir_scan_dir/real-repo" "$symlink_project_dir_scan_dir/projects/repo-link"

cat >"$symlink_project_dir_scan_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Symlinked project directory fixture.
---

# Symlinked Project Directory
SKILL

cat >"$symlink_project_dir_scan_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-project-dir-scan
  name: Symlink Project Dir Scan
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$symlink_project_dir_scan_dir/real-repo/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Repo-local duplicate behind project symlink.
---

# Repo-local Duplicate
SKILL

symlink_project_dir_scan_output="$(
  PROJECTS_ROOT="$symlink_project_dir_scan_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$symlink_project_dir_scan_dir/skills.registry.yaml" \
    --projects-root "$symlink_project_dir_scan_dir/projects"
)"
assert_contains "$symlink_project_dir_scan_output" "source-skill: 1 repo-local copies found"

empty_expose_to_dir="$tmp_dir/empty-expose-to"
mkdir -p "$empty_expose_to_dir/example-skill" "$empty_expose_to_dir/profiles/machine"

cat >"$empty_expose_to_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Empty expose_to fixture.
---

# Example Skill
SKILL

cat >"$empty_expose_to_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: empty-expose-to
  name: Empty Expose To
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$empty_expose_to_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: empty-expose-to-profile
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to: []
YAML

empty_expose_to_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$empty_expose_to_dir/skills.registry.yaml" --profile "$empty_expose_to_dir/profiles/machine/example.yaml" --projects-root "$empty_expose_to_dir/projects")"
assert_contains "$empty_expose_to_output" "example-skill expose_to must list at least one consumer"

lock_artifact_dir="$tmp_dir/lock-artifact"
mkdir -p "$lock_artifact_dir/example-skill"

cat >"$lock_artifact_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Lock artifact fixture.
---

# Example Skill
SKILL

cat >"$lock_artifact_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: lock-artifact
  name: Lock Artifact
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

git -C "$lock_artifact_dir" init -q
git -C "$lock_artifact_dir" add skills.registry.yaml example-skill/SKILL.md
git -C "$lock_artifact_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
printf 'temporary artifact\n' >"$lock_artifact_dir/example-skill/generated.tmp"

lock_artifact_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$lock_artifact_dir/skills.registry.yaml" --print-lock)"
assert_contains "$lock_artifact_output" "example-skill: registry-local source.path has unreviewed git changes; commit or clean changes before --print-lock"
assert_not_contains "$lock_artifact_output" "generated_by: scripts/skills_doctor.rb --print-lock"

tracked_dirty_lock_dir="$tmp_dir/tracked-dirty-lock"
mkdir -p "$tracked_dirty_lock_dir/example-skill"

cat >"$tracked_dirty_lock_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Tracked dirty lock fixture.
---

# Example Skill
SKILL

cat >"$tracked_dirty_lock_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: tracked-dirty-lock
  name: Tracked Dirty Lock
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

git -C "$tracked_dirty_lock_dir" init -q
git -C "$tracked_dirty_lock_dir" add skills.registry.yaml example-skill/SKILL.md
git -C "$tracked_dirty_lock_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
printf '\ntracked edit\n' >>"$tracked_dirty_lock_dir/example-skill/SKILL.md"

tracked_dirty_lock_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$tracked_dirty_lock_dir/skills.registry.yaml" --print-lock)"
assert_contains "$tracked_dirty_lock_output" "example-skill: registry-local source.path has unreviewed git changes; commit or clean changes before --print-lock"
assert_not_contains "$tracked_dirty_lock_output" "generated_by: scripts/skills_doctor.rb --print-lock"

non_string_registry_local_path_dir="$tmp_dir/non-string-registry-local-path"
mkdir -p "$non_string_registry_local_path_dir"

cat >"$non_string_registry_local_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-registry-local-path
  name: Non String Registry Local Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: []
    exported_names:
      - example-skill
YAML

non_string_registry_local_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_registry_local_path_dir/skills.registry.yaml" --print-lock)"
assert_contains "$non_string_registry_local_path_output" "example-skill: registry-local source.path must be a string"

parent_segment_source_path_dir="$tmp_dir/parent-segment-source-path"
mkdir -p "$parent_segment_source_path_dir/example-skill" "$parent_segment_source_path_dir/staging"

cat >"$parent_segment_source_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Parent segment source path fixture.
---

# Example Skill
SKILL

cat >"$parent_segment_source_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: parent-segment-source-path
  name: Parent Segment Source Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: staging/../example-skill
    exported_names:
      - example-skill
YAML

parent_segment_source_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$parent_segment_source_path_dir/skills.registry.yaml" --print-lock)"
assert_contains "$parent_segment_source_path_output" "example-skill: registry-local source.path must be a safe relative path"

control_char_source_path_dir="$tmp_dir/control-char-source-path"
control_char_source_path_name=$'bad\npath'
mkdir -p "$control_char_source_path_dir/$control_char_source_path_name"

cat >"$control_char_source_path_dir/$control_char_source_path_name/SKILL.md" <<'SKILL'
---
name: example-skill
description: Control-char source path fixture.
---

# Example Skill
SKILL

cat >"$control_char_source_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: control-char-source-path
  name: Control Char Source Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: "bad\npath"
    exported_names:
      - example-skill
YAML

control_char_source_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$control_char_source_path_dir/skills.registry.yaml" --print-lock)"
assert_contains "$control_char_source_path_output" "example-skill: registry-local source.path must be a safe relative path"
assert_not_contains "$control_char_source_path_output" "generated_by: scripts/skills_doctor.rb --print-lock"

non_string_skill_id_dir="$tmp_dir/non-string-skill-id"
mkdir -p "$non_string_skill_id_dir/example-skill"

cat >"$non_string_skill_id_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Non string skill id fixture.
---

# Example Skill
SKILL

cat >"$non_string_skill_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-skill-id
  name: Non String Skill Id
skills:
  - id: []
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

non_string_skill_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_skill_id_dir/skills.registry.yaml" --print-lock)"
assert_contains "$non_string_skill_id_output" "skill entry id must be a string"

control_char_skill_id_dir="$tmp_dir/control-char-skill-id"
mkdir -p "$control_char_skill_id_dir/example-skill"

cat >"$control_char_skill_id_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Control-char skill id fixture.
---

# Example Skill
SKILL

cat >"$control_char_skill_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: control-char-skill-id
  name: Control Char Skill Id
skills:
  - id: "bad\nid"
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

control_char_skill_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$control_char_skill_id_dir/skills.registry.yaml" --print-lock)"
assert_contains "$control_char_skill_id_output" "skill entry id must not contain control characters"
assert_not_contains "$control_char_skill_id_output" "generated_by: scripts/skills_doctor.rb --print-lock"

non_string_consumer_path_dir="$tmp_dir/non-string-consumer-path"
mkdir -p "$non_string_consumer_path_dir/example-skill" "$non_string_consumer_path_dir/profiles/machine"

cat >"$non_string_consumer_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Non string consumer path fixture.
---

# Example Skill
SKILL

cat >"$non_string_consumer_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-consumer-path
  name: Non String Consumer Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$non_string_consumer_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: non-string-consumer-path-profile
consumer_roots:
  fixture_user:
    path: []
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

non_string_consumer_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_consumer_path_dir/skills.registry.yaml" --profile "$non_string_consumer_path_dir/profiles/machine/example.yaml" --projects-root "$non_string_consumer_path_dir/projects")"
assert_contains "$non_string_consumer_path_output" "consumer_roots.fixture_user path must be a non-empty string"

unused_consumer_path_dir="$tmp_dir/unused-consumer-path"
mkdir -p "$unused_consumer_path_dir/example-skill" "$unused_consumer_path_dir/profiles/machine"

cat >"$unused_consumer_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Unused consumer path fixture.
---

# Example Skill
SKILL

cat >"$unused_consumer_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unused-consumer-path
  name: Unused Consumer Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$unused_consumer_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unused-consumer-path-profile
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: planned
  unused:
    path: []
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

unused_consumer_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unused_consumer_path_dir/skills.registry.yaml" --profile "$unused_consumer_path_dir/profiles/machine/example.yaml" --projects-root "$unused_consumer_path_dir/projects")"
assert_contains "$unused_consumer_path_output" "consumer_roots.unused path must be a non-empty string"

absolute_lock_redaction_dir="$tmp_dir/absolute-lock-redaction"
mkdir -p "$absolute_lock_redaction_dir/example-skill"

cat >"$absolute_lock_redaction_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Absolute lock redaction fixture.
---

# Example Skill
SKILL

cat >"$absolute_lock_redaction_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: absolute-lock-redaction
  name: Absolute Lock Redaction
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

absolute_lock_redaction_output="$(
  ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$absolute_lock_redaction_dir/skills.registry.yaml" \
    --lock "$absolute_lock_redaction_dir/missing.lock.yaml" \
    --projects-root "$absolute_lock_redaction_dir/projects"
)"
assert_contains "$absolute_lock_redaction_output" "<absolute-path> is missing; run with --print-lock to create a reviewed lock candidate"
assert_not_contains "$absolute_lock_redaction_output" "$absolute_lock_redaction_dir/missing.lock.yaml"

false_lock_doc_dir="$tmp_dir/false-lock-doc"
mkdir -p "$false_lock_doc_dir/example-skill"

cat >"$false_lock_doc_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: False lock doc fixture.
---

# Example Skill
SKILL

cat >"$false_lock_doc_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: false-lock-doc
  name: False Lock Doc
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

printf 'false\n' >"$false_lock_doc_dir/bad.lock.yaml"
false_lock_doc_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$false_lock_doc_dir/skills.registry.yaml" --lock "$false_lock_doc_dir/bad.lock.yaml" --projects-root "$false_lock_doc_dir/projects")"
assert_contains "$false_lock_doc_output" "must contain a top-level mapping"

missing_lock_skills_dir="$tmp_dir/missing-lock-skills"
mkdir -p "$missing_lock_skills_dir/example-skill"

cat >"$missing_lock_skills_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Missing lock skills fixture.
---

# Example Skill
SKILL

cat >"$missing_lock_skills_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-lock-skills
  name: Missing Lock Skills
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$missing_lock_skills_dir/bad.lock.yaml" <<'YAML'
schema_version: 0.1
generated_by: fixture
YAML

missing_lock_skills_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$missing_lock_skills_dir/skills.registry.yaml" --lock "$missing_lock_skills_dir/bad.lock.yaml" --projects-root "$missing_lock_skills_dir/projects")"
assert_contains "$missing_lock_skills_output" "skills must be an array"

special_file_digest_dir="$tmp_dir/special-file-digest"
mkdir -p "$special_file_digest_dir/example-skill"

cat >"$special_file_digest_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Special file digest fixture.
---

# Example Skill
SKILL

mkfifo "$special_file_digest_dir/example-skill/blocking.pipe"

cat >"$special_file_digest_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: special-file-digest
  name: Special File Digest
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

special_file_digest_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$special_file_digest_dir/skills.registry.yaml" --print-lock)"
assert_contains "$special_file_digest_output" "must be a regular file"
assert_not_contains "$special_file_digest_output" "generated_by: scripts/skills_doctor.rb --print-lock"

bad_exported_name_dir="$tmp_dir/bad-exported-name"
mkdir -p "$bad_exported_name_dir"

cat >"$bad_exported_name_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-exported-name
  name: Bad Exported Name
skills:
  - id: example-skill
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - "\0bad"
YAML

bad_exported_name_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_exported_name_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_exported_name_output" "must be a safe adapter directory name"
assert_not_contains "$bad_exported_name_output" "Traceback"

bad_external_fields_dir="$tmp_dir/bad-external-fields"
mkdir -p "$bad_external_fields_dir"

cat >"$bad_external_fields_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-external-fields
  name: Bad External Fields
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: []
      path: {}
      pinned_tag:
        - v1.0.0
      observed_commit:
        bad: value
    exported_names:
      - swiftui-pro
YAML

bad_external_fields_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_external_fields_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_external_fields_output" "swiftui-pro: external-git source.url must be a string"
assert_contains "$bad_external_fields_output" "swiftui-pro: external-git source.path must be a string"
assert_contains "$bad_external_fields_output" "swiftui-pro: external-git pinned_tag must be a string"
assert_contains "$bad_external_fields_output" "swiftui-pro: external-git observed_commit must be a string"
assert_not_contains "$bad_external_fields_output" "generated_by: scripts/skills_doctor.rb --print-lock"

lock_scalar_type_dir="$tmp_dir/lock-scalar-type"
mkdir -p "$lock_scalar_type_dir/123"

cat >"$lock_scalar_type_dir/123/SKILL.md" <<'SKILL'
---
name: adapter-123
description: Lock scalar type fixture.
---

# Lock Scalar Type
SKILL

cat >"$lock_scalar_type_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: lock-scalar-type
  name: Lock Scalar Type
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: "123"
    exported_names:
      - adapter-123
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$lock_scalar_type_dir/skills.registry.yaml" --print-lock >"$lock_scalar_type_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["path"] = 123
  File.write(ARGV[1], lock.to_yaml)
' "$lock_scalar_type_dir/good.lock.yaml" "$lock_scalar_type_dir/bad.lock.yaml"

lock_scalar_type_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$lock_scalar_type_dir/skills.registry.yaml" --lock "$lock_scalar_type_dir/bad.lock.yaml" --projects-root "$lock_scalar_type_dir/projects")"
assert_contains "$lock_scalar_type_output" "example-skill lock path must be a string"

unsafe_registry_local_lock_path_dir="$tmp_dir/unsafe-registry-local-lock-path"
mkdir -p "$unsafe_registry_local_lock_path_dir/example-skill"

cat >"$unsafe_registry_local_lock_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Unsafe registry-local lock path fixture.
---

# Example Skill
SKILL

cat >"$unsafe_registry_local_lock_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-registry-local-lock-path
  name: Unsafe Registry Local Lock Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_registry_local_lock_path_dir/skills.registry.yaml" --print-lock >"$unsafe_registry_local_lock_path_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["path"] = "../outside"
  File.write(ARGV[1], lock.to_yaml)
' "$unsafe_registry_local_lock_path_dir/good.lock.yaml" "$unsafe_registry_local_lock_path_dir/bad.lock.yaml"

unsafe_registry_local_lock_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_registry_local_lock_path_dir/skills.registry.yaml" --lock "$unsafe_registry_local_lock_path_dir/bad.lock.yaml" --projects-root "$unsafe_registry_local_lock_path_dir/projects")"
assert_contains "$unsafe_registry_local_lock_path_output" "example-skill lock path must name a top-level skill directory"

unsafe_external_lock_coords_dir="$tmp_dir/unsafe-external-lock-coords"
mkdir -p "$unsafe_external_lock_coords_dir"

cat >"$unsafe_external_lock_coords_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-external-lock-coords
  name: Unsafe External Lock Coords
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_external_lock_coords_dir/skills.registry.yaml" --print-lock >"$unsafe_external_lock_coords_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["url"] = "--upload-pack=./script"
  lock["skills"][0]["path"] = "../../outside"
  File.write(ARGV[1], lock.to_yaml)
' "$unsafe_external_lock_coords_dir/good.lock.yaml" "$unsafe_external_lock_coords_dir/bad.lock.yaml"

unsafe_external_lock_coords_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_external_lock_coords_dir/skills.registry.yaml" --lock "$unsafe_external_lock_coords_dir/bad.lock.yaml" --projects-root "$unsafe_external_lock_coords_dir/projects")"
assert_contains "$unsafe_external_lock_coords_output" "swiftui-pro lock url must not start with -"

unsafe_external_lock_path_dir="$tmp_dir/unsafe-external-lock-path"
mkdir -p "$unsafe_external_lock_path_dir"

cat >"$unsafe_external_lock_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-external-lock-path
  name: Unsafe External Lock Path
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_external_lock_path_dir/skills.registry.yaml" --print-lock >"$unsafe_external_lock_path_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["path"] = "../../outside"
  File.write(ARGV[1], lock.to_yaml)
' "$unsafe_external_lock_path_dir/good.lock.yaml" "$unsafe_external_lock_path_dir/bad.lock.yaml"

unsafe_external_lock_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_external_lock_path_dir/skills.registry.yaml" --lock "$unsafe_external_lock_path_dir/bad.lock.yaml" --projects-root "$unsafe_external_lock_path_dir/projects")"
assert_contains "$unsafe_external_lock_path_output" "swiftui-pro lock path must be a safe relative path"

unsafe_external_lock_url_dir="$tmp_dir/unsafe-external-lock-url"
mkdir -p "$unsafe_external_lock_url_dir"

cat >"$unsafe_external_lock_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-external-lock-url
  name: Unsafe External Lock Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_external_lock_url_dir/skills.registry.yaml" --print-lock >"$unsafe_external_lock_url_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["url"] = "../private-repo"
  File.write(ARGV[1], lock.to_yaml)
' "$unsafe_external_lock_url_dir/good.lock.yaml" "$unsafe_external_lock_url_dir/bad.lock.yaml"

unsafe_external_lock_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unsafe_external_lock_url_dir/skills.registry.yaml" --lock "$unsafe_external_lock_url_dir/bad.lock.yaml" --projects-root "$unsafe_external_lock_url_dir/projects")"
assert_contains "$unsafe_external_lock_url_output" "swiftui-pro lock url must be a safe relative path"

non_string_selected_skill_id_dir="$tmp_dir/non-string-selected-skill-id"
mkdir -p "$non_string_selected_skill_id_dir/123" "$non_string_selected_skill_id_dir/profiles/machine"

cat >"$non_string_selected_skill_id_dir/123/SKILL.md" <<'SKILL'
---
name: adapter-123
description: Non string selected skill id fixture.
---

# Non String Selected Skill Id
SKILL

cat >"$non_string_selected_skill_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-selected-skill-id
  name: Non String Selected Skill Id
skills:
  - id: "123"
    status: active
    source:
      type: registry-local
      path: "123"
    exported_names:
      - adapter-123
YAML

cat >"$non_string_selected_skill_id_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: non-string-selected-skill-id-profile
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: 123
    expose_to:
      - fixture_user
YAML

non_string_selected_skill_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_selected_skill_id_dir/skills.registry.yaml" --profile "$non_string_selected_skill_id_dir/profiles/machine/example.yaml" --projects-root "$non_string_selected_skill_id_dir/projects")"
assert_contains "$non_string_selected_skill_id_output" "selected_skills[].skill_id must be a non-empty string"

missing_adapter_warning_dir="$tmp_dir/missing-adapter-warning"
mkdir -p "$missing_adapter_warning_dir/example-skill" "$missing_adapter_warning_dir/profiles/machine/consumer-root"

cat >"$missing_adapter_warning_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Missing adapter warning fixture.
---

# Example Skill
SKILL

cat >"$missing_adapter_warning_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-adapter-warning
  name: Missing Adapter Warning
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$missing_adapter_warning_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: missing-adapter-warning-profile
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

missing_adapter_warning_output="$(
  PROJECTS_ROOT="$missing_adapter_warning_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$missing_adapter_warning_dir/skills.registry.yaml" \
    --profile "$missing_adapter_warning_dir/profiles/machine/example.yaml" \
    --projects-root "$missing_adapter_warning_dir/projects"
)"
assert_contains "$missing_adapter_warning_output" "warning: fixture_user: example-skill adapter missing"
assert_contains "$missing_adapter_warning_output" "skills doctor completed with 2 warning(s)"

invalid_consumer_root_path_dir="$tmp_dir/invalid-consumer-root-path"
mkdir -p "$invalid_consumer_root_path_dir/example-skill" "$invalid_consumer_root_path_dir/profiles/machine"

cat >"$invalid_consumer_root_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Invalid consumer root path fixture.
---

# Example Skill
SKILL

cat >"$invalid_consumer_root_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: invalid-consumer-root-path
  name: Invalid Consumer Root Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$invalid_consumer_root_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: invalid-consumer-root-path-profile
consumer_roots:
  fixture_user:
    path: "\0bad"
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

invalid_consumer_root_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$invalid_consumer_root_path_dir/skills.registry.yaml" --profile "$invalid_consumer_root_path_dir/profiles/machine/example.yaml" --projects-root "$invalid_consumer_root_path_dir/projects")"
assert_contains "$invalid_consumer_root_path_output" "consumer_roots.fixture_user path must be a non-empty string"
assert_not_contains "$invalid_consumer_root_path_output" "Traceback"

tilde_user_consumer_path_dir="$tmp_dir/tilde-user-consumer-path"
mkdir -p "$tilde_user_consumer_path_dir/example-skill" "$tilde_user_consumer_path_dir/profiles/machine"

cat >"$tilde_user_consumer_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Tilde user consumer path fixture.
---

# Example Skill
SKILL

cat >"$tilde_user_consumer_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: tilde-user-consumer-path
  name: Tilde User Consumer Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$tilde_user_consumer_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: tilde-user-consumer-path-profile
consumer_roots:
  fixture_user:
    path: ~__skills_doctor_missing_user__/consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

tilde_user_consumer_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$tilde_user_consumer_path_dir/skills.registry.yaml" --profile "$tilde_user_consumer_path_dir/profiles/machine/example.yaml" --projects-root "$tilde_user_consumer_path_dir/projects")"
assert_contains "$tilde_user_consumer_path_output" "consumer_roots.fixture_user path must be a non-empty string"
assert_not_contains "$tilde_user_consumer_path_output" "Traceback"

invalid_upstream_fields_dir="$tmp_dir/invalid-upstream-fields"
mkdir -p "$invalid_upstream_fields_dir"

cat >"$invalid_upstream_fields_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: invalid-upstream-fields
  name: Invalid Upstream Fields
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: "\0bad"
      path: skill
      pinned_tag: "\0tag"
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

invalid_upstream_fields_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$invalid_upstream_fields_dir/skills.registry.yaml" --check-upstream --print-lock)"
assert_contains "$invalid_upstream_fields_output" "swiftui-pro: external-git source.url must not contain null bytes"
assert_contains "$invalid_upstream_fields_output" "swiftui-pro: external-git pinned_tag must not contain null bytes"
assert_not_contains "$invalid_upstream_fields_output" "Traceback"

option_like_upstream_url_dir="$tmp_dir/option-like-upstream-url"
mkdir -p "$option_like_upstream_url_dir"

cat >"$option_like_upstream_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: option-like-upstream-url
  name: Option Like Upstream URL
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: --upload-pack=./script
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

option_like_upstream_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$option_like_upstream_url_dir/skills.registry.yaml" --check-upstream --print-lock)"
assert_contains "$option_like_upstream_url_output" "swiftui-pro: external-git source.url must not start with -"
assert_not_contains "$option_like_upstream_url_output" "Traceback"

wildcard_upstream_tag_dir="$tmp_dir/wildcard-upstream-tag"
mkdir -p "$wildcard_upstream_tag_dir"

cat >"$wildcard_upstream_tag_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: wildcard-upstream-tag
  name: Wildcard Upstream Tag
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v*
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

wildcard_upstream_tag_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$wildcard_upstream_tag_dir/skills.registry.yaml" --check-upstream --print-lock)"
assert_contains "$wildcard_upstream_tag_output" "swiftui-pro: external-git pinned_tag must be an exact tag name"
assert_not_contains "$wildcard_upstream_tag_output" "Traceback"

full_ref_upstream_tag_dir="$tmp_dir/full-ref-upstream-tag"
mkdir -p "$full_ref_upstream_tag_dir"

cat >"$full_ref_upstream_tag_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: full-ref-upstream-tag
  name: Full Ref Upstream Tag
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: refs/tags/v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

full_ref_upstream_tag_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$full_ref_upstream_tag_dir/skills.registry.yaml" --check-upstream --print-lock)"
assert_contains "$full_ref_upstream_tag_output" "swiftui-pro: external-git pinned_tag must be an exact tag name"
assert_not_contains "$full_ref_upstream_tag_output" "Traceback"

upstream_stderr_redaction_dir="$tmp_dir/upstream-stderr-redaction"
mkdir -p "$upstream_stderr_redaction_dir/private repo"

cat >"$upstream_stderr_redaction_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: upstream-stderr-redaction
  name: Upstream Stderr Redaction
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: $upstream_stderr_redaction_dir/private repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

upstream_stderr_redaction_output="$(
  ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$upstream_stderr_redaction_dir/skills.registry.yaml" \
    --check-upstream \
    --projects-root "$upstream_stderr_redaction_dir/projects"
)"
assert_contains "$upstream_stderr_redaction_output" "swiftui-pro: could not resolve upstream tag v1.0.0"
assert_not_contains "$upstream_stderr_redaction_output" "$upstream_stderr_redaction_dir/private repo"
assert_not_contains "$upstream_stderr_redaction_output" "private repo"

print_lock_local_url_dir="$tmp_dir/print-lock-local-url"
mkdir -p "$print_lock_local_url_dir/private-repo"

cat >"$print_lock_local_url_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: print-lock-local-url
  name: Print Lock Local Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: $print_lock_local_url_dir/private-repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_local_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_local_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_local_url_output" "swiftui-pro: external-git source.url must not be a local absolute path when using --print-lock"
assert_not_contains "$print_lock_local_url_output" "$print_lock_local_url_dir/private-repo"
assert_not_contains "$print_lock_local_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_file_url_dir="$tmp_dir/print-lock-file-url"
mkdir -p "$print_lock_file_url_dir/private-repo"

cat >"$print_lock_file_url_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: print-lock-file-url
  name: Print Lock File Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: file://$print_lock_file_url_dir/private-repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_file_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_file_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_file_url_output" "swiftui-pro: external-git source.url must not be a local file:// URL when using --print-lock"
assert_not_contains "$print_lock_file_url_output" "$print_lock_file_url_dir/private-repo"
assert_not_contains "$print_lock_file_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_hosted_file_url_dir="$tmp_dir/print-lock-hosted-file-url"
mkdir -p "$print_lock_hosted_file_url_dir/private-repo"

cat >"$print_lock_hosted_file_url_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: print-lock-hosted-file-url
  name: Print Lock Hosted File Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: file://127.0.0.1$print_lock_hosted_file_url_dir/private-repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_hosted_file_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_hosted_file_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_hosted_file_url_output" "swiftui-pro: external-git source.url must not be a local file:// URL when using --print-lock"
assert_not_contains "$print_lock_hosted_file_url_output" "$print_lock_hosted_file_url_dir/private-repo"
assert_not_contains "$print_lock_hosted_file_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_home_relative_url_dir="$tmp_dir/print-lock-home-relative-url"
mkdir -p "$print_lock_home_relative_url_dir"

cat >"$print_lock_home_relative_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: print-lock-home-relative-url
  name: Print Lock Home Relative Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: ~/private-repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_home_relative_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_home_relative_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_home_relative_url_output" "swiftui-pro: external-git source.url must not be a local home-relative path when using --print-lock"
assert_not_contains "$print_lock_home_relative_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_parent_relative_url_dir="$tmp_dir/print-lock-parent-relative-url"
mkdir -p "$print_lock_parent_relative_url_dir"

cat >"$print_lock_parent_relative_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: print-lock-parent-relative-url
  name: Print Lock Parent Relative Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: ../private-repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_parent_relative_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_parent_relative_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_parent_relative_url_output" "swiftui-pro: external-git source.url must be a safe relative path when using --print-lock"
assert_not_contains "$print_lock_parent_relative_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_credential_url_dir="$tmp_dir/print-lock-credential-url"
mkdir -p "$print_lock_credential_url_dir"

cat >"$print_lock_credential_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: print-lock-credential-url
  name: Print Lock Credential Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://user:token@example.com/org/repo.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_credential_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_credential_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_credential_url_output" "swiftui-pro: external-git source.url must not include HTTP credentials when using --print-lock"
assert_not_contains "$print_lock_credential_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_invalid_credential_url_dir="$tmp_dir/print-lock-invalid-credential-url"
mkdir -p "$print_lock_invalid_credential_url_dir"

cat >"$print_lock_invalid_credential_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: print-lock-invalid-credential-url
  name: Print Lock Invalid Credential Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://user:token@example.com/org/re po.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

print_lock_invalid_credential_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$print_lock_invalid_credential_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$print_lock_invalid_credential_url_output" "swiftui-pro: external-git source.url must not include HTTP credentials when using --print-lock"
assert_not_contains "$print_lock_invalid_credential_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

ext_remote_url_dir="$tmp_dir/ext-remote-url"
mkdir -p "$ext_remote_url_dir"

cat >"$ext_remote_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: ext-remote-url
  name: Ext Remote Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: ext::sh -c echo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ext_remote_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$ext_remote_url_dir/skills.registry.yaml" --check-upstream --print-lock)"
assert_contains "$ext_remote_url_output" "swiftui-pro: external-git source.url must not use ext:: remotes"
assert_not_contains "$ext_remote_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

multiline_upstream_url_dir="$tmp_dir/multiline-upstream-url"
mkdir -p "$multiline_upstream_url_dir"

cat >"$multiline_upstream_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: multiline-upstream-url
  name: Multiline Upstream Url
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: "https://example.com/repo.git\nextra"
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

multiline_upstream_url_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$multiline_upstream_url_dir/skills.registry.yaml" --print-lock)"
assert_contains "$multiline_upstream_url_output" "swiftui-pro: external-git source.url must not contain control characters"
assert_not_contains "$multiline_upstream_url_output" "generated_by: scripts/skills_doctor.rb --print-lock"

print_lock_warning_dir="$tmp_dir/print-lock-warning"
mkdir -p "$print_lock_warning_dir/not-a-git-repo"

cat >"$print_lock_warning_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: print-lock-warning
  name: Print Lock Warning
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: ./not-a-git-repo
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ruby "$repo_root/scripts/skills_doctor.rb" \
  --registry "$print_lock_warning_dir/skills.registry.yaml" \
  --check-upstream \
  --print-lock \
  >"$print_lock_warning_dir/stdout.yaml" \
  2>"$print_lock_warning_dir/stderr.log"
print_lock_warning_stdout="$(cat "$print_lock_warning_dir/stdout.yaml")"
print_lock_warning_stderr="$(cat "$print_lock_warning_dir/stderr.log")"
assert_contains "$print_lock_warning_stdout" "generated_by: scripts/skills_doctor.rb --print-lock"
assert_contains "$print_lock_warning_stderr" "warning: swiftui-pro: could not resolve upstream tag v1.0.0"
assert_not_contains "$print_lock_warning_stdout" "could not resolve upstream tag"

bad_observed_commit_dir="$tmp_dir/bad-observed-commit"
mkdir -p "$bad_observed_commit_dir"

cat >"$bad_observed_commit_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-observed-commit
  name: Bad Observed Commit
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: not-a-commit
    exported_names:
      - swiftui-pro
YAML

bad_observed_commit_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_observed_commit_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_observed_commit_output" "swiftui-pro: external-git observed_commit must be a full git object id"
assert_not_contains "$bad_observed_commit_output" "generated_by: scripts/skills_doctor.rb --print-lock"

bad_lock_observed_commit_dir="$tmp_dir/bad-lock-observed-commit"
mkdir -p "$bad_lock_observed_commit_dir"

cat >"$bad_lock_observed_commit_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-observed-commit
  name: Bad Lock Observed Commit
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_observed_commit_dir/skills.registry.yaml" --print-lock >"$bad_lock_observed_commit_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["observed_commit"] = "not-a-commit"
  File.write(ARGV[1], lock.to_yaml)
' "$bad_lock_observed_commit_dir/good.lock.yaml" "$bad_lock_observed_commit_dir/bad.lock.yaml"

bad_lock_observed_commit_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_observed_commit_dir/skills.registry.yaml" --lock "$bad_lock_observed_commit_dir/bad.lock.yaml" --projects-root "$bad_lock_observed_commit_dir/projects")"
assert_contains "$bad_lock_observed_commit_output" "swiftui-pro lock observed_commit must be a full git object id"

bad_lock_pinned_tag_dir="$tmp_dir/bad-lock-pinned-tag"
mkdir -p "$bad_lock_pinned_tag_dir"

cat >"$bad_lock_pinned_tag_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-pinned-tag
  name: Bad Lock Pinned Tag
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_pinned_tag_dir/skills.registry.yaml" --print-lock >"$bad_lock_pinned_tag_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["pinned_tag"] = "v*"
  File.write(ARGV[1], lock.to_yaml)
' "$bad_lock_pinned_tag_dir/good.lock.yaml" "$bad_lock_pinned_tag_dir/bad.lock.yaml"

bad_lock_pinned_tag_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_pinned_tag_dir/skills.registry.yaml" --lock "$bad_lock_pinned_tag_dir/bad.lock.yaml" --projects-root "$bad_lock_pinned_tag_dir/projects")"
assert_contains "$bad_lock_pinned_tag_output" "swiftui-pro lock pinned_tag must be an exact tag name"

annotated_tag_commit_dir="$tmp_dir/annotated-tag-commit"
mkdir -p "$annotated_tag_commit_dir/upstream"

git -C "$annotated_tag_commit_dir/upstream" init -q
cat >"$annotated_tag_commit_dir/upstream/README.md" <<'EOF'
annotated tag fixture
EOF
git -C "$annotated_tag_commit_dir/upstream" add README.md
git -C "$annotated_tag_commit_dir/upstream" -c user.name=Test -c user.email=test@example.com commit -q -m init
git -C "$annotated_tag_commit_dir/upstream" -c user.name=Test -c user.email=test@example.com tag -a v1.0.0 -m v1.0.0
annotated_tag_object="$(git -C "$annotated_tag_commit_dir/upstream" rev-parse v1.0.0)"
annotated_tag_commit="$(git -C "$annotated_tag_commit_dir/upstream" rev-parse 'v1.0.0^{}')"

cat >"$annotated_tag_commit_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: annotated-tag-commit
  name: Annotated Tag Commit
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: ./upstream
      path: skill
      pinned_tag: v1.0.0
      observed_commit: $annotated_tag_object
    exported_names:
      - swiftui-pro
YAML

annotated_tag_commit_output="$(
  cd "$annotated_tag_commit_dir"
  ruby "$repo_root/scripts/skills_doctor.rb" --registry skills.registry.yaml --check-upstream --projects-root "$annotated_tag_commit_dir/projects"
)"
assert_contains "$annotated_tag_commit_output" "swiftui-pro: pinned tag v1.0.0 no longer resolves to observed_commit ${annotated_tag_object:0:12}"
assert_not_contains "$annotated_tag_commit_output" "$annotated_tag_commit"

annotated_tag_commit_outside_output="$(
  ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$annotated_tag_commit_dir/skills.registry.yaml" \
    --check-upstream \
    --projects-root "$annotated_tag_commit_dir/projects"
)"
assert_contains "$annotated_tag_commit_outside_output" "swiftui-pro: pinned tag v1.0.0 no longer resolves to observed_commit ${annotated_tag_object:0:12}"
assert_not_contains "$annotated_tag_commit_outside_output" "could not resolve upstream tag v1.0.0"

bare_relative_upstream_dir="$tmp_dir/bare-relative-upstream"
mkdir -p "$bare_relative_upstream_dir/upstream.git"

git -C "$bare_relative_upstream_dir/upstream.git" init -q
cat >"$bare_relative_upstream_dir/upstream.git/README.md" <<'EOF'
bare relative upstream fixture
EOF
git -C "$bare_relative_upstream_dir/upstream.git" add README.md
git -C "$bare_relative_upstream_dir/upstream.git" -c user.name=Test -c user.email=test@example.com commit -q -m init
git -C "$bare_relative_upstream_dir/upstream.git" -c user.name=Test -c user.email=test@example.com tag -a v1.0.0 -m v1.0.0
bare_relative_upstream_tag_object="$(git -C "$bare_relative_upstream_dir/upstream.git" rev-parse v1.0.0)"

cat >"$bare_relative_upstream_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bare-relative-upstream
  name: Bare Relative Upstream
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: upstream.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: $bare_relative_upstream_tag_object
    exported_names:
      - swiftui-pro
YAML

bare_relative_upstream_output="$(
  ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$bare_relative_upstream_dir/skills.registry.yaml" \
    --check-upstream \
    --projects-root "$bare_relative_upstream_dir/projects"
)"
assert_contains "$bare_relative_upstream_output" "swiftui-pro: pinned tag v1.0.0 no longer resolves to observed_commit ${bare_relative_upstream_tag_object:0:12}"
assert_not_contains "$bare_relative_upstream_output" "could not resolve upstream tag v1.0.0"

scp_like_upstream_dir="$tmp_dir/scp-like-upstream"
mkdir -p "$scp_like_upstream_dir/bin"

cat >"$scp_like_upstream_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: scp-like-upstream
  name: Scp Like Upstream
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: git.example.com:team/repo.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

cat >"$scp_like_upstream_dir/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls-remote" ]; then
  if [ "\${4:-}" = "git.example.com:team/repo.git" ]; then
    printf '0123456789abcdef0123456789abcdef01234567\trefs/tags/v1.0.0^{}\n'
    exit 0
  fi

  echo "unexpected upstream: \${4:-}" >&2
  exit 1
fi

exec "$real_git" "\$@"
EOF
chmod +x "$scp_like_upstream_dir/bin/git"

scp_like_upstream_output="$(
  PATH="$scp_like_upstream_dir/bin:$PATH" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
      --registry "$scp_like_upstream_dir/skills.registry.yaml" \
      --check-upstream \
      --projects-root "$scp_like_upstream_dir/projects"
)"
assert_contains "$scp_like_upstream_output" "swiftui-pro: upstream tag v1.0.0 resolves to 0123456789ab"
assert_not_contains "$scp_like_upstream_output" "could not resolve upstream tag v1.0.0"

scp_absolute_path_upstream_dir="$tmp_dir/scp-absolute-path-upstream"
mkdir -p "$scp_absolute_path_upstream_dir/bin"

cat >"$scp_absolute_path_upstream_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: scp-absolute-path-upstream
  name: Scp Absolute Path Upstream
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: user@git.example.com:/team/repo.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

cat >"$scp_absolute_path_upstream_dir/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls-remote" ]; then
  if [ "\${4:-}" = "user@git.example.com:/team/repo.git" ]; then
    printf '0123456789abcdef0123456789abcdef01234567\trefs/tags/v1.0.0^{}\n'
    exit 0
  fi

  echo "unexpected upstream: \${4:-}" >&2
  exit 1
fi

exec "$real_git" "\$@"
EOF
chmod +x "$scp_absolute_path_upstream_dir/bin/git"

scp_absolute_path_upstream_output="$(
  PATH="$scp_absolute_path_upstream_dir/bin:$PATH" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
      --registry "$scp_absolute_path_upstream_dir/skills.registry.yaml" \
      --check-upstream \
      --projects-root "$scp_absolute_path_upstream_dir/projects"
)"
assert_contains "$scp_absolute_path_upstream_output" "swiftui-pro: upstream tag v1.0.0 resolves to 0123456789ab"
assert_not_contains "$scp_absolute_path_upstream_output" "could not resolve upstream tag v1.0.0"

single_component_upstream_dir="$tmp_dir/single-component-upstream"
mkdir -p "$single_component_upstream_dir/upstream"

git -C "$single_component_upstream_dir/upstream" init -q
cat >"$single_component_upstream_dir/upstream/README.md" <<'EOF'
single-component upstream
EOF
git -C "$single_component_upstream_dir/upstream" add README.md
git -C "$single_component_upstream_dir/upstream" -c user.name=Test -c user.email=test@example.com commit -q -m init
git -C "$single_component_upstream_dir/upstream" -c user.name=Test -c user.email=test@example.com tag -a v1.0.0 -m v1.0.0
single_component_upstream_tag_object="$(git -C "$single_component_upstream_dir/upstream" rev-parse v1.0.0)"

cat >"$single_component_upstream_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: single-component-upstream
  name: Single Component Upstream
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: upstream
      path: skill
      pinned_tag: v1.0.0
      observed_commit: $single_component_upstream_tag_object
    exported_names:
      - swiftui-pro
YAML

single_component_upstream_output="$(
  (
    cd "$tmp_dir"
    ruby "$repo_root/scripts/skills_doctor.rb" \
      --registry "$single_component_upstream_dir/skills.registry.yaml" \
      --check-upstream \
      --projects-root "$single_component_upstream_dir/projects"
  )
)"
assert_contains "$single_component_upstream_output" "swiftui-pro: pinned tag v1.0.0 no longer resolves to observed_commit ${single_component_upstream_tag_object:0:12}"
assert_not_contains "$single_component_upstream_output" "could not resolve upstream tag v1.0.0"

unresolved_bare_upstream_dir="$tmp_dir/unresolved-bare-upstream"
mkdir -p "$unresolved_bare_upstream_dir/bin"

cat >"$unresolved_bare_upstream_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unresolved-bare-upstream
  name: Unresolved Bare Upstream
skills:
  - id: swiftui-pro
    status: active
    source:
      type: external-git
      url: upstream
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - swiftui-pro
YAML

cat >"$unresolved_bare_upstream_dir/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "ls-remote" ]; then
  echo "unexpected bare upstream resolution" >&2
  exit 99
fi

exec "__REAL_GIT__" "$@"
EOF
perl -0pi -e "s|__REAL_GIT__|$real_git|g" "$unresolved_bare_upstream_dir/bin/git"
chmod +x "$unresolved_bare_upstream_dir/bin/git"

unresolved_bare_upstream_output="$(
  PATH="$unresolved_bare_upstream_dir/bin:$PATH" \
    expect_failure ruby "$repo_root/scripts/skills_doctor.rb" \
      --registry "$unresolved_bare_upstream_dir/skills.registry.yaml" \
      --check-upstream \
      --print-lock
)"
assert_contains "$unresolved_bare_upstream_output" "swiftui-pro: external-git source.url must resolve within the registry root or use an explicit remote URL"
assert_not_contains "$unresolved_bare_upstream_output" "unexpected bare upstream resolution"
assert_not_contains "$unresolved_bare_upstream_output" "generated_by: scripts/skills_doctor.rb --print-lock"

literal_pathspec_dir="$tmp_dir/literal-pathspec"
mkdir -p "$literal_pathspec_dir/:foo"

cat >"$literal_pathspec_dir/:foo/SKILL.md" <<'SKILL'
---
name: colon-skill
description: Literal pathspec fixture.
---

# Colon Skill
SKILL

cat >"$literal_pathspec_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: literal-pathspec
  name: Literal Pathspec
skills:
  - id: colon-skill
    status: active
    source:
      type: registry-local
      path: ":foo"
    exported_names:
      - colon-skill
YAML

git -C "$literal_pathspec_dir" init -q
git -C "$literal_pathspec_dir" add skills.registry.yaml -- ':(literal):foo/SKILL.md'
git -C "$literal_pathspec_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
printf '\ntracked edit\n' >>"$literal_pathspec_dir/:foo/SKILL.md"

literal_pathspec_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$literal_pathspec_dir/skills.registry.yaml" --print-lock)"
assert_contains "$literal_pathspec_output" "colon-skill: registry-local source.path has unreviewed git changes; commit or clean changes before --print-lock"

bad_registry_metadata_dir="$tmp_dir/bad-registry-metadata"
mkdir -p "$bad_registry_metadata_dir/example-skill"

cat >"$bad_registry_metadata_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Bad registry metadata fixture.
---

# Example Skill
SKILL

cat >"$bad_registry_metadata_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: []
  name:
    bad: value
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

bad_registry_metadata_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_registry_metadata_dir/skills.registry.yaml" --print-lock)"
assert_contains "$bad_registry_metadata_output" "registry.id must be a string"
assert_contains "$bad_registry_metadata_output" "registry.name must be a string"
assert_not_contains "$bad_registry_metadata_output" "generated_by: scripts/skills_doctor.rb --print-lock"

non_string_profile_id_dir="$tmp_dir/non-string-profile-id"
mkdir -p "$non_string_profile_id_dir/example-skill" "$non_string_profile_id_dir/profiles/machine"

cat >"$non_string_profile_id_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Non string profile id fixture.
---

# Example Skill
SKILL

cat >"$non_string_profile_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-profile-id
  name: Non String Profile Id
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$non_string_profile_id_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: []
consumer_roots:
  fixture_user:
    path: ./consumer-root
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

non_string_profile_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_profile_id_dir/skills.registry.yaml" --profile "$non_string_profile_id_dir/profiles/machine/example.yaml" --projects-root "$non_string_profile_id_dir/projects")"
assert_contains "$non_string_profile_id_output" "profile.id must be a string"
assert_not_contains "$non_string_profile_id_output" "[]: 1 selected skills"

non_string_consumer_root_key_dir="$tmp_dir/non-string-consumer-root-key"
mkdir -p "$non_string_consumer_root_key_dir/example-skill" "$non_string_consumer_root_key_dir/profiles/machine/consumer-root"

cat >"$non_string_consumer_root_key_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Non string consumer root key fixture.
---

# Example Skill
SKILL

cat >"$non_string_consumer_root_key_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-consumer-root-key
  name: Non String Consumer Root Key
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$non_string_consumer_root_key_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: non-string-consumer-root-key-profile
consumer_roots:
  123:
    path: ./consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - "123"
YAML

non_string_consumer_root_key_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_consumer_root_key_dir/skills.registry.yaml" --profile "$non_string_consumer_root_key_dir/profiles/machine/example.yaml" --projects-root "$non_string_consumer_root_key_dir/projects")"
assert_contains "$non_string_consumer_root_key_output" "consumer_roots keys must be non-empty strings"
assert_not_contains "$non_string_consumer_root_key_output" "skills doctor passed"

normalized_adapter_name_dir="$tmp_dir/normalized-adapter-name"
mkdir -p "$normalized_adapter_name_dir"

cat >"$normalized_adapter_name_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: normalized-adapter-name
  name: Normalized Adapter Name
skills:
  - id: example-skill
    status: active
    source:
      type: external-git
      url: https://example.com/skill.git
      path: skill
      pinned_tag: v1.0.0
      observed_commit: 0123456789abcdef0123456789abcdef01234567
    exported_names:
      - "s/"
YAML

normalized_adapter_name_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$normalized_adapter_name_dir/skills.registry.yaml" --print-lock)"
assert_contains "$normalized_adapter_name_output" "example-skill: exported_name s/ must be a safe adapter directory name"

non_string_lock_id_dir="$tmp_dir/non-string-lock-id"
mkdir -p "$non_string_lock_id_dir/123"

cat >"$non_string_lock_id_dir/123/SKILL.md" <<'SKILL'
---
name: adapter-123
description: Non string lock id fixture.
---

# Non String Lock Id
SKILL

cat >"$non_string_lock_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-lock-id
  name: Non String Lock Id
skills:
  - id: "123"
    status: active
    source:
      type: registry-local
      path: "123"
    exported_names:
      - adapter-123
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_lock_id_dir/skills.registry.yaml" --print-lock >"$non_string_lock_id_dir/good.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["id"] = 123
  File.write(ARGV[1], lock.to_yaml)
' "$non_string_lock_id_dir/good.lock.yaml" "$non_string_lock_id_dir/bad.lock.yaml"

non_string_lock_id_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$non_string_lock_id_dir/skills.registry.yaml" --lock "$non_string_lock_id_dir/bad.lock.yaml" --projects-root "$non_string_lock_id_dir/projects")"
assert_contains "$non_string_lock_id_output" "lock entries must include non-empty string id"

frontmatter_string_dir="$tmp_dir/frontmatter-string"
mkdir -p "$frontmatter_string_dir/example-skill"

cat >"$frontmatter_string_dir/example-skill/SKILL.md" <<'SKILL'
---
name: []
description:
  bad: value
---

# Frontmatter String Fixture
SKILL

cat >"$frontmatter_string_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: frontmatter-string
  name: Frontmatter String
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

frontmatter_string_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$frontmatter_string_dir/skills.registry.yaml" --print-lock)"
assert_contains "$frontmatter_string_output" "SKILL.md front matter name must be a string"
assert_contains "$frontmatter_string_output" "SKILL.md front matter description must be a string"
assert_not_contains "$frontmatter_string_output" "generated_by: scripts/skills_doctor.rb --print-lock"

frontmatter_whitespace_dir="$tmp_dir/frontmatter-whitespace"
mkdir -p "$frontmatter_whitespace_dir/example-skill"

cat >"$frontmatter_whitespace_dir/example-skill/SKILL.md" <<'SKILL'
---
name: "   "
description: "   "
---

# Frontmatter Whitespace Fixture
SKILL

cat >"$frontmatter_whitespace_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: frontmatter-whitespace
  name: Frontmatter Whitespace
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

frontmatter_whitespace_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$frontmatter_whitespace_dir/skills.registry.yaml" --print-lock)"
assert_contains "$frontmatter_whitespace_output" "SKILL.md front matter name is required"
assert_contains "$frontmatter_whitespace_output" "SKILL.md front matter description is required"
assert_not_contains "$frontmatter_whitespace_output" "generated_by: scripts/skills_doctor.rb --print-lock"

symlink_parent_dirty_dir="$tmp_dir/symlink-parent-dirty"
mkdir -p "$symlink_parent_dirty_dir/real-parent/example-skill"
ln -s "$symlink_parent_dirty_dir/real-parent" "$symlink_parent_dirty_dir/link-parent"

cat >"$symlink_parent_dirty_dir/real-parent/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Symlink parent dirty fixture.
---

# Example Skill
SKILL

cat >"$symlink_parent_dirty_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-parent-dirty
  name: Symlink Parent Dirty
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: link-parent/example-skill
    exported_names:
      - example-skill
YAML

git -C "$symlink_parent_dirty_dir" init -q
git -C "$symlink_parent_dirty_dir" add skills.registry.yaml real-parent/example-skill/SKILL.md link-parent
git -C "$symlink_parent_dirty_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
printf '\nreal target edit\n' >>"$symlink_parent_dirty_dir/real-parent/example-skill/SKILL.md"

symlink_parent_dirty_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$symlink_parent_dirty_dir/skills.registry.yaml" --print-lock)"
assert_contains "$symlink_parent_dirty_output" "example-skill: registry-local source.path must name a top-level skill directory"

symlink_declared_path_dirty_dir="$tmp_dir/symlink-declared-path-dirty"
mkdir -p "$symlink_declared_path_dirty_dir/real-parent-one/example-skill" "$symlink_declared_path_dirty_dir/real-parent-two/example-skill"
ln -s "$symlink_declared_path_dirty_dir/real-parent-one" "$symlink_declared_path_dirty_dir/link-parent"

cat >"$symlink_declared_path_dirty_dir/real-parent-one/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Symlink declared path dirty fixture one.
---

# Example Skill
SKILL

cat >"$symlink_declared_path_dirty_dir/real-parent-two/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Symlink declared path dirty fixture two.
---

# Example Skill
SKILL

cat >"$symlink_declared_path_dirty_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-declared-path-dirty
  name: Symlink Declared Path Dirty
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: link-parent/example-skill
    exported_names:
      - example-skill
YAML

git -C "$symlink_declared_path_dirty_dir" init -q
git -C "$symlink_declared_path_dirty_dir" add skills.registry.yaml real-parent-one/example-skill/SKILL.md real-parent-two/example-skill/SKILL.md link-parent
git -C "$symlink_declared_path_dirty_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
rm "$symlink_declared_path_dirty_dir/link-parent"
ln -s "$symlink_declared_path_dirty_dir/real-parent-two" "$symlink_declared_path_dirty_dir/link-parent"

symlink_declared_path_dirty_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$symlink_declared_path_dirty_dir/skills.registry.yaml" --print-lock)"
assert_contains "$symlink_declared_path_dirty_output" "example-skill: registry-local source.path must name a top-level skill directory"

missing_consumer_root_warning_dir="$tmp_dir/missing-consumer-root-warning"
mkdir -p "$missing_consumer_root_warning_dir/example-skill" "$missing_consumer_root_warning_dir/profiles/machine"

cat >"$missing_consumer_root_warning_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Missing consumer root warning fixture.
---

# Example Skill
SKILL

cat >"$missing_consumer_root_warning_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-consumer-root-warning
  name: Missing Consumer Root Warning
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$missing_consumer_root_warning_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: missing-consumer-root-warning-profile
consumer_roots:
  fixture_user:
    path: ./missing-consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - fixture_user
YAML

missing_consumer_root_warning_output="$(
  PROJECTS_ROOT="$missing_consumer_root_warning_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$missing_consumer_root_warning_dir/skills.registry.yaml" \
    --profile "$missing_consumer_root_warning_dir/profiles/machine/example.yaml" \
    --projects-root "$missing_consumer_root_warning_dir/projects"
)"
assert_contains "$missing_consumer_root_warning_output" "warning: fixture_user: <absolute-path> is missing"

directory_lock_path_dir="$tmp_dir/directory-lock-path"
mkdir -p "$directory_lock_path_dir/example-skill" "$directory_lock_path_dir/not-a-lock"

cat >"$directory_lock_path_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Directory lock path fixture.
---

# Example Skill
SKILL

cat >"$directory_lock_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: directory-lock-path
  name: Directory Lock Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

directory_lock_path_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$directory_lock_path_dir/skills.registry.yaml" --lock "$directory_lock_path_dir/not-a-lock" --projects-root "$directory_lock_path_dir/projects")"
assert_contains "$directory_lock_path_output" "must be a file"

dirty_manifest_dir="$tmp_dir/dirty-manifest"
mkdir -p "$dirty_manifest_dir/example-skill"

cat >"$dirty_manifest_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Dirty manifest fixture.
---

# Example Skill
SKILL

cat >"$dirty_manifest_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: dirty-manifest
  name: Dirty Manifest
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

git -C "$dirty_manifest_dir" init -q
git -C "$dirty_manifest_dir" add skills.registry.yaml example-skill/SKILL.md
git -C "$dirty_manifest_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
printf '\n# local change\n' >>"$dirty_manifest_dir/skills.registry.yaml"

dirty_manifest_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$dirty_manifest_dir/skills.registry.yaml" --print-lock)"
assert_contains "$dirty_manifest_output" "registry manifest has unreviewed git changes; commit or clean changes before --print-lock"

git_status_failure_dir="$tmp_dir/git-status-failure"
mkdir -p "$git_status_failure_dir/example-skill" "$git_status_failure_dir/bin"

cat >"$git_status_failure_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Git status failure fixture.
---

# Example Skill
SKILL

cat >"$git_status_failure_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: git-status-failure
  name: Git Status Failure
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

git -C "$git_status_failure_dir" init -q
git -C "$git_status_failure_dir" add skills.registry.yaml example-skill/SKILL.md
git -C "$git_status_failure_dir" -c user.name=Test -c user.email=test@example.com commit -q -m init
printf '\nlocal edit\n' >>"$git_status_failure_dir/example-skill/SKILL.md"

cat >"$git_status_failure_dir/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ] && [ "\${3:-}" = "status" ]; then
  echo "fatal: unable to read index file" >&2
  exit 128
fi

exec "$real_git" "\$@"
EOF
chmod +x "$git_status_failure_dir/bin/git"

git_status_failure_output="$(PATH="$git_status_failure_dir/bin:$PATH" expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$git_status_failure_dir/skills.registry.yaml" --print-lock)"
assert_contains "$git_status_failure_output" "registry manifest git status check failed: fatal: unable to read index file"
assert_not_contains "$git_status_failure_output" "generated_by: scripts/skills_doctor.rb --print-lock"

git_status_failure_normal_output="$(
  PATH="$git_status_failure_dir/bin:$PATH" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
      --registry "$git_status_failure_dir/skills.registry.yaml"
)"
assert_contains "$git_status_failure_normal_output" "registry worktree git status check failed: fatal: unable to read index file"
assert_not_contains "$git_status_failure_normal_output" "registry worktree is clean"

duplicate_scan_loop_dir="$tmp_dir/duplicate-scan-loop"
mkdir -p "$duplicate_scan_loop_dir/source-skill" "$duplicate_scan_loop_dir/projects/workspace/.agents/skills/adapter-alias"
ln -s "$duplicate_scan_loop_dir/projects" "$duplicate_scan_loop_dir/projects/workspace/loop"

cat >"$duplicate_scan_loop_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate scan loop fixture.
---

# Duplicate Scan Loop
SKILL

cat >"$duplicate_scan_loop_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-loop
  name: Duplicate Scan Loop
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$duplicate_scan_loop_dir/projects/workspace/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Repo-local duplicate behind loop fixture.
---

# Repo-local Duplicate
SKILL

duplicate_scan_loop_output="$(
  PROJECTS_ROOT="$duplicate_scan_loop_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_loop_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_loop_dir/projects"
)"
assert_contains "$duplicate_scan_loop_output" "source-skill: 1 repo-local copies found"

duplicate_scan_symlink_adapter_dir="$tmp_dir/duplicate-scan-symlink-adapter"
mkdir -p "$duplicate_scan_symlink_adapter_dir/source-skill" "$duplicate_scan_symlink_adapter_dir/projects/workspace/.agents/skills"

cat >"$duplicate_scan_symlink_adapter_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate scan symlink adapter fixture.
---

# Duplicate Scan Symlink Adapter
SKILL

cat >"$duplicate_scan_symlink_adapter_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-symlink-adapter
  name: Duplicate Scan Symlink Adapter
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

ln -s "$duplicate_scan_symlink_adapter_dir/source-skill" "$duplicate_scan_symlink_adapter_dir/projects/workspace/.agents/skills/adapter-alias"

duplicate_scan_symlink_adapter_output="$(
  PROJECTS_ROOT="$duplicate_scan_symlink_adapter_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_symlink_adapter_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_symlink_adapter_dir/projects"
)"
assert_contains "$duplicate_scan_symlink_adapter_output" "no repo-local copies of registry-owned skills found"
assert_not_contains "$duplicate_scan_symlink_adapter_output" "repo-local copies found"

duplicate_scan_symlink_skills_root_dir="$tmp_dir/duplicate-scan-symlink-skills-root"
mkdir -p "$duplicate_scan_symlink_skills_root_dir/source-skill" "$duplicate_scan_symlink_skills_root_dir/projects/workspace/.agents" "$duplicate_scan_symlink_skills_root_dir/adapter-view/adapter-alias"

cat >"$duplicate_scan_symlink_skills_root_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate scan symlink skills root fixture.
---

# Duplicate Scan Symlink Skills Root
SKILL

cat >"$duplicate_scan_symlink_skills_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-symlink-skills-root
  name: Duplicate Scan Symlink Skills Root
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$duplicate_scan_symlink_skills_root_dir/adapter-view/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Adapter view behind symlinked skills root.
---

# Adapter View
SKILL

ln -s "$duplicate_scan_symlink_skills_root_dir/adapter-view" "$duplicate_scan_symlink_skills_root_dir/projects/workspace/.agents/skills"

duplicate_scan_symlink_skills_root_output="$(
  PROJECTS_ROOT="$duplicate_scan_symlink_skills_root_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_symlink_skills_root_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_symlink_skills_root_dir/projects"
)"
assert_contains "$duplicate_scan_symlink_skills_root_output" "no repo-local copies of registry-owned skills found"
assert_not_contains "$duplicate_scan_symlink_skills_root_output" "repo-local copies found"

duplicate_scan_symlink_agents_root_dir="$tmp_dir/duplicate-scan-symlink-agents-root"
mkdir -p "$duplicate_scan_symlink_agents_root_dir/source-skill" "$duplicate_scan_symlink_agents_root_dir/projects/workspace" "$duplicate_scan_symlink_agents_root_dir/adapter-view/skills/adapter-alias"

cat >"$duplicate_scan_symlink_agents_root_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate scan symlink .agents root fixture.
---

# Duplicate Scan Symlink .agents Root
SKILL

cat >"$duplicate_scan_symlink_agents_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-symlink-agents-root
  name: Duplicate Scan Symlink .agents Root
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$duplicate_scan_symlink_agents_root_dir/adapter-view/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Adapter view behind symlinked .agents root.
---

# Adapter View
SKILL

ln -s "$duplicate_scan_symlink_agents_root_dir/adapter-view" "$duplicate_scan_symlink_agents_root_dir/projects/workspace/.agents"

duplicate_scan_symlink_agents_root_output="$(
  PROJECTS_ROOT="$duplicate_scan_symlink_agents_root_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_symlink_agents_root_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_symlink_agents_root_dir/projects"
)"
assert_contains "$duplicate_scan_symlink_agents_root_output" "no repo-local copies of registry-owned skills found"
assert_not_contains "$duplicate_scan_symlink_agents_root_output" "repo-local copies found"

duplicate_scan_skills_name_dir="$tmp_dir/duplicate-scan-skills-name"
mkdir -p "$duplicate_scan_skills_name_dir/source-skill" "$duplicate_scan_skills_name_dir/projects/workspace/.agents/skills/skills"

cat >"$duplicate_scan_skills_name_dir/source-skill/SKILL.md" <<'SKILL'
---
name: skills
description: Duplicate scan skills-name fixture.
---

# Duplicate Scan Skills Name
SKILL

cat >"$duplicate_scan_skills_name_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-skills-name
  name: Duplicate Scan Skills Name
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - skills
YAML

cat >"$duplicate_scan_skills_name_dir/projects/workspace/.agents/skills/skills/SKILL.md" <<'SKILL'
---
name: skills
description: Repo-local duplicate for adapter named skills.
---

# Repo-local Duplicate
SKILL

duplicate_scan_skills_name_output="$(
  PROJECTS_ROOT="$duplicate_scan_skills_name_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_skills_name_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_skills_name_dir/projects"
)"
assert_contains "$duplicate_scan_skills_name_output" "source-skill: 1 repo-local copies found"

duplicate_scan_nested_projects_root_dir="$tmp_dir/duplicate-scan-nested-projects-root"
mkdir -p "$duplicate_scan_nested_projects_root_dir/source-skill" "$duplicate_scan_nested_projects_root_dir/container/.agents/skills/projects-root/app/.agents/skills/adapter-alias"

cat >"$duplicate_scan_nested_projects_root_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate scan nested projects-root fixture.
---

# Duplicate Scan Nested Projects Root
SKILL

cat >"$duplicate_scan_nested_projects_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-nested-projects-root
  name: Duplicate Scan Nested Projects Root
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$duplicate_scan_nested_projects_root_dir/container/.agents/skills/projects-root/app/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Repo-local duplicate under nested projects root.
---

# Repo-local Duplicate
SKILL

duplicate_scan_nested_projects_root_output="$(
  PROJECTS_ROOT="$duplicate_scan_nested_projects_root_dir/container/.agents/skills/projects-root" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_nested_projects_root_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_nested_projects_root_dir/container/.agents/skills/projects-root"
)"
assert_contains "$duplicate_scan_nested_projects_root_output" "source-skill: 1 repo-local copies found"

duplicate_scan_partial_dir="$tmp_dir/duplicate-scan-partial"
mkdir -p "$duplicate_scan_partial_dir/source-skill" "$duplicate_scan_partial_dir/projects/workspace/.agents/skills/adapter-alias" "$duplicate_scan_partial_dir/fake-bin"

cat >"$duplicate_scan_partial_dir/source-skill/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Duplicate scan partial fixture.
---

# Duplicate Scan Partial
SKILL

cat >"$duplicate_scan_partial_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-scan-partial
  name: Duplicate Scan Partial
skills:
  - id: source-skill
    status: active
    source:
      type: registry-local
      path: source-skill
    exported_names:
      - adapter-alias
YAML

cat >"$duplicate_scan_partial_dir/projects/workspace/.agents/skills/adapter-alias/SKILL.md" <<'SKILL'
---
name: adapter-alias
description: Repo-local duplicate from partial find output.
---

# Repo-local Duplicate
SKILL

cat >"$duplicate_scan_partial_dir/fake-bin/find" <<'SH'
#!/bin/sh
printf '%s\n' "$PROJECTS_ROOT/workspace/.agents/skills/adapter-alias/SKILL.md"
printf '%s\n' "find: '$PROJECTS_ROOT/workspace/loop': File system loop detected" >&2
exit 1
SH
chmod +x "$duplicate_scan_partial_dir/fake-bin/find"

duplicate_scan_partial_output="$(
  PATH="$duplicate_scan_partial_dir/fake-bin:$PATH" \
    PROJECTS_ROOT="$duplicate_scan_partial_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$duplicate_scan_partial_dir/skills.registry.yaml" \
    --projects-root "$duplicate_scan_partial_dir/projects"
)"
assert_contains "$duplicate_scan_partial_output" "source-skill: 1 repo-local copies found"
assert_contains "$duplicate_scan_partial_output" "repo-local duplicate scan encountered find errors; using partial results"
assert_not_contains "$duplicate_scan_partial_output" "$duplicate_scan_partial_dir/projects/workspace/loop"

echo "skills_doctor test ok"
