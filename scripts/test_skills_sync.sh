#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s\n' "$haystack" | grep -F -q -- "$needle"; then
    echo "expected output to contain: $needle" >&2
    echo "actual output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
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

write_skill() {
  local dir="$1"
  local name="$2"
  local description="$3"
  mkdir -p "$dir"
  cat >"$dir/SKILL.md" <<SKILL
---
name: $name
description: $description
---

# $name
SKILL
}

write_lock_from_registry() {
  ruby "$repo_root/scripts/skills_doctor.rb" --registry "$1/skills.registry.yaml" --print-lock >"$1/skills.lock.yaml"
}

basic_dir="$tmp_dir/basic"
write_skill "$basic_dir/example-skill" "example-skill" "Example fixture skill."
mkdir -p "$basic_dir/profiles/machine" "$basic_dir/consumer-root"

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
    clients:
      codex: supported
YAML

write_lock_from_registry "$basic_dir"

cat >"$basic_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: fixture-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

basic_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$basic_output" "Mode: report-only; no filesystem changes were made"
assert_contains "$basic_output" "create | planned | codex_user/example-skill"
assert_contains "$basic_output" "target=./consumer-root/example-skill"
assert_contains "$basic_output" "source=./example-skill"
assert_contains "$basic_output" "lock=sha256:"
assert_not_contains "$basic_output" "$tmp_dir"

default_lock_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$default_lock_output" "Lock: ./skills.lock.yaml"
assert_contains "$default_lock_output" "create | planned | codex_user/example-skill"

ln -s "$basic_dir/example-skill" "$basic_dir/consumer-root/example-skill"
keep_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$keep_output" "keep | ok | codex_user/example-skill"
assert_contains "$keep_output" "target=./consumer-root/example-skill"
assert_contains "$keep_output" "adapter already points at registry source"

rm "$basic_dir/consumer-root/example-skill"
ln -s "$basic_dir/missing-source" "$basic_dir/consumer-root/example-skill"
broken_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$broken_output" "update | planned | codex_user/example-skill"
assert_contains "$broken_output" "adapter symlink is broken"

rm "$basic_dir/consumer-root/example-skill"
mkdir -p "$tmp_dir/other-source"
ln -s "$tmp_dir/other-source" "$basic_dir/consumer-root/example-skill"
wrong_target_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$wrong_target_output" "update | planned | codex_user/example-skill"
assert_contains "$wrong_target_output" 'adapter symlink points at "<absolute-path>"'
assert_not_contains "$wrong_target_output" "$tmp_dir"

rm "$basic_dir/consumer-root/example-skill"
mkdir -p "$basic_dir/consumer-root/example-skill"
copy_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$copy_output" "manual-review | blocked | codex_user/example-skill"
assert_contains "$copy_output" "directory exists and is not a symlink adapter"

drift_dir="$tmp_dir/drift"
write_skill "$drift_dir/example-skill" "example-skill" "Drift fixture skill."
mkdir -p "$drift_dir/profiles/machine" "$drift_dir/consumer-root"

cat >"$drift_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: drift-fixture
  name: Drift Fixture
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$drift_dir"

cat >"$drift_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: drift-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

printf 'drifted\n' >"$drift_dir/example-skill/EXTRA.md"
drift_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$drift_dir/skills.registry.yaml" --lock "$drift_dir/skills.lock.yaml" --profile "$drift_dir/profiles/machine/example.yaml")"
assert_contains "$drift_output" "example-skill: lock digest_sha256 does not match registry-local source contents"

symlink_source_dir="$tmp_dir/symlink-source"
symlink_target_dir="$tmp_dir/outside-source"
write_skill "$symlink_target_dir" "example-skill" "Outside source fixture."
mkdir -p "$symlink_source_dir/profiles/machine" "$symlink_source_dir/consumer-root"
ln -s "$symlink_target_dir" "$symlink_source_dir/example-skill"

cat >"$symlink_source_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: symlink-source-fixture
  name: Symlink Source Fixture
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$symlink_source_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: example-skill
    source_type: registry-local
    path: example-skill
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - example-skill
YAML

cat >"$symlink_source_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: symlink-source-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

symlink_source_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$symlink_source_dir/skills.registry.yaml" --lock "$symlink_source_dir/skills.lock.yaml" --profile "$symlink_source_dir/profiles/machine/example.yaml")"
assert_contains "$symlink_source_output" "example-skill: registry-local source.path must not be a symlink"

stale_dir="$tmp_dir/stale"
write_skill "$stale_dir/kept-skill" "kept-skill" "Kept skill fixture."
write_skill "$stale_dir/stale-skill" "stale-skill" "Stale skill fixture."
mkdir -p "$stale_dir/profiles/machine" "$stale_dir/consumer-root"

