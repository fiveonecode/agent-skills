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

assert_occurrences() {
  local haystack="$1"
  local needle="$2"
  local expected_count="$3"
  local actual_count

  actual_count="$(printf '%s\n' "$haystack" | grep -F -c -- "$needle" || true)"
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "expected $expected_count occurrences of: $needle" >&2
    echo "actual count: $actual_count" >&2
    echo "actual output:" >&2
    printf '%s\n' "$haystack" >&2
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

shell_syntax_dir="$tmp_dir/shell-syntax"
mkdir -p "$shell_syntax_dir"
cat >"$shell_syntax_dir/bad.sh" <<'SH'
if
SH
cat >"$shell_syntax_dir/good.sh" <<'SH'
echo ok
SH
shell_syntax_output="$(expect_failure bash -lc 'set -e; for file in "$@"; do bash -n "$file"; done' _ "$shell_syntax_dir/bad.sh" "$shell_syntax_dir/good.sh")"
assert_contains "$shell_syntax_output" "syntax error"

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
windows_link_target='C:\Users\alice\secret'
mkdir -p "$basic_dir/consumer-root/$windows_link_target"
ln -s "$windows_link_target" "$basic_dir/consumer-root/example-skill"
windows_target_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$basic_dir/skills.registry.yaml" \
    --lock "$basic_dir/skills.lock.yaml" \
    --profile "$basic_dir/profiles/machine/example.yaml"
)"
assert_contains "$windows_target_output" "update | planned | codex_user/example-skill"
assert_contains "$windows_target_output" 'adapter symlink points at "<absolute-path>"'
assert_not_contains "$windows_target_output" "$windows_link_target"

rm "$basic_dir/consumer-root/example-skill"
rm -rf "$basic_dir/consumer-root/$windows_link_target"
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

renamed_export_dir="$tmp_dir/renamed-export"
write_skill "$renamed_export_dir/example-skill" "example-skill" "Renamed export fixture."
mkdir -p "$renamed_export_dir/profiles/machine" "$renamed_export_dir/consumer-root"

cat >"$renamed_export_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: renamed-export
  name: Renamed Export
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - new-name
YAML

write_lock_from_registry "$renamed_export_dir"

cat >"$renamed_export_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: renamed-export-profile
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

ln -s "$renamed_export_dir/example-skill" "$renamed_export_dir/consumer-root/old-name"
renamed_export_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$renamed_export_dir/skills.registry.yaml" \
    --lock "$renamed_export_dir/skills.lock.yaml" \
    --profile "$renamed_export_dir/profiles/machine/example.yaml"
)"
assert_contains "$renamed_export_output" "create | planned | codex_user/new-name"
assert_contains "$renamed_export_output" "remove-stale | planned | codex_user/old-name"
assert_contains "$renamed_export_output" "registry adapter name is no longer exported by the registry but still points at the skill source"

blocked_rename_dir="$tmp_dir/blocked-rename"
write_skill "$blocked_rename_dir/example-skill" "example-skill" "Blocked rename fixture."
mkdir -p "$blocked_rename_dir/profiles/machine" "$blocked_rename_dir/consumer-root"

cat >"$blocked_rename_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: blocked-rename
  name: Blocked Rename
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - new-name
YAML

write_lock_from_registry "$blocked_rename_dir"

cat >"$blocked_rename_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: blocked-rename-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: pending-review
YAML

ln -s "$blocked_rename_dir/example-skill" "$blocked_rename_dir/consumer-root/old-name"
blocked_rename_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$blocked_rename_dir/skills.registry.yaml" \
    --lock "$blocked_rename_dir/skills.lock.yaml" \
    --profile "$blocked_rename_dir/profiles/machine/example.yaml"
)"
assert_contains "$blocked_rename_output" "blocked | blocked | codex_user/new-name"
assert_contains "$blocked_rename_output" "manual-review | blocked | codex_user/old-name"
assert_contains "$blocked_rename_output" "selected skill state is pending-review, so stale adapter rename requires manual review"
assert_not_contains "$blocked_rename_output" "remove-stale | planned | codex_user/old-name"

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

duplicate_source_owner_dir="$tmp_dir/duplicate-source-owner"
write_skill "$duplicate_source_owner_dir/shared-skill" "shared-skill" "Duplicate source owner fixture."
mkdir -p "$duplicate_source_owner_dir/profiles/machine"

cat >"$duplicate_source_owner_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-source-owner
  name: Duplicate Source Owner
skills:
  - id: skill-a
    status: active
    source:
      type: registry-local
      path: shared-skill
    exported_names:
      - skill-a
  - id: skill-b
    status: active
    source:
      type: registry-local
      path: shared-skill
    exported_names:
      - skill-b
YAML

write_lock_from_registry "$duplicate_source_owner_dir"

cat >"$duplicate_source_owner_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: duplicate-source-owner-profile
consumer_roots: {}
YAML

duplicate_source_owner_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$duplicate_source_owner_dir/skills.registry.yaml" --lock "$duplicate_source_owner_dir/skills.lock.yaml" --profile "$duplicate_source_owner_dir/profiles/machine/example.yaml")"
assert_contains "$duplicate_source_owner_output" "skill-b: registry-local source.path shared-skill is already declared by skill-a"

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

ssh_external_dir="$tmp_dir/ssh-external"
mkdir -p "$ssh_external_dir/profiles/machine"

cat >"$ssh_external_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: ssh-external
  name: SSH External
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: ssh://git@github.com/example/skill.git
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
  - id: external-skill-port
    status: active
    source:
      type: external-git
      url: ssh://git@github.com:2222/example/skill.git
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "2222222222222222222222222222222222222222"
    exported_names:
      - external-skill-port
YAML

cat >"$ssh_external_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: ssh://git@github.com/example/skill.git
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
  - id: external-skill-port
    source_type: external-git
    url: ssh://git@github.com:2222/example/skill.git
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "2222222222222222222222222222222222222222"
    exported_names:
      - external-skill-port
YAML

cat >"$ssh_external_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: ssh-external-profile
consumer_roots: {}
YAML

ssh_external_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$ssh_external_dir/skills.registry.yaml" \
    --lock "$ssh_external_dir/skills.lock.yaml" \
    --profile "$ssh_external_dir/profiles/machine/example.yaml"
)"
assert_contains "$ssh_external_output" "- no adapter actions"
assert_not_contains "$ssh_external_output" "must not include credentials"

non_string_external_path_dir="$tmp_dir/non-string-external-path"
mkdir -p "$non_string_external_path_dir/profiles/machine"

cat >"$non_string_external_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: non-string-external-path
  name: Non String External Path
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: []
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$non_string_external_path_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: "[]"
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$non_string_external_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: non-string-external-path-profile
consumer_roots: {}
YAML

non_string_external_path_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$non_string_external_path_dir/skills.registry.yaml" --lock "$non_string_external_path_dir/skills.lock.yaml" --profile "$non_string_external_path_dir/profiles/machine/example.yaml")"
assert_contains "$non_string_external_path_output" "external-skill: external-git source.path must be a string when provided"

invalid_external_pins_dir="$tmp_dir/invalid-external-pins"
mkdir -p "$invalid_external_pins_dir/profiles/machine"

cat >"$invalid_external_pins_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: invalid-external-pins
  name: Invalid External Pins
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: skill-dir
      pinned_tag: refs/heads/main
      observed_commit: abc
    exported_names:
      - external-skill
YAML

