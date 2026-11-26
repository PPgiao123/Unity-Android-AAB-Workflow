# Unity-Android-AAB-Workflow Engineering Guidelines

## 1. Repository Scope & Privacy

1. **Zero Project-Specific Data in Public Repo**:
   - Never commit real game project names, package IDs, AdMob/SDK keys, personal filesystem paths, `.p12`/`.keystore` files, passwords, or service account JSONs into this repository.
   - Store local per-project configs exclusively under `local-config/` (excluded by `.gitignore`).
2. **Git Discipline**:
   - Never commit or push automatically without explicit user authorization.

---

## 2. Security, Compatibility & Verification Gates

1. **Windows PowerShell 5.1 Compatibility**:
   - All `.ps1` scripts must remain compatible with Windows PowerShell 5.1 with `$ErrorActionPreference = 'Stop'` and `Set-StrictMode -Version Latest`.
2. **Zero Secret Leakage in CLI Arguments or Logs**:
   - Never pass keystore passwords or Base64 private keys on command-line arguments.
   - Always build an unsigned staging AAB first (with signing password environment variables temporarily cleared), then sign post-build via `jarsigner -storepass:env` / `-keypass:env` or pipe Secrets to `gh secret set` via stdin.
   - Overwrite temporary certificate/keystore files with zero bytes before deletion in `finally`.
3. **Process Output Redirection**:
   - Use redirected `stdout`/`stderr` files and explicit timeouts when invoking Unity, Gradle, `bundletool`, `jarsigner`, or `keytool` to prevent Windows pipe/Gradle daemon hangs.
4. **Google Play AAB Verification Gate**:
   - Every signed AAB must pass: `bundletool validate`, `bundletool dump manifest` (`package`, `versionName`, `versionCode`, `minSdkVersion`, `targetSdkVersion`, plus optional permissions/meta-data/features), `arm64-v8a` `libil2cpp.so` + **16 KB ELF `PT_LOAD` alignment**, `jarsigner -verify -strict -keystore`, signing certificate SHA-256 verification, and `.aab.sha256` checksum verification.
