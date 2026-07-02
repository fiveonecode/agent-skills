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

fake_openai_key() {
  printf 'sk-%024d\n' 0
}

public_safety_cmd="$(
  ruby -ryaml -e '
    config = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
    command = config.fetch("commands").find { |entry| entry.fetch("id") == "public-safety-docs" }
    puts command.fetch("run")
  ' "$repo_root/.agents/verify/skills-registry.yaml"
)"

registry_yaml_cmd="$(
  ruby -ryaml -e '
    config = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
    command = config.fetch("commands").find { |entry| entry.fetch("id") == "registry-yaml" }
    puts command.fetch("run")
  ' "$repo_root/.agents/verify/skills-registry.yaml"
)"

run_public_safety() {
  local fixture_root="$1"

  (
    cd "$fixture_root"
    eval "$public_safety_cmd"
  )
}

run_registry_yaml() {
  local fixture_root="$1"

  (
    cd "$fixture_root"
    eval "$registry_yaml_cmd"
  )
}

write_fixture_repo() {
  local root="$1"

  mkdir -p \
    "$root/.agents/manifests" \
    "$root/.agents/verify" \
    "$root/docs" \
    "$root/example-skill/assets" \
    "$root/profiles/machine" \
    "$root/scripts"

  cat >"$root/AGENTS.md" <<'EOF'
# Fixture
EOF

  cat >"$root/README.md" <<'EOF'
# Fixture
EOF

  cat >"$root/skills.lock.yaml" <<'EOF'
schema_version: 0.1
locks: []
EOF

  cat >"$root/skills.registry.yaml" <<'EOF'
schema_version: 0.1
skills: []
EOF

  cat >"$root/.agents/verify/skills-registry.yaml" <<'EOF'
id: fixture
commands: []
EOF

  cat >"$root/.agents/manifests/registry.yaml" <<'EOF'
id: fixture
globs: []
EOF

  cat >"$root/profiles/machine/example.yaml" <<'EOF'
schema_version: 0.1
profile:
  id: fixture
EOF

  cat >"$root/scripts/example.sh" <<'EOF'
#!/usr/bin/env bash
echo fixture
EOF

  cat >"$root/example-skill/SKILL.md" <<'EOF'
---
name: example-skill
description: Fixture skill.
---

# Example Skill
EOF

  cat >"$root/docs/guide.md" <<'EOF'
# Fixture Docs
EOF
}

ok_dir="$tmp_dir/ok"
write_fixture_repo "$ok_dir"
ok_registry_output="$(run_registry_yaml "$ok_dir")"
assert_contains "$ok_registry_output" "registry YAML parsed"
ok_output="$(run_public_safety "$ok_dir")"
assert_contains "$ok_output" "public-safety scan ok"

invalid_agents_manifest_dir="$tmp_dir/invalid-agents-manifest"
cp -R "$ok_dir/." "$invalid_agents_manifest_dir/"
cat >"$invalid_agents_manifest_dir/.agents/manifests/registry.yaml" <<'EOF'
id: [
EOF
invalid_agents_manifest_output="$(expect_failure run_registry_yaml "$invalid_agents_manifest_dir")"
assert_contains "$invalid_agents_manifest_output" ".agents/manifests/registry.yaml"

gitignore_leak_dir="$tmp_dir/gitignore-leak"
cp -R "$ok_dir/." "$gitignore_leak_dir/"
printf 'token=%s\n' "$(fake_openai_key)" >"$gitignore_leak_dir/.gitignore"
gitignore_leak_output="$(expect_failure run_public_safety "$gitignore_leak_dir")"
assert_contains "$gitignore_leak_output" ".gitignore: OpenAI key"

docs_leak_dir="$tmp_dir/docs-leak"
cp -R "$ok_dir/." "$docs_leak_dir/"
printf 'token=%s\n' "$(fake_openai_key)" >"$docs_leak_dir/docs/leak.txt"
docs_leak_output="$(expect_failure run_public_safety "$docs_leak_dir")"
assert_contains "$docs_leak_output" "docs/leak.txt: OpenAI key"

profile_artifact_leak_dir="$tmp_dir/profile-artifact-leak"
cp -R "$ok_dir/." "$profile_artifact_leak_dir/"
printf 'token=%s\n' "$(fake_openai_key)" >"$profile_artifact_leak_dir/profiles/.env"
profile_artifact_output="$(expect_failure run_public_safety "$profile_artifact_leak_dir")"
assert_contains "$profile_artifact_output" "profiles/.env: OpenAI key"

aws_leak_dir="$tmp_dir/aws-leak"
cp -R "$ok_dir/." "$aws_leak_dir/"
printf '%s\n' 'aws_access_key_id = AKIA1234567890ABCDEF' >"$aws_leak_dir/docs/aws.txt"
aws_leak_output="$(expect_failure run_public_safety "$aws_leak_dir")"
assert_contains "$aws_leak_output" "docs/aws.txt: AWS access key"

bearer_leak_dir="$tmp_dir/bearer-leak"
cp -R "$ok_dir/." "$bearer_leak_dir/"
printf '%s\n' 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9' >"$bearer_leak_dir/docs/bearer.txt"
bearer_leak_output="$(expect_failure run_public_safety "$bearer_leak_dir")"
assert_contains "$bearer_leak_output" "docs/bearer.txt: Bearer token"

hidden_skill_leak_dir="$tmp_dir/hidden-skill-leak"
cp -R "$ok_dir/." "$hidden_skill_leak_dir/"
printf 'token=%s\n' "$(fake_openai_key)" >"$hidden_skill_leak_dir/example-skill/assets/.env"
hidden_skill_output="$(expect_failure run_public_safety "$hidden_skill_leak_dir")"
assert_contains "$hidden_skill_output" "example-skill/assets/.env: OpenAI key"

echo "skills_registry_verify test ok"
