#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/example-skill" "$tmp_dir/profiles/machine"

cat >"$tmp_dir/example-skill/SKILL.md" <<'SKILL'
---
name: example-skill
description: Example fixture skill.
---

# Example Skill
SKILL

cat >"$tmp_dir/skills.registry.yaml" <<'YAML'
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

cat >"$tmp_dir/profiles/machine/example.yaml" <<'YAML'
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

output="$(
  PROJECTS_ROOT="$tmp_dir/projects" \
    ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$tmp_dir/skills.registry.yaml" \
    --profile "$tmp_dir/profiles/machine/example.yaml" \
    --projects-root "$tmp_dir/projects"
)"

printf '%s\n' "$output" | grep -q "fixture-profile: 1 selected skills, 1 consumer roots"
printf '%s\n' "$output" | grep -q "example-skill: registry-local example-skill digest"

lock_output="$(
  ruby "$repo_root/scripts/skills_doctor.rb" \
    --registry "$tmp_dir/skills.registry.yaml" \
    --print-lock
)"

printf '%s\n' "$lock_output" | grep -q "generated_by: scripts/skills_doctor.rb --print-lock"
printf '%s\n' "$lock_output" | grep -q "digest_sha256:"

echo "skills_doctor test ok"