cat >"$invalid_external_pins_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: skill-dir
    pinned_tag: refs/heads/main
    observed_commit: abc
    exported_names:
      - external-skill
YAML

cat >"$invalid_external_pins_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: invalid-external-pins-profile
consumer_roots: {}
YAML

invalid_external_pins_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$invalid_external_pins_dir/skills.registry.yaml" --lock "$invalid_external_pins_dir/skills.lock.yaml" --profile "$invalid_external_pins_dir/profiles/machine/example.yaml")"
assert_contains "$invalid_external_pins_output" "external-skill: external-git source.pinned_tag must be an exact tag name"
assert_contains "$invalid_external_pins_output" "external-skill: external-git source.observed_commit must be a full git object id"

invalid_external_lock_fields_dir="$tmp_dir/invalid-external-lock-fields"
mkdir -p "$invalid_external_lock_fields_dir/profiles/machine"

cat >"$invalid_external_lock_fields_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: invalid-external-lock-fields
  name: Invalid External Lock Fields
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: skill-dir
      pinned_tag: "1"
      observed_commit: ""
    exported_names:
      - external-skill
YAML

cat >"$invalid_external_lock_fields_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: skill-dir
    pinned_tag: 1
    exported_names:
      - external-skill
YAML

cat >"$invalid_external_lock_fields_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: invalid-external-lock-fields-profile
consumer_roots: {}
YAML

invalid_external_lock_fields_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$invalid_external_lock_fields_dir/skills.registry.yaml" --lock "$invalid_external_lock_fields_dir/skills.lock.yaml" --profile "$invalid_external_lock_fields_dir/profiles/machine/example.yaml")"
assert_contains "$invalid_external_lock_fields_output" "external-skill: lock pinned_tag must be a string"
assert_contains "$invalid_external_lock_fields_output" "external-skill: lock observed_commit must be a string"

uppercase_external_commit_dir="$tmp_dir/uppercase-external-commit"
mkdir -p "$uppercase_external_commit_dir/profiles/machine"

cat >"$uppercase_external_commit_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: uppercase-external-commit
  name: Uppercase External Commit
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: skill-dir
      pinned_tag: "1"
      observed_commit: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    exported_names:
      - external-skill
YAML

cat >"$uppercase_external_commit_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: skill-dir
    pinned_tag: "1"
    observed_commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    exported_names:
      - external-skill
YAML

cat >"$uppercase_external_commit_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: uppercase-external-commit-profile
consumer_roots: {}
YAML

uppercase_external_commit_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$uppercase_external_commit_dir/skills.registry.yaml" \
    --lock "$uppercase_external_commit_dir/skills.lock.yaml" \
    --profile "$uppercase_external_commit_dir/profiles/machine/example.yaml"
)"
assert_contains "$uppercase_external_commit_output" "- no adapter actions"
assert_not_contains "$uppercase_external_commit_output" "lock observed_commit differs from registry"

stale_subpath_dir="$tmp_dir/stale-subpath"
write_skill "$stale_subpath_dir/stale-skill" "stale-skill" "Stale subpath fixture."
mkdir -p "$stale_subpath_dir/stale-skill/references" "$stale_subpath_dir/profiles/machine" "$stale_subpath_dir/consumer-root"

cat >"$stale_subpath_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: stale-subpath
  name: Stale Subpath
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
YAML

write_lock_from_registry "$stale_subpath_dir"

cat >"$stale_subpath_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: stale-subpath-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
YAML

ln -s "$stale_subpath_dir/stale-skill/references" "$stale_subpath_dir/consumer-root/stale-skill"
stale_subpath_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$stale_subpath_dir/skills.registry.yaml" \
    --lock "$stale_subpath_dir/skills.lock.yaml" \
    --profile "$stale_subpath_dir/profiles/machine/example.yaml"
)"
assert_contains "$stale_subpath_output" "manual-review | blocked | codex_user/stale-skill"
assert_contains "$stale_subpath_output" "symlink points to a subpath inside the skill source"

unsafe_stale_link_dir="$tmp_dir/unsafe-stale-link"
write_skill "$unsafe_stale_link_dir/stale-skill" "stale-skill" "Unsafe stale link fixture."
mkdir -p "$unsafe_stale_link_dir/profiles/machine" "$unsafe_stale_link_dir/consumer-root"

cat >"$unsafe_stale_link_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-stale-link
  name: Unsafe Stale Link
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
    clients:
      codex: supported
YAML

write_lock_from_registry "$unsafe_stale_link_dir"

cat >"$unsafe_stale_link_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unsafe-stale-link-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
YAML

unsafe_stale_link_name='stale\name'
ln -s "$unsafe_stale_link_dir/stale-skill" "$unsafe_stale_link_dir/consumer-root/$unsafe_stale_link_name"
unsafe_stale_link_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$unsafe_stale_link_dir/skills.registry.yaml" \
    --lock "$unsafe_stale_link_dir/skills.lock.yaml" \
    --profile "$unsafe_stale_link_dir/profiles/machine/example.yaml"
)"
assert_contains "$unsafe_stale_link_output" 'manual-review | blocked | codex_user/stale\name'
assert_contains "$unsafe_stale_link_output" "unsafe adapter name"
assert_not_contains "$unsafe_stale_link_output" "- no adapter actions"

unsafe_windows_stale_link_dir="$tmp_dir/unsafe-windows-stale-link"
write_skill "$unsafe_windows_stale_link_dir/stale-skill" "stale-skill" "Unsafe Windows stale link fixture."
mkdir -p "$unsafe_windows_stale_link_dir/profiles/machine" "$unsafe_windows_stale_link_dir/consumer-root"
windows_stale_name='C:\Users\alice\secret-stale'
windows_stale_name_json="${windows_stale_name//\\/\\\\}"

cat >"$unsafe_windows_stale_link_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unsafe-windows-stale-link
  name: Unsafe Windows Stale Link
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
    clients:
      codex: supported
YAML

write_lock_from_registry "$unsafe_windows_stale_link_dir"

cat >"$unsafe_windows_stale_link_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unsafe-windows-stale-link-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
    status: active
YAML

ln -s "$unsafe_windows_stale_link_dir/stale-skill" "$unsafe_windows_stale_link_dir/consumer-root/$windows_stale_name"
unsafe_windows_stale_link_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --json \
    --registry "$unsafe_windows_stale_link_dir/skills.registry.yaml" \
    --lock "$unsafe_windows_stale_link_dir/skills.lock.yaml" \
    --profile "$unsafe_windows_stale_link_dir/profiles/machine/example.yaml"
)"
assert_contains "$unsafe_windows_stale_link_output" '"exported_name": "<unsafe-adapter-name>"'
assert_contains "$unsafe_windows_stale_link_output" '"target": "./consumer-root/<unsafe-adapter-name>"'
assert_not_contains "$unsafe_windows_stale_link_output" "$windows_stale_name_json"

bad_adapter_type_dir="$tmp_dir/bad-adapter-type"
write_skill "$bad_adapter_type_dir/example-skill" "example-skill" "Bad adapter type fixture."
mkdir -p "$bad_adapter_type_dir/profiles/machine"

cat >"$bad_adapter_type_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-adapter-type
  name: Bad Adapter Type
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_adapter_type_dir"

cat >"$bad_adapter_type_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-adapter-type-profile
consumer_roots:
  codex_user:
    path: ./consumer-root
    adapter: []
YAML