cat >"$stale_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: stale-fixture
  name: Stale Fixture
skills:
  - id: kept-skill
    status: active
    source:
      type: registry-local
      path: kept-skill
    exported_names:
      - kept-skill
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
YAML

write_lock_from_registry "$stale_dir"

cat >"$stale_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: stale-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: kept-skill
    expose_to:
      - codex_user
    state: active
YAML

ln -s "$stale_dir/stale-skill" "$stale_dir/consumer-root/stale-skill"
stale_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$stale_dir/skills.registry.yaml" \
    --lock "$stale_dir/skills.lock.yaml" \
    --profile "$stale_dir/profiles/machine/example.yaml"
)"
assert_contains "$stale_output" "remove-stale | planned | codex_user/stale-skill"

rm "$stale_dir/consumer-root/stale-skill"
mkdir -p "$stale_dir/consumer-root/stale-skill"
stale_copy_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$stale_dir/skills.registry.yaml" \
    --lock "$stale_dir/skills.lock.yaml" \
    --profile "$stale_dir/profiles/machine/example.yaml"
)"
assert_contains "$stale_copy_output" "manual-review | blocked | codex_user/stale-skill"
assert_contains "$stale_copy_output" "registry-named non-symlink entry is not selected by the profile"

unsupported_dir="$tmp_dir/unsupported"
write_skill "$unsupported_dir/local-skill" "local-skill" "Local skill fixture."
mkdir -p "$unsupported_dir/profiles/machine" "$unsupported_dir/consumer-root"

cat >"$unsupported_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsupported-fixture
  name: Unsupported Fixture
skills:
  - id: local-skill
    status: active
    source:
      type: registry-local
      path: local-skill
    exported_names:
      - local-skill
  - id: external-skill
    status: needs-import-review
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: external-skill
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

write_lock_from_registry "$unsupported_dir"

cat >"$unsupported_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unsupported-profile
consumer_roots:
  claude_user:
    path: ../../consumer-root
    adapter: verify-before-use
    status: active
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: local-skill
    expose_to:
      - claude_user
    state: active
  - skill_id: external-skill
    expose_to:
      - codex_user
    state: active
YAML

unsupported_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$unsupported_dir/skills.registry.yaml" \
    --lock "$unsupported_dir/skills.lock.yaml" \
    --profile "$unsupported_dir/profiles/machine/example.yaml"
)"
assert_contains "$unsupported_output" "blocked | blocked | claude_user/local-skill"
assert_contains "$unsupported_output" "adapter type \"verify-before-use\" is not supported"
assert_contains "$unsupported_output" "blocked | blocked | codex_user/external-skill"
assert_contains "$unsupported_output" "external-git source must be imported"

unsupported_stale_dir="$tmp_dir/unsupported-stale"
write_skill "$unsupported_stale_dir/stale-skill" "stale-skill" "Unsupported stale fixture."
mkdir -p "$unsupported_stale_dir/profiles/machine" "$unsupported_stale_dir/consumer-root"

cat >"$unsupported_stale_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsupported-stale
  name: Unsupported Stale
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
YAML

write_lock_from_registry "$unsupported_stale_dir"

cat >"$unsupported_stale_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unsupported-stale-profile
consumer_roots:
  claude_user:
    path: ../../consumer-root
    adapter: verify-before-use
    status: active
YAML

ln -s "$unsupported_stale_dir/stale-skill" "$unsupported_stale_dir/consumer-root/stale-skill"
unsupported_stale_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$unsupported_stale_dir/skills.registry.yaml" \
    --lock "$unsupported_stale_dir/skills.lock.yaml" \
    --profile "$unsupported_stale_dir/profiles/machine/example.yaml"
)"
assert_contains "$unsupported_stale_output" "manual-review | blocked | claude_user/stale-skill"
assert_contains "$unsupported_stale_output" "adapter type \"verify-before-use\" is not supported"

missing_skill_file_dir="$tmp_dir/missing-skill-file"
mkdir -p "$missing_skill_file_dir/docs" "$missing_skill_file_dir/profiles/machine" "$missing_skill_file_dir/consumer-root"
printf '# docs\n' >"$missing_skill_file_dir/docs/README.md"

cat >"$missing_skill_file_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-skill-file
  name: Missing Skill File
skills:
  - id: docs-skill
    status: active
    source:
      type: registry-local
      path: docs
    exported_names:
      - docs-skill
YAML

cat >"$missing_skill_file_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: docs-skill
    source_type: registry-local
    path: docs
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - docs-skill
YAML

cat >"$missing_skill_file_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: missing-skill-file-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: docs-skill
    expose_to:
      - codex_user
    state: active
