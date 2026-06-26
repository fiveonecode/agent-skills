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
assert_contains "$lock_check_output" "bad.lock.yaml: lock-skill differs from current source fields: path, exported_names"

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

echo "skills_doctor test ok"