bad_adapter_type_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_adapter_type_dir/skills.registry.yaml" --lock "$bad_adapter_type_dir/skills.lock.yaml" --profile "$bad_adapter_type_dir/profiles/machine/example.yaml")"
assert_contains "$bad_adapter_type_output" "consumer_roots.codex_user adapter must be a string when provided"

bad_adapter_value_dir="$tmp_dir/bad-adapter-value"
write_skill "$bad_adapter_value_dir/example-skill" "example-skill" "Bad adapter value fixture."
mkdir -p "$bad_adapter_value_dir/profiles/machine" "$bad_adapter_value_dir/consumer-root"
secret_adapter="$bad_adapter_value_dir/secret-adapter"

cat >"$bad_adapter_value_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-adapter-value
  name: Bad Adapter Value
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_adapter_value_dir"

cat >"$bad_adapter_value_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-adapter-value-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: $secret_adapter
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

bad_adapter_value_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_adapter_value_dir/skills.registry.yaml" --lock "$bad_adapter_value_dir/skills.lock.yaml" --profile "$bad_adapter_value_dir/profiles/machine/example.yaml")"
assert_contains "$bad_adapter_value_output" "consumer_roots.codex_user adapter must be a safe non-path identifier"
assert_not_contains "$bad_adapter_value_output" "$secret_adapter"

bad_windows_adapter_value_dir="$tmp_dir/bad-windows-adapter-value"
write_skill "$bad_windows_adapter_value_dir/example-skill" "example-skill" "Bad Windows adapter value fixture."
mkdir -p "$bad_windows_adapter_value_dir/profiles/machine" "$bad_windows_adapter_value_dir/consumer-root"
windows_secret_adapter='C:\Users\alice\secret-adapter'
windows_secret_adapter_json="${windows_secret_adapter//\\/\\\\}"

cat >"$bad_windows_adapter_value_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-adapter-value
  name: Bad Windows Adapter Value
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_windows_adapter_value_dir"

cat >"$bad_windows_adapter_value_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-windows-adapter-value-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: $windows_secret_adapter
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

bad_windows_adapter_value_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_windows_adapter_value_dir/skills.registry.yaml" --lock "$bad_windows_adapter_value_dir/skills.lock.yaml" --profile "$bad_windows_adapter_value_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_adapter_value_output" "consumer_roots.codex_user adapter must be a safe non-path identifier"
assert_not_contains "$bad_windows_adapter_value_output" "$windows_secret_adapter_json"

bad_consumer_label_dir="$tmp_dir/bad-consumer-label"
write_skill "$bad_consumer_label_dir/example-skill" "example-skill" "Bad consumer label fixture."
mkdir -p "$bad_consumer_label_dir/profiles/machine" "$bad_consumer_label_dir/consumer-root"
secret_consumer="$bad_consumer_label_dir/secret-consumer"

cat >"$bad_consumer_label_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-consumer-label
  name: Bad Consumer Label
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_consumer_label_dir"

cat >"$bad_consumer_label_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-consumer-label-profile
consumer_roots:
  $secret_consumer:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - $secret_consumer
    state: active
YAML

bad_consumer_label_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_consumer_label_dir/skills.registry.yaml" --lock "$bad_consumer_label_dir/skills.lock.yaml" --profile "$bad_consumer_label_dir/profiles/machine/example.yaml")"
assert_contains "$bad_consumer_label_output" "consumer_roots keys must be safe non-path identifiers"
assert_contains "$bad_consumer_label_output" "example-skill expose_to entries must be safe non-path identifiers"
assert_not_contains "$bad_consumer_label_output" "$secret_consumer"

bad_windows_consumer_label_dir="$tmp_dir/bad-windows-consumer-label"
write_skill "$bad_windows_consumer_label_dir/example-skill" "example-skill" "Bad Windows consumer label fixture."
mkdir -p "$bad_windows_consumer_label_dir/profiles/machine" "$bad_windows_consumer_label_dir/consumer-root"
windows_secret_consumer='\\server\share\secret-consumer'
windows_secret_consumer_json="${windows_secret_consumer//\\/\\\\}"

cat >"$bad_windows_consumer_label_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-consumer-label
  name: Bad Windows Consumer Label
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_windows_consumer_label_dir"

cat >"$bad_windows_consumer_label_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-windows-consumer-label-profile
consumer_roots:
  $windows_secret_consumer:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - $windows_secret_consumer
    state: active
YAML

bad_windows_consumer_label_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_windows_consumer_label_dir/skills.registry.yaml" --lock "$bad_windows_consumer_label_dir/skills.lock.yaml" --profile "$bad_windows_consumer_label_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_consumer_label_output" "consumer_roots keys must be safe non-path identifiers"
assert_contains "$bad_windows_consumer_label_output" "example-skill expose_to entries must be safe non-path identifiers"
assert_not_contains "$bad_windows_consumer_label_output" "$windows_secret_consumer_json"

bad_skill_id_dir="$tmp_dir/bad-skill-id"
mkdir -p "$bad_skill_id_dir/profiles/machine" "$bad_skill_id_dir/consumer-root"
secret_skill_id="$bad_skill_id_dir/secret-skill"

cat >"$bad_skill_id_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bad-skill-id
  name: Bad Skill Id
skills:
  - id: $secret_skill_id
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$bad_skill_id_dir/skills.lock.yaml" <<YAML
schema_version: 0.1
skills:
  - id: $secret_skill_id
    source_type: registry-local
    path: example-skill
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - example-skill
YAML

cat >"$bad_skill_id_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-skill-id-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: $secret_skill_id
    expose_to:
      - codex_user
    state: active
YAML

bad_skill_id_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_skill_id_dir/skills.registry.yaml" --lock "$bad_skill_id_dir/skills.lock.yaml" --profile "$bad_skill_id_dir/profiles/machine/example.yaml")"
assert_contains "$bad_skill_id_output" "skill entry id must be a safe non-path identifier"
assert_contains "$bad_skill_id_output" "lock entries must use safe non-path identifiers"
assert_contains "$bad_skill_id_output" "selected_skills[].skill_id must be a safe non-path identifier"
assert_not_contains "$bad_skill_id_output" "$secret_skill_id"

bad_windows_skill_id_dir="$tmp_dir/bad-windows-skill-id"
mkdir -p "$bad_windows_skill_id_dir/profiles/machine" "$bad_windows_skill_id_dir/consumer-root"
windows_secret_skill_id='C:\Users\alice\secret-skill'
windows_secret_skill_id_json="${windows_secret_skill_id//\\/\\\\}"

cat >"$bad_windows_skill_id_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-skill-id
  name: Bad Windows Skill Id
skills:
  - id: $windows_secret_skill_id
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

cat >"$bad_windows_skill_id_dir/skills.lock.yaml" <<YAML
schema_version: 0.1
skills:
  - id: $windows_secret_skill_id
    source_type: registry-local
    path: example-skill
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - example-skill
YAML

cat >"$bad_windows_skill_id_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-windows-skill-id-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: $windows_secret_skill_id
    expose_to:
      - codex_user
    state: active
YAML

bad_windows_skill_id_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_windows_skill_id_dir/skills.registry.yaml" --lock "$bad_windows_skill_id_dir/skills.lock.yaml" --profile "$bad_windows_skill_id_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_skill_id_output" "skill entry id must be a safe non-path identifier"
assert_contains "$bad_windows_skill_id_output" "lock entries must use safe non-path identifiers"
assert_contains "$bad_windows_skill_id_output" "selected_skills[].skill_id must be a safe non-path identifier"
assert_not_contains "$bad_windows_skill_id_output" "$windows_secret_skill_id_json"

