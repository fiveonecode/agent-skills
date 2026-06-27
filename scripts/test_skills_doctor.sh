#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
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
    "path" => "stale-skill",
    "digest_sha256" => "deadbeef",
    "exported_names" => ["stale-skill"]
  }
  File.write(ARGV[1], lock.to_yaml)
' "$lock_dir/good.lock.yaml" "$lock_dir/bad.lock.yaml"

lock_check_output="$(
  cd "$lock_dir"
  PROJECTS_ROOT="$lock_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$lock_dir/skills.registry.yaml" \
    --lock bad.lock.yaml \
    --projects-root "$lock_dir/projects"
)"

assert_contains "$lock_check_output" "bad.lock.yaml: stale lock entry stale-skill is not present in the registry"
assert_contains "$lock_check_output" "bad.lock.yaml: lock-skill differs from current source fields: source_type, path, exported_names"

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
assert_contains "$duplicate_lock_id_output" "bad.lock.yaml: duplicate lock entry id example-skill"

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
assert_contains "$symlink_parent_output" "outside-skill: registry-local source.path must stay within registry root"

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
assert_contains "$missing_lock_id_output" "bad.lock.yaml: lock entries must include non-empty id"

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
assert_contains "$locked_exported_names_output" "bad.lock.yaml: example-skill lock exported_names must be an array of strings"

directory_input_dir="$tmp_dir/directory-input"
mkdir -p "$directory_input_dir"
directory_input_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$directory_input_dir" --print-lock)"
assert_contains "$directory_input_output" "could not be read"
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
assert_contains "$missing_consumer_path_output" "consumer_roots.fixture_user path is required"
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

unreadable_skill_output="$(expect_failure ruby "$repo_root/scripts/skills_doctor.rb" --registry "$unreadable_skill_dir/skills.registry.yaml" --print-lock)"
chmod 644 "$unreadable_skill_dir/example-skill/SKILL.md"
assert_contains "$unreadable_skill_output" "could not be read"
assert_not_contains "$unreadable_skill_output" "Traceback"

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
      observed_commit: deadbeef
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

echo "skills_doctor test ok"
