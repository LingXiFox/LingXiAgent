#!/usr/bin/env bash
# catalog-pipeline-check.sh — contract §8/§9/§12/§21/§22 as an executable check.
#
# The publisher is the only thing that decides what the public catalog looks like,
# so its guarantees (validate → transform → validate → atomic publish, keep the
# last-known-good on any failure, deterministic ordering, no runtime guessing)
# are asserted against real runs rather than against a description of them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${REPO_ROOT}/Server/models-site/sync-models.py"
PYTHON="${PYTHON:-python3}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lingxi-catalog-check.XXXXXX")"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# The artifact is written compact, so the envelope revision is a single sed away.
revision_of() { sed -n 's/.*"catalogRevision":"\([^"]*\)".*/\1/p' "$1" | head -n 1; }
trap 'rm -rf "$WORK"' EXIT

command -v "$PYTHON" >/dev/null 2>&1 || fail "python3 is required"
[ -f "$SYNC" ] || fail "missing $SYNC"

printf '{"schemaVersion":"2.0"}\n' > /dev/null   # keeps shellcheck quiet about the fixtures below

# ── fixtures ────────────────────────────────────────────────────────────────
cat > "$WORK/source.json" <<'JSON'
{
  "openai": {"id": "openai", "name": "OpenAI", "env": ["OPENAI_API_KEY"], "doc": "https://platform.openai.com/docs/models",
    "api": "https://api.openai.com/v1",
    "models": {
      "gpt-10": {"id": "gpt-10", "name": "GPT-10", "release_date": "2026-01-01", "reasoning": true, "tool_call": true,
                 "modalities": {"input": ["text"], "output": ["text"]}, "limit": {"context": 200000, "output": 100000},
                 "cost": {"input": 1.25, "output": 10}},
      "gpt-5":  {"id": "gpt-5", "name": "GPT-5", "release_date": "2025-08-07", "reasoning": true, "attachment": true,
                 "tool_call": true, "structured_output": true, "modalities": {"input": ["text", "image"], "output": ["text"]},
                 "limit": {"context": 400000, "output": 128000}, "cost": {"input": 1.25, "output": 10},
                 "brand_new_upstream_field": {"keep": "me"}},
      "undated": {"id": "undated", "name": "Undated Model", "modalities": {"input": ["text"], "output": ["text"]},
                  "limit": {"context": 8192, "output": 1024}}
    }},
  "deepseek": {"id": "deepseek", "name": "DeepSeek", "env": ["DEEPSEEK_API_KEY"], "api": "https://api.deepseek.com",
    "models": {"deepseek-v4": {"id": "deepseek-v4", "name": "DeepSeek V4", "release_date": "2026-03-01",
                 "tool_call": true, "modalities": {"input": ["text"], "output": ["text"]},
                 "limit": {"context": 128000, "output": 64000}, "cost": {"input": 0.14, "output": 0.28}}}},
  "broken-provider": "not-an-object",
  "empty-models": {"id": "empty-models", "name": "Empty", "models": {}}
}
JSON

# Same data, different upstream iteration order: the publication must not notice.
"$PYTHON" - "$WORK/source.json" "$WORK/shuffled.json" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
json.dump({k: raw[k] for k in reversed(list(raw))}, open(sys.argv[2], "w"))
PY

# A truncated document: structurally broken, must abort the run.
head -c 120 "$WORK/source.json" > "$WORK/truncated.json"
# Structurally valid JSON whose shape no longer holds: providers without models.
printf '{"a":{"id":"a","name":"A"},"b":{"id":"b","name":"B"}}' > "$WORK/destroyed.json"
# A source that lost most of its models: an incident, not a real shrink.
"$PYTHON" - "$WORK/source.json" "$WORK/thin.json" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
thin = {k: {**p, "models": dict(list(p.get("models", {}).items())[:1])}
        for k, p in raw.items() if isinstance(p, dict) and p.get("models")}
json.dump(thin, open(sys.argv[2], "w"))
PY
# One malformed entry among good ones: skip the entry, publish the rest.
"$PYTHON" - "$WORK/source.json" "$WORK/polluted.json" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
raw["openai"]["models"]["bogus"] = "not-an-object"
raw["openai"]["models"]["bad-limit"] = {"id": "bad-limit", "name": "Bad", "limit": {"context": "wide"}}
json.dump(raw, open(sys.argv[2], "w"))
PY

OUT="$WORK/public"
run() { # run <label> <source> [extra args…] → echoes exit code, keeps stdout in $WORK/last.log
    local label="$1" source="$2"; shift 2
    set +e
    "$PYTHON" "$SYNC" "$OUT" --source-url "file://$source" "$@" > "$WORK/last.log" 2>&1
    local code=$?
    set -e
    printf '[%s] exit=%s\n' "$label" "$code"
    return $code
}