bad_profile_id_dir="$tmp_dir/bad-profile-id"
write_skill "$bad_profile_id_dir/example-skill" "example-skill" "Bad profile id fixture."
mkdir -p "$bad_profile_id_dir/profiles/machine" "$bad_profile_id_dir/consumer-root"
secret_profile_id="$bad_profile_id_dir/secret-profile"

cat >"$bad_profile_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-profile-id
  name: Bad Profile Id
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_profile_id_dir"

cat >"$bad_profile_id_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: $secret_profile_id
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

bad_profile_id_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_profile_id_dir/skills.registry.yaml" --lock "$bad_profile_id_dir/skills.lock.yaml" --profile "$bad_profile_id_dir/profiles/machine/example.yaml")"
assert_contains "$bad_profile_id_output" "profile.id must be a safe non-path identifier"
assert_not_contains "$bad_profile_id_output" "$secret_profile_id"

duplicate_profile_id_dir="$tmp_dir/duplicate-profile-id"
write_skill "$duplicate_profile_id_dir/example-skill" "example-skill" "Duplicate profile id fixture."
mkdir -p "$duplicate_profile_id_dir/profiles/machine" "$duplicate_profile_id_dir/root-a" "$duplicate_profile_id_dir/root-b"

cat >"$duplicate_profile_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: duplicate-profile-id
  name: Duplicate Profile Id
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$duplicate_profile_id_dir"

cat >"$duplicate_profile_id_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: duplicate
consumer_roots:
  codex_user:
    path: ../../root-a
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

cat >"$duplicate_profile_id_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: duplicate
consumer_roots:
  codex_user:
    path: ../../root-b
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

duplicate_profile_id_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$duplicate_profile_id_dir/skills.registry.yaml" --lock "$duplicate_profile_id_dir/skills.lock.yaml" --profile "$duplicate_profile_id_dir/profiles/machine/a.yaml" --profile "$duplicate_profile_id_dir/profiles/machine/b.yaml")"
assert_contains "$duplicate_profile_id_output" "profile.id duplicate duplicates"

bad_windows_profile_id_dir="$tmp_dir/bad-windows-profile-id"
write_skill "$bad_windows_profile_id_dir/example-skill" "example-skill" "Bad Windows profile id fixture."
mkdir -p "$bad_windows_profile_id_dir/profiles/machine" "$bad_windows_profile_id_dir/consumer-root"
windows_secret_profile_id='C:\Users\alice\secret-profile'
windows_secret_profile_id_json="${windows_secret_profile_id//\\/\\\\}"

cat >"$bad_windows_profile_id_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-profile-id
  name: Bad Windows Profile Id
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_windows_profile_id_dir"

cat >"$bad_windows_profile_id_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: $windows_secret_profile_id
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

bad_windows_profile_id_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_windows_profile_id_dir/skills.registry.yaml" --lock "$bad_windows_profile_id_dir/skills.lock.yaml" --profile "$bad_windows_profile_id_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_profile_id_output" "profile.id must be a safe non-path identifier"
assert_not_contains "$bad_windows_profile_id_output" "$windows_secret_profile_id_json"

bad_windows_root_dir="$tmp_dir/bad-windows-root"
write_skill "$bad_windows_root_dir/example-skill" "example-skill" "Bad Windows root fixture."
mkdir -p "$bad_windows_root_dir/profiles/machine"
windows_secret_root='C:\Users\alice\secret-root'
windows_secret_root_json="${windows_secret_root//\\/\\\\}"

cat >"$bad_windows_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-root
  name: Bad Windows Root
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_windows_root_dir"

cat >"$bad_windows_root_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-windows-root-profile
consumer_roots:
  codex_user:
    path: $windows_secret_root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

bad_windows_root_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_windows_root_dir/skills.registry.yaml" --lock "$bad_windows_root_dir/skills.lock.yaml" --profile "$bad_windows_root_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_root_output" "consumer_roots.codex_user path must not be a local Windows path"
assert_not_contains "$bad_windows_root_output" "$windows_secret_root_json"

embedded_windows_root_dir="$tmp_dir/embedded-windows-root"
write_skill "$embedded_windows_root_dir/example-skill" "example-skill" "Embedded Windows root fixture."
mkdir -p "$embedded_windows_root_dir/profiles/machine"
embedded_windows_root='../../C:\Users\alice\secret-root'
embedded_windows_root_json="${embedded_windows_root//\\/\\\\}"

cat >"$embedded_windows_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: embedded-windows-root
  name: Embedded Windows Root
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$embedded_windows_root_dir"

cat >"$embedded_windows_root_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: embedded-windows-root-profile
consumer_roots:
  codex_user:
    path: $embedded_windows_root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

embedded_windows_root_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$embedded_windows_root_dir/skills.registry.yaml" --lock "$embedded_windows_root_dir/skills.lock.yaml" --profile "$embedded_windows_root_dir/profiles/machine/example.yaml")"
assert_contains "$embedded_windows_root_output" "consumer_roots.codex_user path must not be a local Windows path"
assert_not_contains "$embedded_windows_root_output" "$embedded_windows_root_json"

bad_client_status_dir="$tmp_dir/bad-client-status"
write_skill "$bad_client_status_dir/example-skill" "example-skill" "Bad client status fixture."
mkdir -p "$bad_client_status_dir/profiles/machine"
secret_client_status="$bad_client_status_dir/secret-status"

cat >"$bad_client_status_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bad-client-status
  name: Bad Client Status
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
    clients:
      codex: $secret_client_status
YAML

cat >"$bad_client_status_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: example-skill
    source_type: registry-local
    path: example-skill
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - example-skill
YAML

cat >"$bad_client_status_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-client-status-profile
consumer_roots: {}
YAML

bad_client_status_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_client_status_dir/skills.registry.yaml" --lock "$bad_client_status_dir/skills.lock.yaml" --profile "$bad_client_status_dir/profiles/machine/example.yaml")"
assert_contains "$bad_client_status_output" "example-skill: clients values must be safe non-path identifiers"
assert_not_contains "$bad_client_status_output" "$secret_client_status"

bad_selection_state_path_dir="$tmp_dir/bad-selection-state-path"
write_skill "$bad_selection_state_path_dir/example-skill" "example-skill" "Bad selection state path fixture."
mkdir -p "$bad_selection_state_path_dir/profiles/machine" "$bad_selection_state_path_dir/consumer-root"
secret_state="$bad_selection_state_path_dir/secret-state"

cat >"$bad_selection_state_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-selection-state-path
  name: Bad Selection State Path
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_selection_state_path_dir"

cat >"$bad_selection_state_path_dir/profiles/machine/example.yaml" <<YAML
schema_version: 0.1
status: fixture
profile:
  id: bad-selection-state-path-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: pending-$secret_state
YAML

bad_selection_state_path_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_selection_state_path_dir/skills.registry.yaml" --lock "$bad_selection_state_path_dir/skills.lock.yaml" --profile "$bad_selection_state_path_dir/profiles/machine/example.yaml")"
assert_contains "$bad_selection_state_path_output" "example-skill state must be a safe non-path identifier"
assert_not_contains "$bad_selection_state_path_output" "$secret_state"

bad_selection_state_dir="$tmp_dir/bad-selection-state"
write_skill "$bad_selection_state_dir/example-skill" "example-skill" "Bad selection state fixture."
mkdir -p "$bad_selection_state_dir/profiles/machine" "$bad_selection_state_dir/consumer-root"

cat >"$bad_selection_state_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-selection-state
  name: Bad Selection State
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_selection_state_dir"