YAML

missing_skill_file_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$missing_skill_file_dir/skills.registry.yaml" --lock "$missing_skill_file_dir/skills.lock.yaml" --profile "$missing_skill_file_dir/profiles/machine/example.yaml")"
assert_contains "$missing_skill_file_output" "docs-skill: docs/SKILL.md is missing"

duplicate_exports_dir="$tmp_dir/duplicate-exports"
write_skill "$duplicate_exports_dir/example-skill" "example-skill" "Duplicate exports fixture."
mkdir -p "$duplicate_exports_dir/profiles/machine"

cat >"$duplicate_exports_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-exports
  name: Duplicate Exports
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
      - example-skill
YAML

cat >"$duplicate_exports_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: example-skill
    source_type: registry-local
    path: example-skill
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - example-skill
      - example-skill
YAML

cat >"$duplicate_exports_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: duplicate-exports-profile
consumer_roots: {}
YAML

duplicate_exports_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$duplicate_exports_dir/skills.registry.yaml" --lock "$duplicate_exports_dir/skills.lock.yaml" --profile "$duplicate_exports_dir/profiles/machine/example.yaml")"
assert_contains "$duplicate_exports_output" "example-skill: exported adapter name example-skill is duplicated"

unsafe_external_dir="$tmp_dir/unsafe-external"
mkdir -p "$unsafe_external_dir/profiles/machine"

cat >"$unsafe_external_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-external
  name: Unsafe External
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://user:token@example.com/example/skill.git
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$unsafe_external_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://user:token@example.com/example/skill.git
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$unsafe_external_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unsafe-external-profile
consumer_roots: {}
YAML

unsafe_external_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$unsafe_external_dir/skills.registry.yaml" --lock "$unsafe_external_dir/skills.lock.yaml" --profile "$unsafe_external_dir/profiles/machine/example.yaml")"
assert_contains "$unsafe_external_output" "external-skill: external-git source.url must not include credentials"

missing_root_dir="$tmp_dir/missing-root"
write_skill "$missing_root_dir/example-skill" "example-skill" "Missing root fixture."
mkdir -p "$missing_root_dir/profiles/machine"

cat >"$missing_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-root
  name: Missing Root
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$missing_root_dir"

cat >"$missing_root_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: missing-root-profile
consumer_roots:
  codex_user:
    path: ../../missing-consumer-root
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

missing_root_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$missing_root_dir/skills.registry.yaml" \
    --lock "$missing_root_dir/skills.lock.yaml" \
    --profile "$missing_root_dir/profiles/machine/example.yaml"
)"
assert_contains "$missing_root_output" "create | planned | codex_user/example-skill"
assert_contains "$missing_root_output" "consumer root is missing; apply would create it before linking"

duplicate_target_dir="$tmp_dir/duplicate-target"
write_skill "$duplicate_target_dir/example-skill" "example-skill" "Duplicate target fixture."
mkdir -p "$duplicate_target_dir/profiles/machine" "$duplicate_target_dir/consumer-root"

cat >"$duplicate_target_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-target
  name: Duplicate Target
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$duplicate_target_dir"

cat >"$duplicate_target_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: duplicate-target-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

duplicate_target_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$duplicate_target_dir/skills.registry.yaml" --lock "$duplicate_target_dir/skills.lock.yaml" --profile "$duplicate_target_dir/profiles/machine/example.yaml")"
assert_contains "$duplicate_target_output" "maps ./consumer-root/example-skill from both example-skill and example-skill"

bad_profile_dir="$tmp_dir/bad-profile"
write_skill "$bad_profile_dir/example-skill" "example-skill" "Bad profile fixture."
mkdir -p "$bad_profile_dir/profiles/machine"

cat >"$bad_profile_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-profile
  name: Bad Profile
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_profile_dir"

cat >"$bad_profile_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-profile
consumer_roots:
  codex_user:
    path: ./consumer-root
    adapter: symlink
selected_skills:
  - skill_id: missing-skill
    expose_to:
      - other_user
    state: active
YAML

bad_profile_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_profile_dir/skills.registry.yaml" --lock "$bad_profile_dir/skills.lock.yaml" --profile "$bad_profile_dir/profiles/machine/example.yaml")"
assert_contains "$bad_profile_output" "selected skill missing-skill is not in registry"
assert_contains "$bad_profile_output" "missing-skill exposes to unknown consumer other_user"

bad_registry_shape_dir="$tmp_dir/bad-registry-shape"
mkdir -p "$bad_registry_shape_dir"

cat >"$bad_registry_shape_dir/skills.registry.yaml" <<'YAML'
- invalid
YAML

cat >"$bad_registry_shape_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills: []
YAML

