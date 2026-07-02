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

write_ok_fixture() {
  local root="$1"

  mkdir -p "$root/docs"
  write_skill "$root/example-skill" "example-skill" "Example fixture skill."

  cat >"$root/skills.registry.yaml" <<'YAML'
schema_version: 0.1
status: active-partial
registry:
  id: fixture-skills
  name: Fixture Skills
  manager_source: fixture/skills
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
      claude: planned
    scopes:
      - machine
      - repo
    update_policy: internal-reviewed
  - id: external-skill
    status: needs-import-review
    source:
      type: external-git
      url: https://github.com/example/agent-skill.git
      path: external-skill
      pinned_tag: 1.2.3
      observed_commit: "1111111111111111111111111111111111111111"
      observed_at: "2026-07-02"
    exported_names:
      - external-skill
    clients:
      codex: planned
      claude: planned
    scopes:
      - machine
      - repo
    update_policy: external-reviewed
    catalog:
      description: External fixture skill awaiting import review.
YAML

  cat >"$root/skills.lock.yaml" <<'YAML'
schema_version: 0.1
skills:
  - id: example-skill
    source_type: registry-local
    path: example-skill
    digest_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exported_names:
      - example-skill
  - id: external-skill
    source_type: external-git
    url: https://github.com/example/agent-skill.git
    path: external-skill
    pinned_tag: 1.2.3
    observed_commit: "1111111111111111111111111111111111111111"
    exported_names:
      - external-skill
YAML
}

run_catalog() {
  local root="$1"
  shift

  ruby "$repo_root/scripts/skills_catalog.rb" \
    --registry "$root/skills.registry.yaml" \
    --lock "$root/skills.lock.yaml" \
    --json-output "$root/skills.catalog.json" \
    --markdown-output "$root/docs/skills-catalog.md" \
    "$@"
}

ok_dir="$tmp_dir/ok"
write_ok_fixture "$ok_dir"
run_catalog "$ok_dir" --write
run_catalog "$ok_dir" --check

json_output="$(run_catalog "$ok_dir" --json)"
assert_contains "$json_output" '"id": "example-skill"'
assert_contains "$json_output" '"description": "Example fixture skill."'
assert_contains "$json_output" '"codex_global_command": "npx --yes skills@1.5.14 add fixture/skills --skill example-skill --agent codex --global --yes"'
assert_contains "$json_output" '"id": "external-skill"'
assert_contains "$json_output" '"pinned_tag": "1.2.3"'

markdown_output="$(run_catalog "$ok_dir" --markdown)"
assert_contains "$markdown_output" "# Skills Catalog"
assert_contains "$markdown_output" "## Registry-Covered Skills"
assert_contains "$markdown_output" "## Installable Active Skills"

ruby -rjson -e '
  parsed = JSON.parse(File.read(ARGV.fetch(0)))
  raise "wrong schema" unless parsed.fetch("schema_version") == "0.1"
  raise "wrong skill count" unless parsed.fetch("skills").length == 2
  external = parsed.fetch("skills").find { |skill| skill.fetch("id") == "external-skill" }
  raise "external should not emit install command" if external.key?("install")
' "$ok_dir/skills.catalog.json"

ruby -e '
  path = ARGV.fetch(0)
  text = File.read(path).sub("description: Example fixture skill.", "description: Changed fixture skill.")
  File.write(path, text)
' "$ok_dir/example-skill/SKILL.md"
drift_output="$(expect_failure run_catalog "$ok_dir" --check)"
assert_contains "$drift_output" "catalog drift"

missing_description_dir="$tmp_dir/missing-description"
write_ok_fixture "$missing_description_dir"
ruby -ryaml -e '
  path = ARGV.fetch(0)
  data = YAML.safe_load(File.read(path), aliases: false)
  data.fetch("skills").find { |skill| skill.fetch("id") == "external-skill" }.delete("catalog")
  File.write(path, data.to_yaml)
' "$missing_description_dir/skills.registry.yaml"
missing_description_output="$(expect_failure run_catalog "$missing_description_dir" --json)"
assert_contains "$missing_description_output" "external-skill: catalog description is required"

unpinned_dir="$tmp_dir/unpinned"
write_ok_fixture "$unpinned_dir"
ruby -ryaml -e '
  path = ARGV.fetch(0)
  data = YAML.safe_load(File.read(path), aliases: false)
  source = data.fetch("skills").find { |skill| skill.fetch("id") == "external-skill" }.fetch("source")
  source.delete("pinned_tag")
  File.write(path, data.to_yaml)
' "$unpinned_dir/skills.registry.yaml"
unpinned_output="$(expect_failure run_catalog "$unpinned_dir" --json)"
assert_contains "$unpinned_output" "external-skill: external-git source.pinned_tag is required"

private_path_dir="$tmp_dir/private-path"
write_ok_fixture "$private_path_dir"
ruby -ryaml -e '
  path = ARGV.fetch(0)
  data = YAML.safe_load(File.read(path), aliases: false)
  source = data.fetch("skills").find { |skill| skill.fetch("id") == "external-skill" }.fetch("source")
  source["url"] = "file:///Users/alice/private-skill"
  File.write(path, data.to_yaml)
' "$private_path_dir/skills.registry.yaml"
private_path_output="$(expect_failure run_catalog "$private_path_dir" --json)"
assert_contains "$private_path_output" "external-skill: external-git source.url must be a public, credential-free URL"

unsafe_description_dir="$tmp_dir/unsafe-description"
write_ok_fixture "$unsafe_description_dir"
ruby -e '
  path = ARGV.fetch(0)
  text = File.read(path).sub("description: Example fixture skill.", "description: Uses /Users/alice/private.")
  File.write(path, text)
' "$unsafe_description_dir/example-skill/SKILL.md"
unsafe_description_output="$(expect_failure run_catalog "$unsafe_description_dir" --json)"
assert_contains "$unsafe_description_output" "generated catalog JSON contains macOS user path"

echo "skills_catalog test ok"