cat >"$bad_selection_state_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-selection-state-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: []
YAML

bad_selection_state_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_selection_state_dir/skills.registry.yaml" --lock "$bad_selection_state_dir/skills.lock.yaml" --profile "$bad_selection_state_dir/profiles/machine/example.yaml")"
assert_contains "$bad_selection_state_output" "example-skill state must be a string when provided"

external_stale_dir="$tmp_dir/external-stale"
mkdir -p "$external_stale_dir/profiles/machine" "$external_stale_dir/consumer-root" "$external_stale_dir/target-dir"

cat >"$external_stale_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: external-stale
  name: External Stale
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$external_stale_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$external_stale_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: external-stale-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

ln -s "$external_stale_dir/target-dir" "$external_stale_dir/consumer-root/external-skill"
external_stale_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$external_stale_dir/skills.registry.yaml" \
    --lock "$external_stale_dir/skills.lock.yaml" \
    --profile "$external_stale_dir/profiles/machine/example.yaml"
)"
assert_contains "$external_stale_output" "manual-review | blocked | codex_user/external-skill"
assert_contains "$external_stale_output" "maps to an external-git source and is not managed"

exported_outside_registry_dir="$tmp_dir/exported-outside-registry"
write_skill "$exported_outside_registry_dir/example-skill" "example-skill" "Exported outside registry fixture."
mkdir -p "$exported_outside_registry_dir/profiles/machine" "$exported_outside_registry_dir/consumer-root" "$exported_outside_registry_dir/outside-target"

cat >"$exported_outside_registry_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: exported-outside-registry
  name: Exported Outside Registry
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$exported_outside_registry_dir"

cat >"$exported_outside_registry_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: exported-outside-registry-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

ln -s "$exported_outside_registry_dir/outside-target" "$exported_outside_registry_dir/consumer-root/example-skill"
exported_outside_registry_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$exported_outside_registry_dir/skills.registry.yaml" \
    --lock "$exported_outside_registry_dir/skills.lock.yaml" \
    --profile "$exported_outside_registry_dir/profiles/machine/example.yaml"
)"
assert_contains "$exported_outside_registry_output" "manual-review | blocked | codex_user/example-skill"
assert_contains "$exported_outside_registry_output" "registry-named symlink does not point at the expected skill source"

cross_profile_dir="$tmp_dir/cross-profile"
write_skill "$cross_profile_dir/example-skill" "example-skill" "Cross profile fixture."
mkdir -p "$cross_profile_dir/profiles/machine" "$cross_profile_dir/consumer-root"

cat >"$cross_profile_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: cross-profile
  name: Cross Profile
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$cross_profile_dir"

cat >"$cross_profile_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: profile-a
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

cat >"$cross_profile_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: profile-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

ln -s "$cross_profile_dir/example-skill" "$cross_profile_dir/consumer-root/example-skill"
cross_profile_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$cross_profile_dir/skills.registry.yaml" \
    --lock "$cross_profile_dir/skills.lock.yaml"
)"
assert_contains "$cross_profile_output" "keep | ok | codex_user/example-skill"
assert_not_contains "$cross_profile_output" "remove-stale | planned | codex_user/example-skill"

cross_profile_duplicate_dir="$tmp_dir/cross-profile-duplicate"
write_skill "$cross_profile_duplicate_dir/example-skill" "example-skill" "Cross profile duplicate fixture."
mkdir -p "$cross_profile_duplicate_dir/profiles/machine" "$cross_profile_duplicate_dir/consumer-root"

cat >"$cross_profile_duplicate_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: cross-profile-duplicate
  name: Cross Profile Duplicate
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$cross_profile_duplicate_dir"

cat >"$cross_profile_duplicate_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: profile-a
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

cat >"$cross_profile_duplicate_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: profile-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: verify-before-use
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

cross_profile_duplicate_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$cross_profile_duplicate_dir/skills.registry.yaml" --lock "$cross_profile_duplicate_dir/skills.lock.yaml" --profile "$cross_profile_duplicate_dir/profiles/machine/a.yaml" --profile "$cross_profile_duplicate_dir/profiles/machine/b.yaml")"
assert_contains "$cross_profile_duplicate_output" "profile-b maps ./consumer-root/example-skill from example-skill, but profile-a already selects the same target"

shared_desired_conflict_dir="$tmp_dir/shared-desired-conflict"
write_skill "$shared_desired_conflict_dir/skill-a" "skill-a" "Shared desired conflict skill A."
write_skill "$shared_desired_conflict_dir/skill-b" "skill-b" "Shared desired conflict skill B."
mkdir -p "$shared_desired_conflict_dir/profiles/machine" "$shared_desired_conflict_dir/consumer-root"

cat >"$shared_desired_conflict_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: shared-desired-conflict
  name: Shared Desired Conflict
skills:
  - id: skill-a
    status: active
    source:
      type: registry-local
      path: skill-a
    exported_names:
      - skill-a
  - id: skill-b
    status: active
    source:
      type: registry-local
      path: skill-b
    exported_names:
      - skill-b
YAML

write_lock_from_registry "$shared_desired_conflict_dir"

cat >"$shared_desired_conflict_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-desired-conflict-a
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: skill-a
    expose_to:
      - codex_user
    state: active
YAML

cat >"$shared_desired_conflict_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-desired-conflict-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: verify-before-use
selected_skills:
  - skill_id: skill-b
    expose_to:
      - codex_user
    state: active
YAML

shared_desired_conflict_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$shared_desired_conflict_dir/skills.registry.yaml" \
    --lock "$shared_desired_conflict_dir/skills.lock.yaml" \
    --profile "$shared_desired_conflict_dir/profiles/machine/a.yaml" \
    --profile "$shared_desired_conflict_dir/profiles/machine/b.yaml"
)"
assert_contains "$shared_desired_conflict_output" "manual-review | blocked | codex_user/skill-a"
assert_contains "$shared_desired_conflict_output" "consumer root is shared across loaded profiles with unsupported or conflicting adapters (shared-desired-conflict-a=symlink, shared-desired-conflict-b=verify-before-use)"
assert_contains "$shared_desired_conflict_output" "blocked | blocked | codex_user/skill-b"
assert_not_contains "$shared_desired_conflict_output" "create | planned | codex_user/skill-a"

shared_stale_root_dir="$tmp_dir/shared-stale-root"
write_skill "$shared_stale_root_dir/stale-skill" "stale-skill" "Shared stale root fixture."
mkdir -p "$shared_stale_root_dir/profiles/machine" "$shared_stale_root_dir/consumer-root"

cat >"$shared_stale_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: shared-stale-root
  name: Shared Stale Root
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
YAML

write_lock_from_registry "$shared_stale_root_dir"

cat >"$shared_stale_root_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-root-a
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

cat >"$shared_stale_root_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-root-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

ln -s "$shared_stale_root_dir/stale-skill" "$shared_stale_root_dir/consumer-root/stale-skill"
shared_stale_root_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$shared_stale_root_dir/skills.registry.yaml" \
    --lock "$shared_stale_root_dir/skills.lock.yaml" \
    --profile "$shared_stale_root_dir/profiles/machine/a.yaml" \
    --profile "$shared_stale_root_dir/profiles/machine/b.yaml"
)"
assert_occurrences "$shared_stale_root_output" "remove-stale | planned | codex_user/stale-skill" 1