bad_registry_shape_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_registry_shape_dir/skills.registry.yaml" --lock "$bad_registry_shape_dir/skills.lock.yaml")"
assert_contains "$bad_registry_shape_output" "must contain a top-level mapping"

bad_profile_shape_dir="$tmp_dir/bad-profile-shape"
write_skill "$bad_profile_shape_dir/example-skill" "example-skill" "Bad profile shape fixture."
mkdir -p "$bad_profile_shape_dir/profiles/machine" "$bad_profile_shape_dir/consumer-root"

cat >"$bad_profile_shape_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-profile-shape
  name: Bad Profile Shape
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_profile_shape_dir"

cat >"$bad_profile_shape_dir/profiles/machine/example.yaml" <<'YAML'
- invalid
YAML

bad_profile_shape_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_profile_shape_dir/skills.registry.yaml" --lock "$bad_profile_shape_dir/skills.lock.yaml" --profile "$bad_profile_shape_dir/profiles/machine/example.yaml")"
assert_contains "$bad_profile_shape_output" "must contain a top-level mapping"

missing_lock_dir="$tmp_dir/missing-lock"
write_skill "$missing_lock_dir/example-skill" "example-skill" "Missing lock fixture."
mkdir -p "$missing_lock_dir/profiles/machine"

cat >"$missing_lock_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-lock
  name: Missing Lock
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$missing_lock_dir/skills.lock.yaml" <<'YAML'
---
schema_version: 0.1
skills: []
YAML

cat >"$missing_lock_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: missing-lock-profile
consumer_roots:
  codex_user:
    path: ./consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

missing_lock_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$missing_lock_dir/skills.registry.yaml" --lock "$missing_lock_dir/skills.lock.yaml" --profile "$missing_lock_dir/profiles/machine/example.yaml")"
assert_contains "$missing_lock_output" "missing lock entry for example-skill"

bad_lock_mapping_dir="$tmp_dir/bad-lock-mapping"
write_skill "$bad_lock_mapping_dir/example-skill" "example-skill" "Bad lock mapping fixture."
mkdir -p "$bad_lock_mapping_dir/profiles/machine"

cat >"$bad_lock_mapping_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-mapping
  name: Bad Lock Mapping
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$bad_lock_mapping_dir/skills.lock.yaml" <<'YAML'
- invalid
YAML

cat >"$bad_lock_mapping_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-lock-mapping-profile
consumer_roots:
  codex_user:
    path: ./consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

bad_lock_mapping_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_lock_mapping_dir/skills.registry.yaml" --lock "$bad_lock_mapping_dir/skills.lock.yaml" --profile "$bad_lock_mapping_dir/profiles/machine/example.yaml")"
assert_contains "$bad_lock_mapping_output" "./skills.lock.yaml must contain a top-level mapping"

bad_lock_shape_dir="$tmp_dir/bad-lock-shape"
write_skill "$bad_lock_shape_dir/example-skill" "example-skill" "Bad lock shape fixture."
mkdir -p "$bad_lock_shape_dir/profiles/machine"

cat >"$bad_lock_shape_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-lock-shape
  name: Bad Lock Shape
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

ruby "$repo_root/scripts/skills_doctor.rb" --registry "$bad_lock_shape_dir/skills.registry.yaml" --print-lock >"$bad_lock_shape_dir/skills.lock.yaml"
ruby -ryaml -e '
  lock = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  lock["skills"][0]["exported_names"] = "example-skill"
  lock["skills"] << {
    "id" => "stale-skill",
    "source_type" => "registry-local",
    "path" => "stale-skill",
    "digest_sha256" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "exported_names" => ["stale-skill"]
  }
  File.write(ARGV[0], lock.to_yaml)
' "$bad_lock_shape_dir/skills.lock.yaml"

cat >"$bad_lock_shape_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-lock-shape-profile
consumer_roots:
  codex_user:
    path: ./consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

bad_lock_shape_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_lock_shape_dir/skills.registry.yaml" --lock "$bad_lock_shape_dir/skills.lock.yaml" --profile "$bad_lock_shape_dir/profiles/machine/example.yaml")"
assert_contains "$bad_lock_shape_output" "lock exported_names must be an array of strings"
assert_contains "$bad_lock_shape_output" "stale lock entry stale-skill is not present in the registry"

json_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --json \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
ruby -rjson -e '
  parsed = JSON.parse(ARGF.read)
  raise "expected plan mode" unless parsed["mode"] == "plan"
  raise "must be read-only" unless parsed["changed_filesystem"] == false
  raise "expected actions" if parsed["actions"].empty?
' <<<"$json_output"

echo "skills_sync test ok"
