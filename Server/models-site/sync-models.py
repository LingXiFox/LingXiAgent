#!/usr/bin/env python3
"""
sync-models.py — publish the LingXi public model catalog from models.dev.

The published `models.json` is the single model data artifact: the Agent, the
web UI and any third party read the same document. Nothing here decides how
LingXi's runtime talks to a provider — protocol family, adapter and endpoint
overrides belong to the runtime layer, and guessing them from an upstream
package name is exactly what this pipeline used to do wrong.

Publishing is transactional:
    fetch → validate source → normalize → validate catalog → write temp file
    → reopen and decode it → hash and revision → atomic rename → mark published
Any failure leaves the previous last-known-good document untouched.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request

SCHEMA_VERSION = "2.0"
SOURCE = "models.dev"
SOURCE_URL = "https://models.dev/api.json"
USER_AGENT = "LingXiModelSync/2.0 (https://models.lingxifox.cn)"

CATALOG_FILE = "models.json"
MANIFEST_FILE = "publication.json"

# A publication that loses this share of the models relative to the document on
# disk is treated as an upstream incident, not as a real shrink.
DEFAULT_MIN_MODEL_RATIO = 0.7


class SyncError(Exception):
    """A failure that must stop publication and keep the last-known-good."""


# ─────────────────────────────────────────────────────────────────────────────
# Source validation (§9)
#
# Upstream shape is not a contract we control, so it is checked rather than
# assumed. One malformed entry is skipped with a warning; a document whose
# structure no longer holds together aborts the run.
# ─────────────────────────────────────────────────────────────────────────────

def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def check_limit(entry_id, models_limit, warnings):
    """True when `limit` can be published; an absent limit is acceptable."""
    if models_limit is None:
        return True
    if not isinstance(models_limit, dict):
        warnings.append(f"model {entry_id}: limit is not an object")
        return False
    for key in ("context", "input", "output"):
        value = models_limit.get(key)
        if value is None:
            continue
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            warnings.append(f"model {entry_id}: limit.{key} is not a non-negative integer")
            return False
    return True


def check_cost(entry_id, cost, warnings):
    """Prices are per-million-token figures; `null` means unpriced, not free."""
    if cost is None or isinstance(cost, dict):
        return True
    warnings.append(f"model {entry_id}: cost is neither an object nor null")
    return False


FLAG_FIELDS = ("reasoning", "attachment", "tool_call", "structured_output", "open_weights", "temperature")


def check_model(entry_id, model, warnings):
    """Decide whether one model entry is publishable, without touching it."""
    for field in FLAG_FIELDS:
        value = model.get(field)
        if value is not None and not isinstance(value, bool):
            warnings.append(f"model {entry_id}: {field} is not a boolean")
            return False
    modalities = model.get("modalities")
    if modalities is not None:
        if not isinstance(modalities, dict):
            warnings.append(f"model {entry_id}: modalities is not an object")
            return False
        for direction in ("input", "output"):
            values = modalities.get(direction)
            if values is not None and (not isinstance(values, list) or any(not isinstance(v, str) for v in values)):
                warnings.append(f"model {entry_id}: modalities.{direction} is not a string array")
                return False
    # Upstream publishes both `2025-08` and `2025-08-07`; the published schema
    # only requires a string. A format rule here would drop real entries for
    # nothing, since ordering compares them as text either way.
    for field in ("release_date", "last_updated", "knowledge"):
        value = model.get(field)
        if value is not None and not isinstance(value, str):
            warnings.append(f"model {entry_id}: {field} is not a string")
            return False
    for field in ("id", "name", "description", "family", "canonical_model_id"):
        value = model.get(field)
        if value is not None and not isinstance(value, str):
            warnings.append(f"model {entry_id}: {field} is not a string")
            return False
    status = model.get("status")
    if status is not None and not isinstance(status, str):
        warnings.append(f"model {entry_id}: status is not a string")
        return False
    return check_limit(entry_id, model.get("limit"), warnings) and check_cost(entry_id, model.get("cost"), warnings)


def validate_source(raw):
    """Structural checks on the fetched document — abort, never half-publish."""
    if not isinstance(raw, dict) or not raw:
        raise SyncError("上游文档不是非空对象")
    providers = [(pid, pdata) for pid, pdata in raw.items() if isinstance(pdata, dict)]
    if not providers:
        raise SyncError("上游文档里没有任何对象形 provider")
    with_models = [
        (pid, pdata) for pid, pdata in providers
        if isinstance(pdata.get("models"), dict) and pdata["models"]
    ]
    if len(with_models) < max(1, len(providers) // 2):
        raise SyncError(
            f"上游结构漂移：{len(providers)} 个 provider 中只有 {len(with_models)} 个带模型对象"
        )
    return raw


# ─────────────────────────────────────────────────────────────────────────────
# Ordering (§12)
#
# The publisher decides the order, and every reader — Agent, web UI, SDK —
# documents the same comparator, so one catalog always renders the same way.
# Natural compare keeps "GPT-5" ahead of "GPT-10", which a plain byte compare
# gets backwards.
# ─────────────────────────────────────────────────────────────────────────────

_NATURAL = re.compile(r"(\d+)")


def natural_key(text):
    """The published ordering rule, mirrored by `ModelCatalogOrdering.displayName`.

    Case-folded words, digit runs compared as numbers (so GPT-5 precedes GPT-10),
    and a number ordered before a word at the same position.
    """
    parts = _NATURAL.split((text or "").casefold())
    key = []
    for index, part in enumerate(parts):
        if index % 2 == 0:
            key.append((1, 0, part))      # text
        else:
            key.append((0, int(part), ""))  # number
    return tuple(key)


def provider_display_order(name, identifier):
    return (natural_key(name), identifier)


def model_display_order(model):
    release = model.get("release_date") or ""
    # Newest first, and an undated entry never displaces a dated one.
    return (0 if release else 1, _reverse_text(release), natural_key(model.get("family") or ""),
            natural_key(model.get("name") or ""), model.get("id") or "")


class _reverse_text:
    """Wrapper that inverts a string's comparison, for descending text dates."""

    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value

    def __lt__(self, other):
        return self.value > other.value

    def __eq__(self, other):
        return self.value == other.value


