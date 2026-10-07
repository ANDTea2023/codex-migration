# Codex Home Migration for Windows

This repository contains a PowerShell helper for moving the Codex home directory to another local drive while preserving the original directory layout, file contents, access permissions, internal junctions, and the Windows sandbox service lifecycle.

The helper is deliberately fail-closed: it verifies the source and destination before switching the root to a junction, retains a rollback directory until the user validates Codex, and restores the original directory if a post-rename step fails.

## Tested environment

The production run that motivated this repository used:

- Windows build `26300`, 64-bit, preview-style `26H2` build.
- The same machine reported `Windows 10 Pro` through the registry and `Windows 11 Pro` through WMI; the build number is the reliable compatibility detail.
- PowerShell `7.6.5` and Windows PowerShell `5.1` compatibility.
- Built-in Windows `robocopy`.
- Codex Windows sandbox service named `CodexSandboxService.OpenAI.Codex`.

Other Windows versions may use a different Codex service name or service permissions. Check the service name before adapting the helper.

## Before you run it

1. Make a separate backup of irreplaceable data. This helper keeps a rollback copy, but it is not a substitute for a backup.
2. Use a local NTFS destination with enough free space for the Codex home plus at least 2 GiB.
3. Start the helper from an independent Windows Terminal or PowerShell window. Do not start it from a Codex terminal: closing Codex can close its child terminal and terminate the migration.
4. Keep the external window open and visible. When `[1/5 WAIT]` appears, close Codex and keep it closed until `SUCCESS` or a completed failure message appears.
5. Run with an account that can stop and start the Codex sandbox service and create a directory junction. Elevation may be required by local policy.

## Usage

The production mode requires an explicit destination root. The source defaults to `%USERPROFILE%\.codex` so no username is embedded in the script.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\migrate-codex-home.ps1 `
  -DataRoot 'D:\CodexData'
```

Use `-CodexHome` only when the source is in a non-default location:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\migrate-codex-home.ps1 `
  -DataRoot 'D:\CodexData' `
  -CodexHome 'C:\Users\<account>\.codex'
```

The helper writes logs and a journal below `-DataRoot`. Do not publish those files without removing absolute paths, PIDs, timestamps, service names, and file names.

The five visible stages are:

1. **WAIT**: wait for Codex processes to exit.
2. **SERVICE / INVENTORY**: stop only the named sandbox service, capture the complete source manifest, and check that every file is readable.
3. **COPY**: copy data, timestamps, ACLs, SQLite sidecars, and internal junctions. The sandbox binary tree is handled separately when its DACL requires it.
4. **VERIFY**: compare manifests, SHA-256 hashes, file and directory permissions, timestamps, and junction targets.
5. **SWITCH**: rename the original directory to a timestamped rollback path, create the root junction, verify it, restore the service, and print `SUCCESS` only after restoration succeeds.

If a run is interrupted after the source rename, keep Codex closed and run recovery from the same independent window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\migrate-codex-home.ps1 `
  -DataRoot 'D:\CodexData' `
  -RecoverOnly
```

Do not remove the `*.before-migration.*` rollback directory until Codex history, settings, plugins, and a new write have been checked. After validation, it can be removed manually to reclaim the original drive space.

## What changed from v1 to v8

The version history is included because each failure exposed a different Windows boundary:

| Version | Failure | Resolution |
| --- | --- | --- |
| v1 | `robocopy /COPYALL` returned exit code 16 because the account lacked the **Manage Auditing** privilege. | Copy data, attributes, timestamps, and standard ACLs with `/COPY:DATS /DCOPY:DAT`; do not request SACL auditing data. |
| v2 | Protected `.sandbox-bin` files returned access denied during the normal copy. | Exclude that tree from the general copy and copy it with a dedicated DAT/ACL path. |
| v3 | The provisioning guard file changed or could not be read while the sandbox was active. | Add source readability and zero-byte/exclusive guard checks, then identify the exact service holding the file. |
| v4/v5 | A full hash pass still hit a service-held guard; later, the final directory move returned access denied. | Persist service-restore intent, stop and restore the exact sandbox service, check locks before copying, and add a guarded rename probe. |
| v6 | A rename could fail after a long copy even though the copy was correct. | Probe the source rename before inventory and again before switching; preserve both copies if the probe fails. |
| v7 | Temporary sharing/access errors occurred during rename. | Retry only Win32 errors 5, 32, and 33 for a bounded period (five-second intervals, 300 seconds in production). |
| v7 incident | PowerShell console QuickEdit entered Select mode, pausing output while Codex changed the source; the inventory became stale. | Run externally, disable QuickEdit for this invocation, restore the console mode in `finally`, and re-check Codex immediately before reading the inventory. |
| v8 | The complete guarded run succeeded. | Keep all previous checks, journal every phase, verify hashes/ACLs/manifests/junctions, restore the service, and report success only afterward. |

Earlier attempts also showed why an embedded Codex terminal is unsafe for a migration process: closing the app can close the terminal and leave no independent process to finish or report recovery.

## Failure and rollback behavior

- Failure before the source rename leaves the original directory untouched and preserves the destination for inspection or a guarded retry.
- Failure after the source rename attempts to move the rollback directory back to the original path. If that cannot be completed, the journal prints `RECOVERY REQUIRED` and the `-RecoverOnly` path is the supported recovery route.
- Failure after junction creation removes the junction and restores the original directory before returning failure.
- Failure to start the sandbox service after a successful switch triggers a rollback attempt; the helper does not claim success while service restoration is pending.
- The journal is written atomically and includes a `SandboxServiceRestorePending` flag so forced termination can be recovered safely.

## Privacy and customization

The published script contains no username, API key, token, cookie, password, chat content, or machine-specific migration result. Source and destination paths are parameters; the default source is resolved from the current `%USERPROFILE%` at runtime.

The service name is an operational default, not a secret. If a future Codex build changes it, update the service lookup and the README example after verifying the new service in `Get-Service`.

Do not commit production logs, `migration-state.json`, rollback directories, fixture data, or old local copies of the script. Logs can reveal absolute paths, process IDs, service names, temporary plugin paths, and file names even when they contain no credentials.

## License

Add the license that matches how you want others to reuse the helper before accepting external contributions.
