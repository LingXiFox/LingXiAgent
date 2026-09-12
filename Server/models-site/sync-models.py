#!/usr/bin/env python3
"""
sync-models.py - Synchronize and transform models.dev to LingXi Swift-friendly models.json
"""

import json
import os
import sys
import time
import urllib.request
from typing import Any, Dict

MODELS_DEV_URL = "https://models.dev/api.json"


def fetch_models_dev(retries: int = 3, timeout: int = 30) -> Dict[str, Any]:
    req = urllib.request.Request(
        MODELS_DEV_URL,
        headers={
            "User-Agent": "LingXiModelSync/1.0 (https://models.lingxifox.cn)",
            "Accept": "application/json",
        },
    )
    for attempt in range(1, retries + 1):
        try:
            print(f"[sync] Fetching {MODELS_DEV_URL} (attempt {attempt}/{retries})...")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    raw_data = resp.read().decode("utf-8")
                    return json.loads(raw_data)
        except Exception as e:
            print(f"[sync] Error fetching data: {e}")
            if attempt < retries:
                time.sleep(2 * attempt)
            else:
                raise


def determine_swift_driver(provider_id: str, npm: str) -> str:
    npm_lower = (npm or "").lower()
    pid_lower = provider_id.lower()
    if "anthropic" in npm_lower or "anthropic" in pid_lower:
        return "anthropicMessages"
    elif "google" in npm_lower or "gemini" in pid_lower:
        return "geminiNative"
    elif "ollama" in npm_lower or "ollama" in pid_lower:
        return "ollamaNative"
    else:
        return "openaiChat"


def generate_swift_code(provider_id: str, model_id: str, base_url: str, env_key: str) -> str:
    snippet = f"""import LingXiAgent

// 1. One-line inference via LingXiAgent Registry
let model = LingXiAgent.model("{provider_id}/{model_id}", apiKey: processEnvironment["{env_key}"])

// 2. Or initialize via OpenAI-Compatible factory
let provider = LingXiProvider.openAICompatible(
    baseURL: URL(string: "{base_url}")!,
    apiKey: processEnvironment["{env_key}"]
)
let session = provider.model("{model_id}")

// 3. Stream responses with reasoning support
for try await chunk in session.stream("Hello, LingXi!") {{
    if let reasoning = chunk.reasoning {{
        print("[Thinking] \\(reasoning)", terminator: "")
    }}
    print(chunk.text, terminator: "")
}}
"""
    return snippet.strip()


def transform_data(raw_data: Dict[str, Any]) -> Dict[str, Any]:
    transformed_providers: Dict[str, Any] = {}
    all_models_summary = []
    total_models = 0

    for pid, pdata in raw_data.items():
        if not isinstance(pdata, dict):
            continue

        name = pdata.get("name", pid)
        base_url = pdata.get("api", "")
        npm = pdata.get("npm", "@ai-sdk/openai-compatible")
        env_vars = pdata.get("env", [f"{pid.upper().replace('-', '_')}_API_KEY"])
        primary_env = env_vars[0] if env_vars else "API_KEY"
        doc_url = pdata.get("doc", "")
        swift_driver = determine_swift_driver(pid, npm)

        raw_models = pdata.get("models", {})
        transformed_models: Dict[str, Any] = {}

        for mid, mdata in raw_models.items():
            if not isinstance(mdata, dict):
                continue

            total_models += 1
            m_name = mdata.get("name", mid)
            m_desc = mdata.get("description", "")
            limit = mdata.get("limit", {})
            cost = mdata.get("cost", {})
            reasoning = bool(mdata.get("reasoning", False))
            attachment = bool(mdata.get("attachment", False))
            tool_call = bool(mdata.get("tool_call", False))
            options = mdata.get("options", {})
            reasoning_field = "reasoning_content" if options.get("reasoning_content") else None

            swift_snippet = generate_swift_code(pid, mid, base_url, primary_env)

            transformed_models[mid] = {
                **mdata,
                "swiftDriver": swift_driver,
                "reasoningField": reasoning_field,
                "swiftSnippet": swift_snippet,
            }

            all_models_summary.append({
                "providerId": pid,
                "providerName": name,
                "baseURL": base_url,
                "modelId": mid,
                "name": m_name,
                "description": m_desc,
                "context": limit.get("context", 0),
                "output": limit.get("output", 0),
                "costInput": cost.get("input", 0),
                "costOutput": cost.get("output", 0),
                "reasoning": reasoning,
                "attachment": attachment,
                "toolCall": tool_call,
                "swiftDriver": swift_driver,
            })

        transformed_providers[pid] = {
            "id": pid,
            "name": name,
            "baseURL": base_url,
            "npm": npm,
            "swiftDriver": swift_driver,
            "env": env_vars,
            "doc": doc_url,
            "modelCount": len(transformed_models),
            "models": transformed_models,
        }

    return {
        "version": "1.0",
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "totalProviders": len(transformed_providers),
        "totalModels": total_models,
        "providers": transformed_providers,
        "summary": all_models_summary,
    }


def main():
    output_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(output_dir, exist_ok=True)

    print("[sync] Starting models.dev synchronization...")
    raw_data = fetch_models_dev()
    print(f"[sync] Received raw data for {len(raw_data)} providers.")

    catalog = transform_data(raw_data)
    print(f"[sync] Processed {catalog['totalProviders']} providers and {catalog['totalModels']} models.")

    # 1. Output full models.json
    models_json_path = os.path.join(output_dir, "models.json")
    with open(models_json_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
    print(f"[sync] Wrote full catalog to {models_json_path} ({os.path.getsize(models_json_path):,} bytes)")

    # 2. Output lightweight index data for UI
    summary_path = os.path.join(output_dir, "summary.json")
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump({
            "version": catalog["version"],
            "updatedAt": catalog["updatedAt"],
            "totalProviders": catalog["totalProviders"],
            "totalModels": catalog["totalModels"],
            "models": catalog["summary"],
        }, f, ensure_ascii=False)
    print(f"[sync] Wrote summary to {summary_path} ({os.path.getsize(summary_path):,} bytes)")

    print("[sync] Complete successfully!")


if __name__ == "__main__":
    main()