shared_stale_conflict_dir="$tmp_dir/shared-stale-conflict"
write_skill "$shared_stale_conflict_dir/stale-skill" "stale-skill" "Shared stale conflict fixture."
mkdir -p "$shared_stale_conflict_dir/profiles/machine" "$shared_stale_conflict_dir/consumer-root"

cat >"$shared_stale_conflict_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: shared-stale-conflict
  name: Shared Stale Conflict
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
YAML

write_lock_from_registry "$shared_stale_conflict_dir"

cat >"$shared_stale_conflict_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-conflict-a
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

cat >"$shared_stale_conflict_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-conflict-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: verify-before-use
YAML

ln -s "$shared_stale_conflict_dir/stale-skill" "$shared_stale_conflict_dir/consumer-root/stale-skill"
shared_stale_conflict_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$shared_stale_conflict_dir/skills.registry.yaml" \
    --lock "$shared_stale_conflict_dir/skills.lock.yaml" \
    --profile "$shared_stale_conflict_dir/profiles/machine/a.yaml" \
    --profile "$shared_stale_conflict_dir/profiles/machine/b.yaml"
)"
assert_occurrences "$shared_stale_conflict_output" "manual-review | blocked | codex_user/stale-skill" 1
assert_contains "$shared_stale_conflict_output" "unsupported or conflicting adapters (shared-stale-conflict-a=symlink, shared-stale-conflict-b=verify-before-use)"
assert_not_contains "$shared_stale_conflict_output" "remove-stale | planned | codex_user/stale-skill"

shared_stale_symlink_conflict_dir="$tmp_dir/shared-stale-symlink-conflict"
write_skill "$shared_stale_symlink_conflict_dir/stale-skill" "stale-skill" "Shared stale symlink conflict fixture."
mkdir -p "$shared_stale_symlink_conflict_dir/profiles/machine" "$shared_stale_symlink_conflict_dir/consumer-root"
ln -s "$shared_stale_symlink_conflict_dir/consumer-root" "$shared_stale_symlink_conflict_dir/symlink-consumer-root"

cat >"$shared_stale_symlink_conflict_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: shared-stale-symlink-conflict
  name: Shared Stale Symlink Conflict
skills:
  - id: stale-skill
    status: active
    source:
      type: registry-local
      path: stale-skill
    exported_names:
      - stale-skill
YAML

write_lock_from_registry "$shared_stale_symlink_conflict_dir"

cat >"$shared_stale_symlink_conflict_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-symlink-conflict-a
consumer_roots:
  codex_user:
    path: ../../symlink-consumer-root
    adapter: symlink
YAML

cat >"$shared_stale_symlink_conflict_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-symlink-conflict-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: verify-before-use
YAML

ln -s "$shared_stale_symlink_conflict_dir/stale-skill" "$shared_stale_symlink_conflict_dir/consumer-root/stale-skill"
shared_stale_symlink_conflict_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$shared_stale_symlink_conflict_dir/skills.registry.yaml" \
    --lock "$shared_stale_symlink_conflict_dir/skills.lock.yaml" \
    --profile "$shared_stale_symlink_conflict_dir/profiles/machine/a.yaml" \
    --profile "$shared_stale_symlink_conflict_dir/profiles/machine/b.yaml"
)"
assert_occurrences "$shared_stale_symlink_conflict_output" "manual-review | blocked | codex_user/stale-skill" 1
assert_contains "$shared_stale_symlink_conflict_output" "unsupported or conflicting adapters (shared-stale-symlink-conflict-a=symlink, shared-stale-symlink-conflict-b=verify-before-use)"
assert_not_contains "$shared_stale_symlink_conflict_output" "remove-stale | planned | codex_user/stale-skill"

shared_stale_blocked_rename_dir="$tmp_dir/shared-stale-blocked-rename"
write_skill "$shared_stale_blocked_rename_dir/example-skill" "new-name" "Shared stale blocked rename fixture."
mkdir -p "$shared_stale_blocked_rename_dir/profiles/machine" "$shared_stale_blocked_rename_dir/consumer-root"

cat >"$shared_stale_blocked_rename_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: shared-stale-blocked-rename
  name: Shared Stale Blocked Rename
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - new-name
YAML

write_lock_from_registry "$shared_stale_blocked_rename_dir"

cat >"$shared_stale_blocked_rename_dir/profiles/machine/a.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-blocked-rename-a
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

cat >"$shared_stale_blocked_rename_dir/profiles/machine/b.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: shared-stale-blocked-rename-b
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: pending-review
YAML

ln -s "$shared_stale_blocked_rename_dir/example-skill" "$shared_stale_blocked_rename_dir/consumer-root/old-name"
shared_stale_blocked_rename_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$shared_stale_blocked_rename_dir/skills.registry.yaml" \
    --lock "$shared_stale_blocked_rename_dir/skills.lock.yaml" \
    --profile "$shared_stale_blocked_rename_dir/profiles/machine/a.yaml" \
    --profile "$shared_stale_blocked_rename_dir/profiles/machine/b.yaml"
)"
assert_contains "$shared_stale_blocked_rename_output" "manual-review | blocked | codex_user/old-name"
assert_contains "$shared_stale_blocked_rename_output" "selected skill state is pending-review, so stale adapter rename requires manual review"
assert_not_contains "$shared_stale_blocked_rename_output" "remove-stale | planned | codex_user/old-name"

unrelated_broken_symlink_dir="$tmp_dir/unrelated-broken-symlink"
write_skill "$unrelated_broken_symlink_dir/example-skill" "example-skill" "Unrelated broken symlink fixture."
mkdir -p "$unrelated_broken_symlink_dir/profiles/machine" "$unrelated_broken_symlink_dir/consumer-root"

cat >"$unrelated_broken_symlink_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unrelated-broken-symlink
  name: Unrelated Broken Symlink
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$unrelated_broken_symlink_dir"

cat >"$unrelated_broken_symlink_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unrelated-broken-symlink-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

ln -s "$unrelated_broken_symlink_dir/missing-target" "$unrelated_broken_symlink_dir/consumer-root/unrelated-skill"
unrelated_broken_symlink_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$unrelated_broken_symlink_dir/skills.registry.yaml" \
    --lock "$unrelated_broken_symlink_dir/skills.lock.yaml" \
    --profile "$unrelated_broken_symlink_dir/profiles/machine/example.yaml"
)"
assert_contains "$unrelated_broken_symlink_output" "- no adapter actions"
assert_not_contains "$unrelated_broken_symlink_output" "unrelated-skill"

bad_control_url_dir="$tmp_dir/bad-control-url"
mkdir -p "$bad_control_url_dir/profiles/machine"

cat >"$bad_control_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-control-url
  name: Bad Control Url
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: "bad\0url"
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_control_url_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: "bad\0url"
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_control_url_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-control-url-profile
consumer_roots: {}
YAML

bad_control_url_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_control_url_dir/skills.registry.yaml" --lock "$bad_control_url_dir/skills.lock.yaml" --profile "$bad_control_url_dir/profiles/machine/example.yaml")"
assert_contains "$bad_control_url_output" "external-skill: external-git source.url must not contain control characters"
assert_not_contains "$bad_control_url_output" "ArgumentError"

bad_windows_url_dir="$tmp_dir/bad-windows-url"
mkdir -p "$bad_windows_url_dir/profiles/machine"

cat >"$bad_windows_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-url
  name: Bad Windows URL
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: C:/Users/alice/skill.git
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_windows_url_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: C:/Users/alice/skill.git
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_windows_url_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-windows-url-profile
consumer_roots: {}
YAML

