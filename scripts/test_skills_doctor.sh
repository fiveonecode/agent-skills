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

echo "skills_doctor test ok"
