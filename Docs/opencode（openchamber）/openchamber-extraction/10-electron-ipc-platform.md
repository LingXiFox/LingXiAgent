# Electron Main、Preload 与 IPC

## Boundary

Electron owns the desktop shell, not shared product backend logic. `main.mjs` starts the web server in the same main process. `preload.mjs` gives web UI a constrained bridge under `window.__OPENCHAMBER_DESKTOP__`; shared UI must not import Electron.

The preload also exposes runtime bootstrap values such as `__OPENCHAMBER_LOCAL_ORIGIN__`, `__OPENCHAMBER_API_BASE_URL__`, `__OPENCHAMBER_CLIENT_TOKEN__`, runtime headers, relay host ID, home directory and platform. In packaged/local Desktop these let the renderer attach to the in-process server; they are not available to ordinary remote pages.

## IPC inventory

Electron exposes a generic `openchamber:invoke` RPC plus narrower dialogs/filesystem grant handlers. Main validates the sender and command-specific privilege; preload explicitly notes that main decides what is safe. Relevant handlers are at `main.mjs:5175+`, bridge at `preload.mjs:93+` and `:165+`.

| Category | Main/preload capability | Commands / channels | Classification |
| --- | --- | --- |
| Window | create/show/hide/minimize main and Mini Chat windows, multi-window state, context surfaces | `desktop_start_window_drag`, `desktop_focus_window`, fullscreen/title/pinned/state/menu, new/close/minimize/maximize/focus windows, Mini Chat commands | Platform service |
| Dialog / local folder | native open dialog and exact-path grant | `openchamber:dialog:open`, `openchamber:file:grant-existing` | Platform service |
| Filesystem convenience | save markdown, guarded read, reveal/open/open-in-app, installed app lookup/icons | `desktop_save_markdown_file`, `desktop_read_file`, `desktop_open_path`, `desktop_reveal_path`, `desktop_open_in_app`, `desktop_open_file_in_app`, app filter/icon/list | Platform service; server owns general FS API |
| Browser panel | preview color emulation, favicon fetch, scoped storage clear, page/rectangle capture | `desktop_browser_*`, `desktop_capture_page_rect` | Platform service |
| Clipboard / external link | system clipboard/open external URL | `desktop_open_external_url` plus Electron menu native copy roles | UI convenience / platform service |
| Notifications / tray | native notification and renderer-pushed tray state | `desktop_notify`, `desktop_tray_update` | Platform service |
| Updater / app lifecycle | app version, start-at-login, keep-awake, update check/download/restart | `desktop_get_app_version`, login/tray/awake commands, `desktop_check_for_updates`, `desktop_download_and_install_update`, `desktop_restart` | Platform service |
| Process / dev tunnel | creates/tears down local loopback forward for a remote dev server | `desktop_dev_tunnel_open`, `desktop_dev_tunnel_close` | Platform service |
| SSH | import hosts, config, connect/disconnect/status/logs | `desktop_ssh_instances_*`, `desktop_ssh_import_hosts`, `desktop_ssh_connect`, `desktop_ssh_disconnect`, `desktop_ssh_status`, `desktop_ssh_logs*` | Platform service |
| Remote host/bootstrap | configured host/token and remote password login/probe/LAN address | `desktop_hosts_*`, `desktop_local_client_token_get`, `desktop_install_id_get`, `desktop_host_probe`, `desktop_remote_password_login`, `desktop_get_lan_address`, remote-window command | Platform service / remote client convenience |
| Background appearance | validate/copy managed JPEG/PNG/WebP and serve read-only protocol | `desktop_background_get/update/import/clear` | LingXi platform modification |
| Quota | local-only Sub2API fetch | `desktop_fetch_sub2api_quota` | LingXi platform modification |

The exact command string inventory of `openchamber:invoke` should be extracted mechanically from its switch before any replacement implementation. This document intentionally records categories rather than claiming every switch arm without a generated table. See `17-open-questions.md`.

## Native features

- windows, menus, tray, app lifecycle and deep links;
- native dialogs, file reveal/open, clipboard and notifications;
- desktop host switcher, SSH ControlMaster/Windows forwarding and tunnel helpers;
- mini chat windows and browser-panel partition security;
- packaged asset loading, bundled OpenCode CLI, auto updater;
- background image asset protocol in this LingXi fork.

Sources: `packages/electron/README.md`, `main.mjs`, `preload.mjs`, `ssh-manager.mjs`, `background-appearance.mjs`.

## Core-boundary finding

No normal Session/Agent business loop is placed in Electron Main. The closest business-adjacent code is local host bootstrap/credentials, desktop-specific quota access and background asset management. Git, terminal, files, tasks and goals remain server modules and are available to non-Electron clients. This aligns with the repository's stated rule: keep domain backend behavior in web/runtime modules unless inherently native.