# ─────────────────────────────────────────────────────────────────────────────
# Normalize (§10, §11)
#
# Upstream fields are published as they are. The only added keys are the stable
# published schema: a provider's `baseURL` mirror of upstream `api`, and a
# model count. Runtime guesses — driver, reasoning wire field, code snippets —
# are not produced here and are stripped if an older document carried them.
# ─────────────────────────────────────────────────────────────────────────────

RUNTIME_GUESS_FIELDS = ("swiftDriver", "reasoningField", "swiftSnippet")


def normalize(raw, featured):
    warnings = []
    skipped_providers = []
    skipped_models = []
    providers = {}
    total_models = 0

    for pid, pdata in raw.items():
        if not isinstance(pdata, dict):
            skipped_providers.append(str(pid))
            warnings.append(f"provider {pid}: 不是对象，已跳过")
            continue
        raw_models = pdata.get("models")
        if not isinstance(raw_models, dict) or not raw_models:
            skipped_providers.append(str(pid))
            warnings.append(f"provider {pid}: models 缺失或不是对象，已跳过")
            continue

        kept = {}
        for mid, model in raw_models.items():
            if not isinstance(model, dict):
                skipped_models.append(f"{pid}/{mid}")
                warnings.append(f"model {pid}/{mid}: 条目不是对象，已跳过")
                continue
            if not mid or not isinstance(mid, str):
                skipped_models.append(f"{pid}/{mid}")
                warnings.append(f"model {pid}/{mid}: ID 为空，已跳过")
                continue
            if not check_model(f"{pid}/{mid}", model, warnings):
                skipped_models.append(f"{pid}/{mid}")
                continue
            kept[mid] = dict(model)
        if not kept:
            skipped_providers.append(str(pid))
            warnings.append(f"provider {pid}: 没有任何合格模型，已跳过")
            continue

        published = {key: value for key, value in pdata.items() if key != "models"}
        api = published.get("api")
        published["baseURL"] = api if isinstance(api, str) and api else None
        published["modelCount"] = len(kept)
        published["models"] = kept
        total_models += len(kept)
        providers[pid] = published

    ordered_ids = sorted(
        providers,
        key=lambda pid: (
            featured.index(pid) if pid in featured else len(featured),
            provider_display_order(providers[pid].get("name") or pid, pid),
        ),
    )
    ordered = {}
    for pid in ordered_ids:
        entry = providers[pid]
        entry["models"] = {
            mid: entry["models"][mid]
            for mid in sorted(entry["models"], key=lambda mid: model_display_order(entry["models"][mid]))
        }
        ordered[pid] = entry
    return ordered, total_models, warnings, skipped_providers, skipped_models