bad_windows_url_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_windows_url_dir/skills.registry.yaml" --lock "$bad_windows_url_dir/skills.lock.yaml" --profile "$bad_windows_url_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_url_output" "external-skill: external-git source.url must not be a local Windows path"

bad_windows_source_path_dir="$tmp_dir/bad-windows-source-path"
mkdir -p "$bad_windows_source_path_dir/profiles/machine"

cat >"$bad_windows_source_path_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-windows-source-path
  name: Bad Windows Source Path
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: C:\Users\alice\skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_windows_source_path_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: C:\Users\alice\skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_windows_source_path_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-windows-source-path-profile
consumer_roots: {}
YAML

bad_windows_source_path_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_windows_source_path_dir/skills.registry.yaml" --lock "$bad_windows_source_path_dir/skills.lock.yaml" --profile "$bad_windows_source_path_dir/profiles/machine/example.yaml")"
assert_contains "$bad_windows_source_path_output" "external-skill: external-git source.path must be a safe relative path"

bad_query_url_dir="$tmp_dir/bad-query-url"
mkdir -p "$bad_query_url_dir/profiles/machine"
secret_query_token="access_token=secret"

cat >"$bad_query_url_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bad-query-url
  name: Bad Query URL
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: "https://example.com/org/repo.git?$secret_query_token#frag"
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_query_url_dir/skills.lock.yaml" <<YAML
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: "https://example.com/org/repo.git?$secret_query_token#frag"
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_query_url_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-query-url-profile
consumer_roots: {}
YAML

bad_query_url_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_query_url_dir/skills.registry.yaml" --lock "$bad_query_url_dir/skills.lock.yaml" --profile "$bad_query_url_dir/profiles/machine/example.yaml")"
assert_contains "$bad_query_url_output" "external-skill: external-git source.url must not include a query or fragment"
assert_not_contains "$bad_query_url_output" "$secret_query_token"

spaced_lock_dir="$tmp_dir/spaced-lock"
write_skill "$spaced_lock_dir/example-skill" "example-skill" "Spaced lock fixture."
mkdir -p "$spaced_lock_dir/profiles/machine" "$spaced_lock_dir/consumer-root"
spaced_lock_path="$tmp_dir/sync space/lock dir"
mkdir -p "$spaced_lock_path"

cat >"$spaced_lock_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: spaced-lock
  name: Spaced Lock
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

cat >"$spaced_lock_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: spaced-lock-profile
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

spaced_lock_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$spaced_lock_dir/skills.registry.yaml" --lock "$spaced_lock_path" --profile "$spaced_lock_dir/profiles/machine/example.yaml")"
assert_contains "$spaced_lock_output" "could not be read"
assert_not_contains "$spaced_lock_output" "sync space"
assert_not_contains "$spaced_lock_output" "lock dir"

bad_source_type_dir="$tmp_dir/bad-source-type"
mkdir -p "$bad_source_type_dir/profiles/machine"
secret_source_type="$bad_source_type_dir/secret-source-type"

cat >"$bad_source_type_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bad-source-type
  name: Bad Source Type
skills:
  - id: example-skill
    status: active
    source:
      type: $secret_source_type
    exported_names:
      - example-skill
YAML

cat >"$bad_source_type_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills: []
YAML

cat >"$bad_source_type_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-source-type-profile
consumer_roots: {}
YAML

bad_source_type_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_source_type_dir/skills.registry.yaml" --lock "$bad_source_type_dir/skills.lock.yaml" --profile "$bad_source_type_dir/profiles/machine/example.yaml")"
assert_contains "$bad_source_type_output" "example-skill: unsupported source.type"
assert_not_contains "$bad_source_type_output" "$secret_source_type"

bad_scp_credential_url_dir="$tmp_dir/bad-scp-credential-url"
mkdir -p "$bad_scp_credential_url_dir/profiles/machine"

cat >"$bad_scp_credential_url_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: bad-scp-credential-url
  name: Bad Scp Credential Url
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: user:token@example.com:org/repo.git
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_scp_credential_url_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: user:token@example.com:org/repo.git
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_scp_credential_url_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-scp-credential-url-profile
consumer_roots: {}
YAML

bad_scp_credential_url_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_scp_credential_url_dir/skills.registry.yaml" --lock "$bad_scp_credential_url_dir/skills.lock.yaml" --profile "$bad_scp_credential_url_dir/profiles/machine/example.yaml")"
assert_contains "$bad_scp_credential_url_output" "external-skill: external-git source.url must not include credentials"

bad_scp_query_url_dir="$tmp_dir/bad-scp-query-url"
mkdir -p "$bad_scp_query_url_dir/profiles/machine"
secret_scp_query_token="access_token=secret"

cat >"$bad_scp_query_url_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: bad-scp-query-url
  name: Bad Scp Query Url
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: "git@example.com:org/repo.git?$secret_scp_query_token#frag"
      path: skill-dir
      pinned_tag: 1.0.0
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_scp_query_url_dir/skills.lock.yaml" <<YAML
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: "git@example.com:org/repo.git?$secret_scp_query_token#frag"
    path: skill-dir
    pinned_tag: 1.0.0
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$bad_scp_query_url_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-scp-query-url-profile
consumer_roots: {}
YAML

bad_scp_query_url_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$bad_scp_query_url_dir/skills.registry.yaml" --lock "$bad_scp_query_url_dir/skills.lock.yaml" --profile "$bad_scp_query_url_dir/profiles/machine/example.yaml")"
assert_contains "$bad_scp_query_url_output" "external-skill: external-git source.url must not include a query or fragment"
assert_not_contains "$bad_scp_query_url_output" "$secret_scp_query_token"

redacted_tag_summary_dir="$tmp_dir/redacted-tag-summary"
mkdir -p "$redacted_tag_summary_dir/profiles/machine" "$redacted_tag_summary_dir/consumer-root"
secret_tag_path="/tmp/secret-tag-path"

cat >"$redacted_tag_summary_dir/skills.registry.yaml" <<YAML
schema_version: 0.1
status: fixture
registry:
  id: redacted-tag-summary
  name: Redacted Tag Summary
skills:
  - id: external-skill
    status: active
    source:
      type: external-git
      url: https://example.com/example/skill.git
      path: skill-dir
      pinned_tag: "v-$secret_tag_path"
      observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
    clients:
      codex: supported
YAML

cat >"$redacted_tag_summary_dir/skills.lock.yaml" <<YAML
schema_version: 0.1
skills:
  - id: external-skill
    source_type: external-git
    url: https://example.com/example/skill.git
    path: skill-dir
    pinned_tag: "v-$secret_tag_path"
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML

cat >"$redacted_tag_summary_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: redacted-tag-summary-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
selected_skills:
  - skill_id: external-skill
    expose_to:
      - codex_user
    state: active
YAML

redacted_tag_summary_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --json \
    --registry "$redacted_tag_summary_dir/skills.registry.yaml" \
    --lock "$redacted_tag_summary_dir/skills.lock.yaml" \
    --profile "$redacted_tag_summary_dir/profiles/machine/example.yaml"
)"
SECRET_TAG_PATH="$secret_tag_path" ruby -rjson -e '
  parsed = JSON.parse(ARGF.read)
  action = parsed.fetch("actions").find { |item| item["skill_id"] == "external-skill" }
  raise "missing external action" unless action
  raise "lock summary leaked local tag path" if action.fetch("lock").include?(ENV.fetch("SECRET_TAG_PATH"))
  raise "expected redacted tag summary" unless action.fetch("lock").include?("tag:v-<absolute-path>")
