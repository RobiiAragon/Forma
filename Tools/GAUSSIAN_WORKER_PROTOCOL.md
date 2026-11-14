# Local macOS Gaussian worker

`FormaGaussianWorker.mm` runs the native Metal trainer in a separate process. App visibility, stdin closure and a disconnected stdout pipe do not pause training. `NSProcessInfo` activity keeps an active reconstruction eligible for execution without App Nap; ordinary system shutdown/forced termination still applies. No ComfyUI, server, model download, account, subscription or training quota is used.

Build for the current Apple Silicon Mac without changing the iPhone native artifacts:

```sh
FORMA_CMAKE_PATH=/path/to/cmake bash Tools/build_gaussian_worker.sh /path/to/output
```

The output contains the signed executable, matching `msplat-macos.metallib`, licenses and `worker-artifacts.json`. The manifest records SHA-256 hashes of both artifacts, the native archive, the ABI version, and a fingerprint of the native source/header/shader files, CMake file, helper source, build script and verifier. Copy the helper into `Contents/Helpers/FormaGaussianWorker`, and the Metal library/manifest into `Contents/Resources`. Xcode may re-sign the child with CodeSignOnCopy: final verification compares the helper after removing its signature from temporary copies only. Build outputs and the actual packaged child keep their signatures. The shader and manifest must match exactly. Use their actual installed paths. The native ABI handshake rejects an incompatible shader before any training buffers are used. This helper has not been implemented or validated for Windows.

The Mac pre-build check verifies only; it does not silently rebuild a mismatched worker. Final delivery also verifies the actual packaged child/resources:

```sh
python3 Tools/verify_gaussian_worker.py --output build/GaussianDesktopWorker
python3 Tools/verify_gaussian_worker.py --output build/GaussianDesktopWorker --app /path/to/FormaDesktop.app
```

`--record --output <directory>` is used by the helper build script only after compilation, shader publication and signing. A changed source file, old copied Metal library, modified native archive or stale packaged helper fails verification and asks for a rebuild. The separate real Metal/process acceptance remains available as `python3 Tools/verify_gaussian_worker.py <worker> <metallib> <new-owned-test-output>`.

Launch one process per workspace:

```sh
FormaGaussianWorker --config trabajo.json
```

Example configuration:

```json
{
  "schemaVersion": 1,
  "jobID": "616FCE4E-A4F3-4A1D-B51C-779B206852A1",
  "datasetPath": "/absolute/path/to/calibrated/dataset",
  "workspacePath": "/absolute/path/to/owned/workspace",
  "metallibPath": "/absolute/path/to/msplat-macos.metallib",
  "targetIterations": 3000,
  "downscale": 1,
  "checkpointIntervalSeconds": 30,
  "progressIntervalSeconds": 0.5,
  "initiallyPaused": false,
  "resumeOnLaunch": false
}
```

Optional `resumePath` reads an external checkpoint without modifying it. Subsequent checkpoints belong to the workspace. A factor of `1` keeps native captured resolution; no silent reduction is applied. Checkpoint interval `0` disables periodic saving, without changing explicit pause/checkpoint/cancel saving. Numeric values must fit the native API. Sources and workspace must be independent directories.

`status.json` is replaced atomically on each actual state change and throttled progress event. Stdout emits the same snapshots as newline-delimited JSON prefixed with `FORMA_GAUSSIAN `; ignore native engine log lines lacking that prefix. Snapshots include `schemaVersion`, `jobID`, `pid`, `phase`, `message`, `iteration`, `targetIterations`, `splats`, `progress`, `millisecondsPerStep`, `downscale`, `updatedAt` (Unix seconds), `elapsedSeconds`, `checkpointStep`, `controlOffset`, `runtimeABI` and optional `checkpointPath`, `resultPath`, `commandID`, `commandState`, `error`. `progress` counts committed training iterations, not export bytes.

Phases: `preparing`, `running`, `checkpointing`, `pausing`, `paused`, `exporting`, `completed`, `cancelled`, `failed`. Terminal `completed` means all exports and the complete optimizer checkpoint were written successfully. A process that disappears without a terminal snapshot was interrupted; the app should offer the last checkpoint, not report completion.

Send commands as complete NDJSON lines on stdin or append them to `workspace/control.ndjson`. Do not truncate/rewrite the control file while its worker is alive. Include a unique `commandID`; optional `jobID` is checked against the workspace:

```json
{"jobID":"616FCE4E-A4F3-4A1D-B51C-779B206852A1","commandID":"unique-request-id","command":"pause"}
```

Commands: `pause`, `resume`, `checkpoint`, `export`, `cancel`. Acknowledgment progresses from `commandState: accepted` to `completed` or `rejected`. A `paused` snapshot is issued only after a safe native boundary, checkpoint creation and engine destruction. Resume recreates the engine from that complete checkpoint. Cancel similarly preserves a checkpoint and exits with status `130`. SIGINT/SIGTERM request that same cooperative cancellation. Native loading, a training step or export cannot be interrupted in the middle of a GPU/file operation.

The workspace is locked with `flock`; a second worker for the same workspace fails before changing its status. On recovery, `controlOffset` prevents replaying consumed durable commands. A previously confirmed manual pause survives relaunch; `resumeOnLaunch: true` requests explicit continuation. With no external `resumePath`, the last owned checkpoint is selected automatically. Changing the dataset or resolution requires a different workspace.

Exports are generated in a new staging folder and published under `workspace/exports/<iteration>-<UUID>` after all files succeed. `resultPath` points to the package containing `gaussianas.ply` (SH3), `gaussianas.splat` (base color), `entrenamiento.ckpt` and `gaussianas.json`. The app can import that package as a new library capture, retaining the source scan. Failures preserve owned workspaces, incomplete staging files and previous checkpoints for diagnosis/recovery.
