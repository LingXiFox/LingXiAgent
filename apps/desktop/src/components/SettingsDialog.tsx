import { useEffect, useState } from "react";

import { api } from "../lib/api";
import type { SkillSummary } from "../lib/types";

interface SettingsDialogProps {
  open: boolean;
  onClose: () => void;
  onLog: (level: "info" | "success" | "warn" | "error", message: string) => void;
}

const STORAGE_KEY = "lingxi.provider.settings";

interface StoredSettings {
  baseUrl: string;
  credentialRef: string;
}

function loadSettings(): StoredSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<StoredSettings>;
      return {
        baseUrl: parsed.baseUrl ?? "http://127.0.0.1:11434/v1",
        credentialRef: parsed.credentialRef ?? "env:OPENAI_API_KEY",
      };
    }
  } catch {
    // Ignore a corrupt preview setting.
  }
  return { baseUrl: "http://127.0.0.1:11434/v1", credentialRef: "env:OPENAI_API_KEY" };
}

export function SettingsDialog({ open, onClose, onLog }: SettingsDialogProps) {
  const [baseUrl, setBaseUrl] = useState("");
  const [credentialRef, setCredentialRef] = useState("");
  const [secret, setSecret] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [models, setModels] = useState<string[]>([]);
  const [skills, setSkills] = useState<SkillSummary[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    const stored = loadSettings();
    setBaseUrl(stored.baseUrl);
    setCredentialRef(stored.credentialRef);
    setSecret("");
    setStatus(null);
    setModels([]);
    setError(null);
    api
      .skillList()
      .then(setSkills)
      .catch((reason: unknown) => setError(String(reason)));
  }, [open]);

  if (!open) return null;

  const persist = () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ baseUrl, credentialRef }));
  };

  const saveCredential = async () => {
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const name = credentialRef.startsWith("keyring:")
        ? credentialRef.slice("keyring:".length)
        : credentialRef;
      if (!name || credentialRef.startsWith("env:")) {
        throw new Error("请输入 keyring:NAME 形式的凭据引用");
      }
      const reference = await api.credentialSet(name, secret);
      setCredentialRef(reference);
      setSecret("");
      persist();
      setStatus("已写入系统安全存储 · " + reference);
      onLog("success", "credential stored in the OS keychain · " + reference);
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const checkCredential = async () => {
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const available = await api.credentialStatus(credentialRef);
      setStatus(available ? "凭据可用" : "凭据不存在");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const deleteCredential = async () => {
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      await api.credentialDelete(credentialRef);
      setStatus("已从系统安全存储删除");
      onLog("warn", "credential removed from the OS keychain");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const discoverModels = async () => {
    setBusy(true);
    setError(null);
    setModels([]);
    try {
      persist();
      const found = await api.providerModels(baseUrl, credentialRef);
      setModels(found);
      onLog("info", "provider returned " + found.length + " model(s)");
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="dialog-backdrop" role="presentation" onClick={onClose}>
      <section
        className="dialog settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="模型与凭据设置"
        data-testid="settings-dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <header className="dialog__head">
          <h2 className="dialog__title">模型与凭据</h2>
          <button type="button" className="dialog__close" onClick={onClose} aria-label="关闭">
            ×
          </button>
        </header>

        <div className="settings-dialog__body">
          <section className="settings-section">
            <h3 className="settings-section__title">Provider 连接</h3>
            <label className="field" htmlFor="settings-base-url">
              <span className="field__label">Base URL</span>
              <input
                id="settings-base-url"
                className="field__control"
                data-testid="settings-base-url"
                value={baseUrl}
                onChange={(event) => setBaseUrl(event.target.value)}
                placeholder="http://127.0.0.1:11434/v1"
              />
            </label>
            <label className="field" htmlFor="settings-credential-ref">
              <span className="field__label">凭据引用</span>
              <input
                id="settings-credential-ref"
                className="field__control"
                data-testid="settings-credential-ref"
                value={credentialRef}
                onChange={(event) => setCredentialRef(event.target.value)}
                placeholder="keyring:openai 或 env:OPENAI_API_KEY"
              />
            </label>
            <label className="field" htmlFor="settings-secret">
              <span className="field__label">API Key（只写，不读取）</span>
              <input
                id="settings-secret"
                className="field__control"
                data-testid="settings-secret"
                type="password"
                autoComplete="off"
                value={secret}
                onChange={(event) => setSecret(event.target.value)}
              />
            </label>
            <div className="settings-actions">
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="settings-save-credential"
                onClick={() => void saveCredential()}
                disabled={busy || secret.length === 0}
              >
                保存密钥
              </button>
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="settings-check-credential"
                onClick={() => void checkCredential()}
                disabled={busy || credentialRef.length === 0}
              >
                检查凭据
              </button>
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="settings-delete-credential"
                onClick={() => void deleteCredential()}
                disabled={busy || credentialRef.length === 0}
              >
                删除
              </button>
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="settings-discover-models"
                onClick={() => void discoverModels()}
                disabled={busy || baseUrl.length === 0}
              >
                拉取模型列表
              </button>
            </div>
            {status ? (
              <p className="settings-status" data-testid="settings-status">
                {status}
              </p>
            ) : null}
            {models.length > 0 ? (
              <ul className="settings-models" data-testid="settings-models">
                {models.map((model) => (
                  <li key={model}>{model}</li>
                ))}
              </ul>
            ) : null}
          </section>

          <section className="settings-section">
            <h3 className="settings-section__title">本地 Skills</h3>
            {skills.length === 0 ? (
              <p className="settings-hint">未发现 Skills。把 SKILL.md 放到 ~/.lingxi/skills/&lt;id&gt;/ 或 LINGXI_SKILLS_DIR。</p>
            ) : (
              <ul className="settings-skills" data-testid="settings-skills">
                {skills.map((skill) => (
                  <li key={skill.id}>
                    <strong>{skill.name}</strong>
                    <span className="settings-skill-meta">
                      {skill.id}
                      {skill.version ? " · v" + skill.version : ""}
                    </span>
                    <p>{skill.description}</p>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {error ? (
            <p className="dialog__error" data-testid="settings-error">
              {error}
            </p>
          ) : null}
        </div>

        <footer className="dialog__foot">
          <button type="button" className="btn" onClick={onClose}>
            关闭
          </button>
        </footer>
      </section>
    </div>
  );
}