# ─────────────────────────────────────────────────────────────────────────────
# Catalog validation (§9, §21, §22)
# ─────────────────────────────────────────────────────────────────────────────

def validate_generated(catalog, expected_models):
    """Re-check what we are about to publish, independent of the generator."""
    if catalog.get("schemaVersion") != SCHEMA_VERSION:
        raise SyncError("生成文档的 schemaVersion 不符合预期")
    providers = catalog.get("providers")
    if not isinstance(providers, dict) or not providers:
        raise SyncError("生成文档没有 provider")
    counted = 0
    for pid, pdata in providers.items():
        if not isinstance(pdata, dict) or not pid:
            raise SyncError(f"生成文档 provider 条目损坏：{pid}")
        models = pdata.get("models")
        if not isinstance(models, dict) or not models:
            raise SyncError(f"生成文档 provider {pid} 没有模型")
        for mid, model in models.items():
            if not isinstance(model, dict) or not mid:
                raise SyncError(f"生成文档模型条目损坏：{pid}/{mid}")
            for field in RUNTIME_GUESS_FIELDS:
                if field in model or field in pdata:
                    raise SyncError(f"生成文档混入了运行时猜测字段：{field}")
            counted += 1
    if counted != expected_models:
        raise SyncError(f"生成文档模型数 {counted} 与统计值 {expected_models} 不一致")
    if catalog.get("totalModels") != counted:
        raise SyncError("生成文档的 totalModels 与实际模型数不一致")
    return counted


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
# Fetch (§8 step 1)
# ─────────────────────────────────────────────────────────────────────────────

def fetch_source(url, retries=3, timeout=60):
    last_error = None
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        try:
            print(f"[sync] 拉取 {url}（第 {attempt}/{retries} 次）…")
            started = time.monotonic()
            with urllib.request.urlopen(request, timeout=timeout) as response:
                # A non-HTTP scheme (a local file, used by the offline tests) has no status.
                status = response.getcode()
                if status is not None and status != 200:
                    raise SyncError(f"上游返回 HTTP {status}")
                body = response.read()
            print(f"[sync] 收到 {len(body):,} 字节，用时 {time.monotonic() - started:.1f}s")
            return body, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = error
            print(f"[sync] 拉取失败：{error}")
            if attempt < retries:
                time.sleep(2 * attempt)
    raise SyncError(f"上游不可达：{last_error}")


# ─────────────────────────────────────────────────────────────────────────────
# Publish (§7, §8)
# ─────────────────────────────────────────────────────────────────────────────

