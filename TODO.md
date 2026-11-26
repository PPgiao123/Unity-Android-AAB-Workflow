# Unity-Android-AAB-Workflow TODO

Current remaining items: **2** (P0: 0, P1: 1, P2: 1)

---

## P0 (Cleared)

- None.

---

## P1 Enhancements

- [ ] `[TODO-P1-02]` **Interactive Local Config Generator (`Init-ProjectConfig.ps1`)**: Auto-detect package name, version, `Release.json` path, and keystore details for a selected Unity project and save under gitignored `local-config/`.

---

## P2 Long-Term

- [ ] `[TODO-P2-01]` **Optional Standalone Portable GUI / `.exe` Wrapper**: Package a lightweight Windows GUI launcher for non-CLI distribution.

---

## Completed Archive

### P0 Completed
- [x] `[TODO-P0-01]` **Universal Unity Android AAB build, sign, and verification toolchain (`v0.1.0`)**: Implemented `tools/Common.ps1`, `tools/UnityAabBuildBridge.cs`, `Build-Unity-Aab.ps1`, `Sign-Aab.ps1`, `Verify-Aab.ps1`, `config/project.example.json`, and `tests/Test-Workflow.ps1`.

### P1 Completed
- [x] `[TODO-P1-01]` **Unified `Unity-AAB-Tool.cmd` Menu, Self-Hosted Runner Setup & Privacy Cleanup**: Consolidated all entry points into `Unity-AAB-Tool.cmd` / `.ps1`, added `Setup-GitHub-Runner.ps1` (with consent-gated `gh` auto-install, stdin secret upload, and runner registration) + `workflows/caller-selfhosted-aab.yml`, and removed all private project metadata and unused auto-upload files from the public repository.
