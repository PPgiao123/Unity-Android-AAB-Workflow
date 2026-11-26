# Unity Android AAB Workflow

A universal, zero-secret-leakage toolchain for building, signing, and verifying Google Play Android App Bundles (`.aab`) for any Unity project on Windows — either **locally in one click** or via a **GitHub Actions Self-Hosted Runner**.

```text
Unity-AAB-Tool.cmd (Direct 1-Click Local Build)
  ├── 1. Pick Unity project directory (or drag & drop path)
  ├── 2. Silently detect Unity Editor / AndroidPlayer / bundletool & release info
  ├── 3. Auto-use or create upload .p12 keystore (single in-memory password prompt)
  ├── 4. Build + Sign + Verify AAB & highlight the .aab in Explorer
  └── 5. Optional [y/N]: Configure GitHub Secrets & Self-Hosted Runner
```

---

## Quick Start

Double-click **`Unity-AAB-Tool.cmd`** in the repository root, pick your Unity project folder, enter the keystore password once, and it builds, signs, and verifies your `.aab` directly — no menus or manual environment checks.

For scripting or CI automation, invoke individual actions directly from PowerShell:

```powershell
# Direct CLI examples
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Unity-AAB-Tool.ps1" -Action build -ProjectPath "C:\Projects\MyUnityGame" -QaSigning
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Unity-AAB-Tool.ps1" -Action verify -AabPath ".\out\MyGame.aab"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Unity-AAB-Tool.ps1" -Action setup
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Unity-AAB-Tool.ps1" -Action checkenv -ProjectPath "C:\Projects\MyUnityGame"
```

---

## Key Features

1. **Unified Single Entry Point (`Unity-AAB-Tool.cmd`)**:
   - One launcher for building, verifying, generating upload keystores, inspecting environment tools, and setting up GitHub Actions.
2. **Strict Google Play AAB Verification Gate (`Verify-Aab.ps1`)**:
   - Runs `bundletool validate` & `bundletool dump manifest` (`package`, `versionName`, `versionCode`, `minSdkVersion`, `targetSdkVersion`, plus configurable `requiredPermissions`, `requiredMetaData`, `requiredFeatures`).
   - Inspects every `.so` under `base/lib/arm64-v8a/` for `libil2cpp.so` presence and **16 KB ELF `PT_LOAD` page alignment**.
   - Verifies APK/AAB signature with `jarsigner -verify`, checks upload certificate SHA-256 fingerprint via `keytool -printcert`, and verifies `.aab.sha256`.
3. **Zero-Leakage Post-Build Signing (`Sign-Aab.ps1`)**:
   - Never passes keystore passwords or Base64 private keys on CLI arguments.
   - Exports an unsigned staging AAB first (clearing password environment variables during Unity/Gradle execution), clears stale Gradle Daemons and `aapt2` transform caches, strips staging `META-INF` signatures, signs via `jarsigner -storepass:env`, and wipes temporary files in `finally`.
4. **One-Click GitHub Self-Hosted Runner Setup (`Setup-GitHub-Runner.ps1`)**:
   - Prompts you to select a target Unity project and GitHub repository (`owner/repo`).
   - Detects `gh` (`GitHub CLI`); if missing, asks for your permission before downloading and SHA-256 verifying the official MSI from `cli/cli`.
   - Encrypts and uploads all 4 Android signing Secrets (`ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_CERT_SHA256`) via `gh secret set` stdin (no manual web copy-paste).
   - Requests a runner registration token via GitHub API, downloads and SHA-256 verifies official `actions/runner`, registers the runner locally, and creates a `Start-<Project>-Runner.cmd` launcher.

---

## Local Project Configs (`local-config/`)

Copy [config/project.example.json](config/project.example.json) into `local-config/<your-game>.json` (automatically ignored by `.gitignore` and auto-discovered by `Unity-AAB-Tool.cmd`).

---

## Self-Hosted GitHub Actions Usage

1. Copy [workflows/caller-selfhosted-aab.yml](workflows/caller-selfhosted-aab.yml) into your Unity repository as `.github/workflows/android-aab.yml` and replace the `__PROJECT_NAME__`, `__RUNNER_LABEL__`, `__CONFIG_FILE__`, and `<OWNER>` placeholders (or pass inline `-PackageName`, `-ExecuteMethod`, `-RequiredPermissions`, `-RequiredMetaData` parameters to `Build-Unity-Aab.ps1`).
2. Run `Unity-AAB-Tool.cmd` (answer `y` when prompted after a local build) or `powershell -NoProfile -ExecutionPolicy Bypass -File ".\Unity-AAB-Tool.ps1" -Action setup` to upload your 4 encrypted signing Secrets once and bind your local runner (no plaintext passwords are ever saved locally, and future GitHub Actions runs require zero password prompts).
3. Whenever you want a signed AAB: launch `Start-MyUnityGame-Runner.cmd` on Windows and click **`Run workflow`** in `example-org/MyUnityGame` on GitHub Actions, then download the verified `.aab` from Artifacts (or Draft Release) and upload it to Google Play Console.

---

## Repository Structure

| File | Description |
| :--- | :--- |
| `Unity-AAB-Tool.cmd` / `Unity-AAB-Tool.ps1` | Direct 1-click local AAB builder & CLI action dispatcher |
| `Build-Unity-Aab.ps1` | Unity CLI / Editor staging AAB builder + signing + verification orchestrator |
| `Sign-Aab.ps1` | Keystore generator, cert SHA-256 exporter, and post-build `jarsigner` signer |
| `Verify-Aab.ps1` | Standalone Google Play AAB gate (`bundletool` + Manifest + `arm64-v8a` + 16 KB ELF + `jarsigner`) |
| `Setup-GitHub-Runner.ps1` | Interactive GitHub Secrets uploader & Self-Hosted Runner installer |
| `tools/Common.ps1` | Shared Unity CLI / Editor / AndroidPlayer / Gradle cache / ELF 16 KB helpers |
| `tools/UnityAabBuildBridge.cs` | Temporary generic Editor AAB exporter (auto-removed in `finally` when no custom `executeMethod` is specified) |
| `config/project.example.json` | Generic template config (place real project configs in gitignored `local-config/`) |
| `workflows/caller-selfhosted-aab.yml` | Reusable Self-Hosted AAB workflow template for Unity repositories |
| `tests/Test-Workflow.ps1` | Self-contained automated validation and regression suite |