# ── 1. a good source publishes ──────────────────────────────────────────────
run good "$WORK/source.json" || fail "a valid source must publish"
[ -s "$OUT/models.json" ] || fail "models.json missing or empty after a publish"
[ -s "$OUT/publication.json" ] || fail "the publication marker was not written"

# ── 2. the artifact is the single v2 publication, with no second projection ─
REVISION="$(revision_of "$OUT/models.json")"
"$PYTHON" - "$OUT/models.json" <<'PY' || fail "the published artifact violates the contract"
import json, sys
catalog = json.load(open(sys.argv[1]))
assert catalog["schemaVersion"] == "2.0", catalog["schemaVersion"]
assert "summary" not in catalog, "a second model projection reappeared"
assert catalog["totalProviders"] == len(catalog["providers"])
assert catalog["totalProviders"] == 2, catalog["totalProviders"]
assert catalog["source"] == "models.dev"
assert catalog["sourceHash"].startswith("sha256:") and catalog["catalogHash"].startswith("sha256:")
# §11: an upstream field the publisher has never heard of survives.
assert catalog["providers"]["openai"]["models"]["gpt-5"]["brand_new_upstream_field"] == {"keep": "me"}
# §10: no runtime guesses, at either level.
for forbidden in ("swiftDriver", "reasoningField", "swiftSnippet"):
    assert forbidden not in json.dumps(catalog), forbidden
# §12: providers in displayName order, models newest-first then undated.
assert list(catalog["providers"]) == ["deepseek", "openai"], list(catalog["providers"])
assert list(catalog["providers"]["openai"]["models"]) == ["gpt-10", "gpt-5", "undated"], "model order is not the documented rule"
print(catalog["catalogRevision"])
PY

# ── 3. determinism: an unchanged source republishes the same revision ───────
run again "$WORK/source.json" >/dev/null || fail "republishing the same source must succeed"
REVISION2="$(revision_of "$OUT/models.json")"
[ "$REVISION" = "$REVISION2" ] || fail "catalogRevision changed without the data changing"
# Upstream insertion order must not leak into the publication.
run shuffled "$WORK/shuffled.json" >/dev/null || fail "publishing a reordered source must succeed"
REVISION3="$(revision_of "$OUT/models.json")"
[ "$REVISION" = "$REVISION3" ] || fail "reordering the source changed the publication: ordering is not deterministic"

# ── 4. any failure keeps the last-known-good, untouched ─────────────────────
BEFORE="$(shasum -a 256 "$OUT/models.json" | cut -d' ' -f1)"
run truncated "$WORK/truncated.json" && fail "a truncated source must abort"
[ "$(shasum -a 256 "$OUT/models.json" | cut -d' ' -f1)" = "$BEFORE" ] || fail "the last-known-good was modified by an aborted run"
run destroyed "$WORK/destroyed.json" && fail "a shape-drifted source must abort"
run shrink "$WORK/thin.json" && fail "a large model-count drop must refuse to overwrite"
grep -q 'allow-shrink' "$WORK/last.log" || fail "the refusal must name the override it needs"
[ "$(shasum -a 256 "$OUT/models.json" | cut -d' ' -f1)" = "$BEFORE" ] || fail "the shrink guard published anyway"
run shrink-override "$WORK/thin.json" --allow-shrink || fail "--allow-shrink must publish"
[ "$(shasum -a 256 "$OUT/models.json" | cut -d' ' -f1)" != "$BEFORE" ] || fail "--allow-shrink did not publish"
run restore "$WORK/source.json" || fail "republishing the good source must work"
# The document carries generatedAt, so bytes legitimately differ between runs; the
# content-derived revision is what must come back unchanged.
[ "$(revision_of "$OUT/models.json")" = "$REVISION" ] \
    || fail "republishing the same source produced a different revision"

# ── 5. one malformed entry costs that entry, not the catalog ────────────────
run polluted "$WORK/polluted.json" || fail "a malformed entry must not abort the publication"
"$PYTHON" - "$OUT/models.json" <<'PY' || fail "the malformed entries were not skipped as reported"
import json, sys
catalog = json.load(open(sys.argv[1]))
assert catalog["providers"]["openai"]["models"].get("gpt-5"), "good entries must survive"
assert "bogus" not in catalog["providers"]["openai"]["models"]
assert "bad-limit" not in catalog["providers"]["openai"]["models"]
assert "broken-provider" not in catalog["providers"]
assert "empty-models" not in catalog["providers"]
assert catalog["totalModels"] == sum(len(p["models"]) for p in catalog["providers"].values())
PY
run polluted-restore "$WORK/source.json" >/dev/null || fail "republishing after the polluted run must succeed"

# ── 6. --check validates a document without touching the network ────────────
"$PYTHON" "$SYNC" --check "$OUT" > "$WORK/check.log" 2>&1 || fail "--check must validate an existing document"
grep -q 'catalogRevision' "$WORK/check.log" || fail "--check must report the revision it verified"

printf 'catalog pipeline checks passed (revision %s)\n' "$REVISION"