def read_previous(path):
    """The last-known-good document, if one exists and still validates."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError) as error:
        print(f"[sync] 现存 catalog 无法读取（{error}），本次不把它当作 last-known-good")
        return None


def guard_against_shrink(previous, provider_count, model_count, min_ratio, allow_shrink):
    if previous is None or allow_shrink:
        return
    previous_models = previous.get("totalModels")
    if not isinstance(previous_models, int) or previous_models <= 0:
        return
    ratio = model_count / previous_models
    if ratio < min_ratio:
        raise SyncError(
            f"模型数从 {previous_models} 降到 {model_count}（{ratio:.1%}），"
            f"低于阈值 {min_ratio:.0%}；这更像上游异常。确认无误请加 --allow-shrink"
        )
    previous_providers = previous.get("totalProviders")
    if isinstance(previous_providers, int) and previous_providers > 0:
        provider_ratio = provider_count / previous_providers
        if provider_ratio < min_ratio:
            raise SyncError(
                f"provider 数从 {previous_providers} 降到 {provider_count}（{provider_ratio:.1%}）；"
                f"确认无误请加 --allow-shrink"
            )


def publish(output_dir, catalog_bytes, manifest):
    """Write, re-open, verify, then move — the document is never half-written."""
    os.makedirs(output_dir, exist_ok=True)
    target = os.path.join(output_dir, CATALOG_FILE)
    descriptor, temporary = tempfile.mkstemp(dir=output_dir, prefix=".models-", suffix=".json")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(catalog_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        with open(temporary, "rb") as handle:
            reread = handle.read()
        if sha256_of(reread) != sha256_of(catalog_bytes):
            raise SyncError("临时文件回读与内存内容不一致")
        decoded = json.loads(reread.decode("utf-8"))
        validate_generated(decoded, decoded.get("totalModels", 0))
        # mkstemp creates 0600; a public document has to be readable by the web server.
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)

    manifest_path = os.path.join(output_dir, MANIFEST_FILE)
    descriptor, temporary_manifest = tempfile.mkstemp(dir=output_dir, prefix=".publication-", suffix=".json")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_manifest, 0o644)
        if os.path.exists(manifest_path):
            # Keep the previous manifest beside the new one: it is the record of
            # what was live before this run, which a drift check needs.
            shutil.copy2(manifest_path, os.path.join(output_dir, MANIFEST_FILE + ".prev"))
            os.chmod(os.path.join(output_dir, MANIFEST_FILE + ".prev"), 0o644)
        os.replace(temporary_manifest, manifest_path)
    finally:
        if os.path.exists(temporary_manifest):
            os.remove(temporary_manifest)
    print(f"[sync] 发布完成：{target} ({len(catalog_bytes):,} 字节)")
    return target


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def load_featured(path):
    if not path:
        return []
    with open(path, "r", encoding="utf-8") as handle:
        entries = json.load(handle)
    if isinstance(entries, dict):
        entries = entries.get("featured", [])
    if not isinstance(entries, list) or any(not isinstance(item, str) for item in entries):
        raise SyncError("--featured-file 必须是 provider id 的字符串数组")
    return entries


def check(output_dir):
    """Report on a document that already exists, without contacting anything."""
    target = os.path.join(output_dir, CATALOG_FILE)
    if not os.path.exists(target):
        raise SyncError(f"{target} 不存在")
    with open(target, "rb") as handle:
        data = handle.read()
    decoded = json.loads(data.decode("utf-8"))
    models = validate_generated(decoded, decoded.get("totalModels", 0))
    print(json.dumps({
        "path": target,
        "schemaVersion": decoded.get("schemaVersion"),
        "catalogRevision": decoded.get("catalogRevision"),
        "catalogHash": decoded.get("catalogHash"),
        "providers": len(decoded.get("providers", {})),
        "models": models,
        "bytes": len(data),
        "sha256": sha256_of(data),
    }, indent=2))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Publish the LingXi model catalog from models.dev")
    parser.add_argument("output_dir", nargs="?", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "public"))
    parser.add_argument("--source-url", default=SOURCE_URL)
    parser.add_argument("--featured-file", help="JSON array of provider ids to rank first")
    parser.add_argument("--min-model-ratio", type=float, default=DEFAULT_MIN_MODEL_RATIO)
    parser.add_argument("--allow-shrink", action="store_true", help="Publish despite a large drop")
    parser.add_argument("--check", action="store_true", help="Validate an existing document; fetch nothing")
    parser.add_argument("--retries", type=int, default=3)
    args = parser.parse_args(argv)

    started = time.monotonic()
    try:
        if args.check:
            return check(args.output_dir)

        featured = load_featured(args.featured_file)
        raw_bytes, source_fetched_at = fetch_source(args.source_url, retries=args.retries)
        source_hash = sha256_of(raw_bytes)
        try:
            raw = json.loads(raw_bytes.decode("utf-8"))
        except ValueError as error:
            raise SyncError(f"上游不是合法 JSON：{error}")
        validate_source(raw)

        providers, model_count, warnings, skipped_providers, skipped_models = normalize(raw, featured)
        provider_count = len(providers)

        generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        # The revision identifies the data, not the run: re-running against an
        # unchanged upstream must produce the same revision.
        body_for_hash = json.dumps(
            {"schemaVersion": SCHEMA_VERSION, "providers": providers},
            ensure_ascii=False, separators=(",", ":"), sort_keys=True,
        ).encode("utf-8")
        catalog_hash = sha256_of(body_for_hash)

        catalog = {
            "schemaVersion": SCHEMA_VERSION,
            "catalogRevision": catalog_hash[:12],
            "catalogHash": f"sha256:{catalog_hash}",
            "generatedAt": generated_at,
            "source": SOURCE,
            "sourceURL": args.source_url,
            "sourceFetchedAt": source_fetched_at,
            "sourceHash": f"sha256:{source_hash}",
            "totalProviders": provider_count,
            "totalModels": model_count,
            "providers": providers,
        }
        counted = validate_generated(catalog, model_count)
        if counted != model_count:
            raise SyncError("发布前复查的模型数与生成数不一致")

        guard_against_shrink(
            read_previous(os.path.join(args.output_dir, CATALOG_FILE)),
            provider_count, model_count, args.min_model_ratio, args.allow_shrink,
        )

        catalog_bytes = json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        manifest = {
            "schemaVersion": SCHEMA_VERSION,
            "catalogRevision": catalog["catalogRevision"],
            "catalogHash": catalog["catalogHash"],
            "generatedAt": generated_at,
            "sourceFetchedAt": source_fetched_at,
            "sourceHash": catalog["sourceHash"],
            "providers": provider_count,
            "models": counted,
            "bytes": len(catalog_bytes),
            "sha256": sha256_of(catalog_bytes),
            "publishedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        target = publish(args.output_dir, catalog_bytes, manifest)

        duration = time.monotonic() - started
        print(json.dumps({
            "sourceProviders": len(raw),
            "sourceModels": sum(len(p.get("models", {})) for p in raw.values() if isinstance(p, dict)),
            "publishedProviders": provider_count,
            "publishedModels": counted,
            "skippedProviders": len(skipped_providers),
            "skippedModels": len(skipped_models),
            "warnings": len(warnings),
            "sourceHash": f"sha256:{source_hash}",
            "catalogHash": catalog["catalogHash"],
            "catalogRevision": catalog["catalogRevision"],
            "bytes": len(catalog_bytes),
            "seconds": round(duration, 2),
        }, indent=2, sort_keys=True))
        for warning in warnings[:40]:
            print(f"[sync][warn] {warning}")
        if len(warnings) > 40:
            print(f"[sync][warn] …另有 {len(warnings) - 40} 条")
        print(f"[sync] {target}")
        return 0
    except SyncError as error:
        print(f"[sync] 发布中止，保留上一版 last-known-good：{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