' <<<"$redacted_tag_summary_output"

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

obstructed_root_dir="$tmp_dir/obstructed-root"
write_skill "$obstructed_root_dir/example-skill" "example-skill" "Obstructed root fixture."
mkdir -p "$obstructed_root_dir/profiles/machine"
printf 'not a directory\n' >"$obstructed_root_dir/blocked-parent"

cat >"$obstructed_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: obstructed-root
  name: Obstructed Root
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$obstructed_root_dir"

cat >"$obstructed_root_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: obstructed-root-profile
consumer_roots:
  codex_user:
    path: ../../blocked-parent/skills
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

obstructed_root_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$obstructed_root_dir/skills.registry.yaml" \
    --lock "$obstructed_root_dir/skills.lock.yaml" \
    --profile "$obstructed_root_dir/profiles/machine/example.yaml"
)"
assert_contains "$obstructed_root_output" "blocked | blocked | codex_user/example-skill"
assert_contains "$obstructed_root_output" "consumer root is obstructed by ancestor ./blocked-parent that is not a directory"

broken_root_symlink_dir="$tmp_dir/broken-root-symlink"
write_skill "$broken_root_symlink_dir/example-skill" "example-skill" "Broken root symlink fixture."
mkdir -p "$broken_root_symlink_dir/profiles/machine"
ln -s "$broken_root_symlink_dir/does-not-exist" "$broken_root_symlink_dir/broken-consumer-root"

cat >"$broken_root_symlink_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: broken-root-symlink
  name: Broken Root Symlink
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$broken_root_symlink_dir"

cat >"$broken_root_symlink_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: broken-root-symlink-profile
consumer_roots:
  codex_user:
    path: ../../broken-consumer-root
    adapter: symlink
    status: planned
selected_skills:
  - skill_id: example-skill
    expose_to:
      - codex_user
    state: active
YAML

broken_root_symlink_output="$(
  ruby "$repo_root/scripts/skills_sync.rb" \
    --plan \
    --registry "$broken_root_symlink_dir/skills.registry.yaml" \
    --lock "$broken_root_symlink_dir/skills.lock.yaml" \
    --profile "$broken_root_symlink_dir/profiles/machine/example.yaml"
)"
assert_contains "$broken_root_symlink_output" "blocked | blocked | codex_user/example-skill"
assert_contains "$broken_root_symlink_output" "consumer root exists but is not a directory"

if [[ "$(id -u)" -ne 0 ]]; then
  unreadable_root_dir="$tmp_dir/unreadable-root"
  write_skill "$unreadable_root_dir/example-skill" "example-skill" "Unreadable root fixture."
  mkdir -p "$unreadable_root_dir/profiles/machine" "$unreadable_root_dir/consumer-root"

  cat >"$unreadable_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unreadable-root
  name: Unreadable Root
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

  write_lock_from_registry "$unreadable_root_dir"

  cat >"$unreadable_root_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unreadable-root-profile
consumer_roots:
  codex_user:
    path: ../../consumer-root
    adapter: symlink
YAML

  chmod 000 "$unreadable_root_dir/consumer-root"
  unreadable_root_output="$(
    ruby "$repo_root/scripts/skills_sync.rb" \
      --plan \
      --registry "$unreadable_root_dir/skills.registry.yaml" \
      --lock "$unreadable_root_dir/skills.lock.yaml" \
      --profile "$unreadable_root_dir/profiles/machine/example.yaml"
  )"
  chmod 755 "$unreadable_root_dir/consumer-root"
  assert_contains "$unreadable_root_output" "manual-review | blocked | codex_user/*"
  assert_contains "$unreadable_root_output" "target=./consumer-root"
  assert_contains "$unreadable_root_output" "could not inspect consumer root"

  unreadable_selected_root_dir="$tmp_dir/unreadable-selected-root"
  write_skill "$unreadable_selected_root_dir/example-skill" "example-skill" "Unreadable selected root fixture."
  mkdir -p "$unreadable_selected_root_dir/profiles/machine" "$unreadable_selected_root_dir/consumer-root"

  cat >"$unreadable_selected_root_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: unreadable-selected-root
  name: Unreadable Selected Root
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

  write_lock_from_registry "$unreadable_selected_root_dir"

  cat >"$unreadable_selected_root_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: unreadable-selected-root-profile
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

  chmod 000 "$unreadable_selected_root_dir/consumer-root"
  unreadable_selected_root_output="$(
    ruby "$repo_root/scripts/skills_sync.rb" \
      --plan \
      --registry "$unreadable_selected_root_dir/skills.registry.yaml" \
      --lock "$unreadable_selected_root_dir/skills.lock.yaml" \
      --profile "$unreadable_selected_root_dir/profiles/machine/example.yaml"
  )"
  chmod 755 "$unreadable_selected_root_dir/consumer-root"
  assert_contains "$unreadable_selected_root_output" "manual-review | blocked | codex_user/example-skill"
  assert_contains "$unreadable_selected_root_output" "could not inspect consumer root"
  assert_not_contains "$unreadable_selected_root_output" "create | planned | codex_user/example-skill"
fi

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

empty_registry_dir="$tmp_dir/empty-registry"
mkdir -p "$empty_registry_dir"

cat >"$empty_registry_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: empty-registry
  name: Empty Registry
skills: []
YAML

cat >"$empty_registry_dir/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills: []
YAML

empty_registry_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$empty_registry_dir/skills.registry.yaml" --lock "$empty_registry_dir/skills.lock.yaml")"
assert_contains "$empty_registry_output" "skills must be a non-empty array"

missing_profiles_dir="$tmp_dir/missing-profiles"
write_skill "$missing_profiles_dir/example-skill" "example-skill" "Missing profiles fixture."

cat >"$missing_profiles_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: missing-profiles
  name: Missing Profiles
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$missing_profiles_dir"

missing_profiles_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --json --registry "$missing_profiles_dir/skills.registry.yaml" --lock "$missing_profiles_dir/skills.lock.yaml")"
assert_contains "$missing_profiles_output" "at least one profile YAML must be loaded; pass --profile or add files under profiles/"

bad_registry_metadata_dir="$tmp_dir/bad-registry-metadata"
write_skill "$bad_registry_metadata_dir/example-skill" "example-skill" "Bad registry metadata fixture."
mkdir -p "$bad_registry_metadata_dir/profiles/machine"

cat >"$bad_registry_metadata_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: valid-registry
  name: Valid Registry
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

write_lock_from_registry "$bad_registry_metadata_dir"

cat >"$bad_registry_metadata_dir/profiles/machine/example.yaml" <<'YAML'
schema_version: 0.1
status: fixture
profile:
  id: bad-registry-metadata-profile
consumer_roots: {}
YAML

cat >"$bad_registry_metadata_dir/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: fixture
registry:
  id: []
  name: 1
skills:
  - id: example-skill
    status: active
    source:
      type: registry-local
      path: example-skill
    exported_names:
      - example-skill
YAML

bad_registry_metadata_output="$(expect_failure ruby "$repo_root/scripts/skills_sync.rb" --plan --registry "$bad_registry_metadata_dir/skills.registry.yaml" --lock "$bad_registry_metadata_dir/skills.lock.yaml" --profile "$bad_registry_metadata_dir/profiles/machine/example.yaml")"
assert_contains "$bad_registry_metadata_output" "registry.id must be a string"
assert_contains "$bad_registry_metadata_output" "registry.name must be a string"

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
