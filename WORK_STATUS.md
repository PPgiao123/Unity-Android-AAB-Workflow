# Unity-Android-AAB-Workflow Status (`WORK_STATUS.md`)

Last updated: 2026-11-26. Version: `0.2.0`.

---

## Current Snapshot

- **Scope**: Public, generic Unity Android App Bundle (`.aab`) build, signing, verification, and GitHub Self-Hosted Runner setup toolkit.
- **Direct 1-Click Entry Point**: `Unity-AAB-Tool.cmd` / `Unity-AAB-Tool.ps1` now goes straight into local AAB build + sign + verification without a multi-option interactive menu (pick project -> silent env detection -> keystore/auto-keygen -> signed `.aab` in Explorer -> optional `[y/N]` GitHub Runner setup), while retaining `-Action build|setup|keygen|certinfo|verify|checkenv` for CLI automation.
- **Privacy Guarantee**: Zero real project names, package IDs, SDK/AdMob keys, keystore passwords, or personal file paths are tracked in the repository. Real per-project configs live strictly in gitignored `local-config/`.

---

## Automated Verification Summary

- **`tests/Test-Workflow.ps1`**: **8 / 8 Passed, 0 Failed** (`ExitCode = 0`, verified with `-SampleAabPath`):
  1. PowerShell AST syntax validation across all 7 `.ps1` scripts (`0` syntax errors).
  2. `config/project.example.json` schema & privacy check (no real project configs tracked in `config/`).
  3. Unified `Unity-AAB-Tool.cmd` presence and `workflows/caller-selfhosted-aab.yml` PyYAML parse check.
  4. Synthetic Unity project metadata detection, `Unity-AAB-Tool.ps1 -Action checkenv` (Unity CLI `1.0.0-beta.13`, Unity `6000.3.28f1`, `bundletool-all-1.17.2.jar`), and `Setup-GitHub-Runner.ps1 -DryRun`.
  5. Synthetic ELF64 AArch64 16 KB alignment positive/negative unit tests.
  6. `Sign-Aab.ps1` keystore generation, public cert SHA-256 export, and archive signing round-trip.
  7. Optional real AAB `Verify-Aab.ps1` full gate check (`bundletool validate`, Manifest, `arm64-v8a` 16 KB ELF, `jarsigner`, and negative package/cert rejections).
  8. GitHub remote SSH/HTTPS auto-detection (`Resolve-GitHubRepoFromProject` + `Setup-GitHub-Runner.ps1 -DryRun`), zero preset-project menu check, and `gh.exe` detection check.
- **Privacy Scan**: `0` occurrences of real project names, package IDs, AdMob IDs, or personal file paths across all tracked/staged files.
