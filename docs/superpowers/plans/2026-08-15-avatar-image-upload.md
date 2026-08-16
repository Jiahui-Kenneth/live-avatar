# Avatar Image Upload and Hot-Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a secure image upload, 3:4 crop preview, Wav2Lip avatar generation, catalog, and rollback-safe hot switch inside the existing 7860 Settings dialog.

**Architecture:** The browser crops locally and submits a 576×768 JPEG to authenticated LiveTalking management endpoints. LiveTalking validates the image, reuses the existing asynchronous Wav2Lip generator through a staging directory, persists avatar metadata, and loads the selected avatar through `/offer`. The parent page explicitly closes the old avatar session, waits for removal, creates the new session, and rolls back on failure while leaving the s2s/LLM conversation alive.

**Tech Stack:** Python 3.11, aiohttp, OpenCV, existing S3FD/Wav2Lip code, FastAPI demo configuration, ES modules, Canvas 2D, WebRTC, Node.js built-in test runner, Windows PowerShell/batch launchers.

## Global Constraints

- First release supports Windows 10/11 and NVIDIA RTX 20/30/40/50 only.
- All runtime services continue to bind to loopback; no new route may expose a filesystem path.
- Image input is JPEG, PNG, or WebP, no more than 10 MiB, and becomes exactly 576×768 before upload.
- RTX 50/Blackwell keeps PyTorch `2.11.0+cu128`, torchvision `0.26.0+cu128`, torchaudio `2.11.0+cu128`, CUDA 12.8, and `sm_120` support.
- speech-to-speech remains pinned to `656099afffda445a3a3cef8ffee55871c9b6123c`; LiveTalking remains pinned to `c963ad409c556918b7d23999bf87c47a7c05c932`.
- Existing video avatar task endpoints remain backward-compatible.
- Temporary source images and videos are deleted after success or failure; existing avatars are never overwritten.
- The active, built-in, or in-use avatar cannot be deleted.
- A switch must end with exactly one active LiveTalking WebRTC session; failure restores the prior avatar.
- Root integration patches remain the deployable source of truth. New upstream files must be marked intent-to-add before regenerating a patch.

---

## File Map

### LiveTalking upstream checkout and integration patch

- Create `deps/LiveTalking/server/avatar_store.py`: atomic metadata, active avatar, catalog, staging commit, deletion rules.
- Create `deps/LiveTalking/server/avatar_image.py`: image decode/validation, S3FD preflight, still-video writer.
- Create `deps/LiveTalking/server/avatar_auth.py`: short-lived HMAC capability, Origin, and loopback checks.
- Modify `deps/LiveTalking/server/avatar_routes.py`: image task, catalog, active, thumbnail, delete, close-session endpoints.
- Modify `deps/LiveTalking/server/task_manager.py`: stages, result data, success/finally callbacks.
- Modify `deps/LiveTalking/server/rtc_manager.py`: map PeerConnections to session IDs and explicitly close one session.
- Modify `deps/LiveTalking/server/routes.py`: pass dependencies to avatar routes and retain existing APIs.
- Modify `deps/LiveTalking/app.py`: initialize store/auth configuration and expose RTC manager.
- Modify `deps/LiveTalking/avatars/wav2lip/genavatar.py`: reject missing face rather than treating the full frame as a face.
- Create `deps/LiveTalking/tests/test_avatar_store.py`.
- Create `deps/LiveTalking/tests/test_avatar_image.py`.
- Create `deps/LiveTalking/tests/test_avatar_auth.py`.
- Create `deps/LiveTalking/tests/test_avatar_routes.py`.
- Create `deps/LiveTalking/tests/test_rtc_session_close.py`.
- Modify `patches/livetalking-integration.patch`: binary-safe aggregate of all LiveTalking changes.

### Embed and s2s demo

- Modify `web/embed.html`: avatar query parsing, explicit shutdown, session/connection messages, retry cancellation.
- Create `deps/speech-to-speech/demo/ui/avatar-cropper.js`: pure crop geometry and Canvas export.
- Create `deps/speech-to-speech/demo/ui/avatar-api.js`: authenticated API client and task polling.
- Create `deps/speech-to-speech/demo/ui/avatar-manager.js`: Settings state and rollback-safe switch coordinator.
- Create `deps/speech-to-speech/demo/ui/avatar-cropper.test.mjs`.
- Create `deps/speech-to-speech/demo/ui/avatar-api.test.mjs`.
- Create `deps/speech-to-speech/demo/ui/avatar-manager.test.mjs`.
- Modify `deps/speech-to-speech/demo/index.html`: avatar controls and crop dialog.
- Modify `deps/speech-to-speech/demo/main.js`: initialize AvatarManager and connect it to conversation state/mic control.
- Modify `deps/speech-to-speech/demo/style.css`: cropper, progress, catalog, and responsive styles.
- Modify `deps/speech-to-speech/demo/server.py`: return LiveTalking origin and page capability from `/api/config`.
- Create `deps/speech-to-speech/demo/avatar_capability.py`: mint the shared short-lived page capability without exposing the master token.
- Create `deps/speech-to-speech/tests/test_demo_avatar_config.py`.
- Modify `patches/s2s-integration.patch`: binary-safe aggregate of all s2s changes.

### Shared launch/config/docs

- Create `scripts/ensure_avatar_security.ps1`: create/read the per-install 32-byte token atomically.
- Modify `scripts/start_demo.bat` and `scripts/start_livetalking.bat`: load the shared token and allowed origins.
- Modify `scripts/config.local.bat.example`: document `LIVE_AVATAR_DATA_DIR`, `LIVETALKING_URL`, and optional token-file override.
- Modify `README.md` and `docs/DEPLOYMENT.md`: image upload, data location, recovery, and API security.

---

### Task 1: Atomic Avatar Store and Metadata

**Files:**
- Create: `deps/LiveTalking/server/avatar_store.py`
- Create: `deps/LiveTalking/tests/test_avatar_store.py`
- Modify: `patches/livetalking-integration.patch`

**Interfaces:**
- Produces: `AvatarStore(data_root: Path, builtin_ids: set[str])`.
- Produces: `AvatarStore.list_avatars() -> list[dict]`, `get_active() -> dict`, `activate(avatar_id, session_avatar_id) -> dict`, `commit_staging(staged_avatar, metadata) -> Path`, `delete(avatar_id, in_use_ids) -> None`.
- Persists: `<data_root>/config/active-avatar.json` and `<data_root>/avatars/<avatar_id>/metadata.json`.

- [ ] **Step 1: Write failing store tests**

```python
import json
import tempfile
import unittest
from pathlib import Path

from server.avatar_store import AvatarConflict, AvatarStore


class AvatarStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = AvatarStore(self.root, {"myavatar"})

    def tearDown(self):
        self.tmp.cleanup()

    def make_avatar(self, avatar_id: str) -> Path:
        staged = self.root / "temp" / avatar_id
        (staged / "full_imgs").mkdir(parents=True)
        (staged / "face_imgs").mkdir()
        (staged / "full_imgs" / "00000000.png").write_bytes(b"full")
        (staged / "face_imgs" / "00000000.png").write_bytes(b"face")
        (staged / "coords.pkl").write_bytes(b"coords")
        return staged

    def test_commit_activate_and_list(self):
        staged = self.make_avatar("avatar_abc")
        self.store.commit_staging(staged, {"avatar_id": "avatar_abc", "display_name": "Alice"})
        self.store.activate("avatar_abc", "avatar_abc")
        item = self.store.list_avatars()[0]
        self.assertEqual(item["avatar_id"], "avatar_abc")
        self.assertTrue(item["active"])

    def test_delete_rejects_active_builtin_and_in_use(self):
        with self.assertRaises(AvatarConflict):
            self.store.delete("myavatar", set())
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe -m unittest tests.test_avatar_store -v
```

Expected: import fails because `server.avatar_store` does not exist.

- [ ] **Step 3: Implement the store**

Implement atomic JSON writes with a sibling temporary file and `os.replace`:

```python
class AvatarStore:
    def __init__(self, data_root: Path, builtin_ids: set[str]):
        self.data_root = Path(data_root).resolve()
        self.avatars_root = self.data_root / "avatars"
        self.config_root = self.data_root / "config"
        self.builtin_ids = frozenset(builtin_ids)
        self.avatars_root.mkdir(parents=True, exist_ok=True)
        self.config_root.mkdir(parents=True, exist_ok=True)

    def _write_json(self, path: Path, value: dict) -> None:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)

    def commit_staging(self, staged_avatar: Path, metadata: dict) -> Path:
        avatar_id = validate_avatar_id(metadata["avatar_id"])
        target = self.avatars_root / avatar_id
        if target.exists():
            raise AvatarConflict("avatar already exists")
        for required in ("full_imgs", "face_imgs", "coords.pkl"):
            if not (staged_avatar / required).exists():
                raise AvatarInvalid(f"missing generated asset: {required}")
        self._write_json(staged_avatar / "metadata.json", metadata)
        os.replace(staged_avatar, target)
        return target
```

Use `^[a-z0-9][a-z0-9_-]{2,63}$` for IDs. `activate` must compare `session_avatar_id == avatar_id` before writing. `delete` must reject built-in, active, and `in_use_ids` before calling `shutil.rmtree` on the resolved child of `avatars_root`.

- [ ] **Step 4: Run GREEN and patch preflight**

Run the unittest command again. Expected: all tests pass. Then run:

```powershell
git -c safe.directory=E:/AI/AI-Girlfriend2/deps/LiveTalking -C E:\AI\AI-Girlfriend2\deps\LiveTalking add -N -- server/avatar_store.py tests/test_avatar_store.py
git -c safe.directory=E:/AI/AI-Girlfriend2/deps/LiveTalking -C E:\AI\AI-Girlfriend2\deps\LiveTalking diff --binary --output=E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b\patches\livetalking-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b diff --check
```

Expected: no whitespace errors.

- [ ] **Step 5: Commit the store**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add patches/livetalking-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: add atomic avatar metadata store"
```

### Task 2: Image Validation, Face Preflight, and Still Video

**Files:**
- Create: `deps/LiveTalking/server/avatar_image.py`
- Create: `deps/LiveTalking/tests/test_avatar_image.py`
- Modify: `deps/LiveTalking/avatars/wav2lip/genavatar.py`
- Modify: `patches/livetalking-integration.patch`

**Interfaces:**
- Consumes: Wav2Lip S3FD `FaceAlignment.face_detector.detect_from_image`.
- Produces: `validate_avatar_image(payload: bytes, detect_faces: Callable) -> ValidatedImage`.
- Produces: `write_still_video(image_bgr: np.ndarray, target: Path, fps: int = 25, frames: int = 25) -> None`.
- Produces errors with stable codes: `image_too_large`, `invalid_image`, `wrong_dimensions`, `no_face`, `multiple_faces`, `face_too_small`.

- [ ] **Step 1: Write failing validation tests**

```python
class AvatarImageTest(unittest.TestCase):
    def encoded(self, width=576, height=768):
        image = np.zeros((height, width, 3), dtype=np.uint8)
        ok, data = cv2.imencode(".jpg", image)
        self.assertTrue(ok)
        return data.tobytes()

    def test_accepts_one_large_face(self):
        out = validate_avatar_image(
            self.encoded(),
            lambda image: [(160, 120, 416, 500, 0.99)],
        )
        self.assertEqual(out.image_bgr.shape, (768, 576, 3))

    def test_rejects_multiple_significant_faces(self):
        with self.assertRaisesRegex(AvatarImageError, "multiple_faces"):
            validate_avatar_image(
                self.encoded(),
                lambda image: [(50, 50, 250, 300, .99), (300, 80, 500, 330, .96)],
            )

    def test_rejects_face_smaller_than_minimum_wav2lip_crop(self):
        with self.assertRaisesRegex(AvatarImageError, "face_too_small"):
            validate_avatar_image(self.encoded(), lambda image: [(0, 0, 60, 60, .99)])
```

- [ ] **Step 2: Run RED**

```powershell
E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe -m unittest tests.test_avatar_image -v
```

Expected: import fails because `server.avatar_image` does not exist.

- [ ] **Step 3: Implement validation and video writing**

```python
MAX_IMAGE_BYTES = 10 * 1024 * 1024
TARGET_WIDTH = 576
TARGET_HEIGHT = 768
MIN_FACE_AREA_RATIO = 0.02
MIN_FACE_EDGE = 96

def validate_avatar_image(payload: bytes, detect_faces) -> ValidatedImage:
    if len(payload) > MAX_IMAGE_BYTES:
        raise AvatarImageError("image_too_large", "Image exceeds 10 MiB")
    raw = np.frombuffer(payload, dtype=np.uint8)
    image = cv2.imdecode(raw, cv2.IMREAD_COLOR)
    if image is None:
        raise AvatarImageError("invalid_image", "JPEG, PNG, or WebP required")
    if image.shape[:2] != (TARGET_HEIGHT, TARGET_WIDTH):
        raise AvatarImageError("wrong_dimensions", "Image must be 576x768")
    faces = [box for box in detect_faces(image) if float(box[4]) >= 0.5]
    if not faces:
        raise AvatarImageError("no_face", "No face detected")
    if len(faces) > 1:
        raise AvatarImageError("multiple_faces", "Multiple faces detected")
    x1, y1, x2, y2, _ = faces[0]
    face_width, face_height = max(0, x2-x1), max(0, y2-y1)
    ratio = face_width * face_height / (TARGET_WIDTH * TARGET_HEIGHT)
    if ratio < MIN_FACE_AREA_RATIO or min(face_width, face_height) < MIN_FACE_EDGE:
        raise AvatarImageError("face_too_small", "Face is too small; crop closer")
    return ValidatedImage(image_bgr=image, face_box=(int(x1), int(y1), int(x2), int(y2)))

def write_still_video(image_bgr, target: Path, fps=25, frames=25):
    writer = cv2.VideoWriter(str(target), cv2.VideoWriter_fourcc(*"mp4v"), fps, (576, 768))
    if not writer.isOpened():
        raise AvatarImageError("video_encoder_unavailable", "Cannot create avatar input video")
    try:
        for _ in range(frames):
            writer.write(image_bgr)
    finally:
        writer.release()
```

Add `detect_faces_sfd(image_bgr)` that creates `FaceAlignment(..., device=device)`, passes RGB data to `face_detector.detect_from_image`, returns all boxes, and releases the detector. In `genavatar.py`, replace the `rect is None` full-frame fallback with `raise RuntimeError("No face detected in avatar frame")`.

- [ ] **Step 4: Run GREEN and regenerate the patch**

Run the unittest. Also create a temporary video from the test image and assert OpenCV reads exactly 25 frames. Mark new files intent-to-add, regenerate `livetalking-integration.patch`, and run `git diff --check` as in Task 1.

- [ ] **Step 5: Commit image validation**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add patches/livetalking-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: validate still-image avatar inputs"
```

### Task 3: Per-Install Management Authentication

**Files:**
- Create: `deps/LiveTalking/server/avatar_auth.py`
- Create: `deps/LiveTalking/tests/test_avatar_auth.py`
- Create: `scripts/ensure_avatar_security.ps1`
- Modify: `scripts/start_demo.bat`
- Modify: `scripts/start_livetalking.bat`
- Modify: `scripts/config.local.bat.example`
- Modify: `patches/livetalking-integration.patch`

**Interfaces:**
- Produces: `AvatarAdminGuard(master_token: str, allowed_origins: set[str], now: Callable).require(request) -> None`.
- Produces: `LIVE_AVATAR_ADMIN_TOKEN`, `LIVE_AVATAR_ALLOWED_ORIGINS`, `LIVE_AVATAR_DATA_DIR` in both service processes.
- Produces: token file `<integration-root>/data/config/avatar-admin-token.txt` with 32 random bytes encoded base64url.

- [ ] **Step 1: Write failing authentication tests**

```python
class FakeRequest:
    def __init__(self, capability, origin, host="127.0.0.1:8010"):
        self.headers = {"X-Live-Avatar-Capability": capability, "Origin": origin, "Host": host}

class AvatarAdminGuardTest(unittest.TestCase):
    def setUp(self):
        self.now = 2_000_000_000
        self.origin = "http://127.0.0.1:7860"
        self.guard = AvatarAdminGuard("secret", {self.origin}, now=lambda: self.now)
        self.valid = mint_capability("secret", self.origin, self.now + 300, "nonce")

    def test_accepts_exact_token_origin_and_loopback(self):
        self.guard.require(FakeRequest(self.valid, self.origin))

    def test_rejects_wrong_token_origin_and_non_loopback(self):
        for req in (
            FakeRequest(mint_capability("wrong", self.origin, self.now + 300, "nonce"), self.origin),
            FakeRequest(self.valid, "https://evil.example"),
            FakeRequest(self.valid, self.origin, "192.168.1.5:8010"),
            FakeRequest(mint_capability("secret", self.origin, self.now - 1, "nonce"), self.origin),
        ):
            with self.assertRaises(web.HTTPForbidden):
                self.guard.require(req)
```

- [ ] **Step 2: Run RED**

Run `python -m unittest tests.test_avatar_auth -v`. Expected: missing module.

- [ ] **Step 3: Implement guard and token bootstrap**

Use capability wire format `v1.<expires_unix>.<nonce_base64url>.<signature_base64url>`. The HMAC input is the UTF-8 string `v1\n<origin>\n<expires_unix>\n<nonce>` and the signature is HMAC-SHA256 with the per-install master token. Guard comparison must use `secrets.compare_digest`, reject expiry more than five minutes in the future, and never return the master token. Normalize host with `ipaddress.ip_address`; accept only `127.0.0.0/8` and `::1`.

Implement `ensure_avatar_security.ps1` with an atomic create:

```powershell
param([Parameter(Mandatory=$true)][string]$DataRoot)
$configDir = Join-Path $DataRoot 'config'
$tokenPath = Join-Path $configDir 'avatar-admin-token.txt'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
if (-not (Test-Path -LiteralPath $tokenPath)) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    try { [IO.File]::WriteAllText($tokenPath, $token, [Text.UTF8Encoding]::new($false)) } catch [IO.IOException] {}
}
$value = [IO.File]::ReadAllText($tokenPath).Trim()
if ($value.Length -lt 43) { throw 'Avatar admin token is invalid' }
$value
```

Both batch launchers derive the integration root from `%~dp0..`, default data root to `<root>\data`, invoke the script, and set the same token. Demo gets `LIVE_AVATAR_ADMIN_TOKEN`; LiveTalking also gets `LIVE_AVATAR_ALLOWED_ORIGINS=http://127.0.0.1:7860,http://localhost:7860`.

- [ ] **Step 4: Verify token stability and isolation**

Run the script twice against a temporary directory and assert identical output; run against a second directory and assert different output. Run the Python authentication tests, batch syntax smoke tests, patch regeneration, and `git diff --check`.

- [ ] **Step 5: Commit authentication**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add scripts patches/livetalking-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: secure local avatar management"
```

### Task 4: Asynchronous Image Task and Avatar APIs

**Files:**
- Modify: `deps/LiveTalking/server/task_manager.py`
- Modify: `deps/LiveTalking/server/avatar_routes.py`
- Modify: `deps/LiveTalking/server/routes.py`
- Modify: `deps/LiveTalking/app.py`
- Create: `deps/LiveTalking/tests/test_avatar_routes.py`
- Modify: `patches/livetalking-integration.patch`

**Interfaces:**
- Extends: `TaskManager.add_task(..., stage="queued", on_success=None, on_finally=None) -> str`.
- Extends task JSON with `stage`, `avatar_id`, and `result`.
- Produces: `POST /api/avatar/image-task`, `GET /api/avatar/list`, `GET /api/avatar/active`, `GET /api/avatar/{id}/thumbnail`, `POST /api/avatar/activate`, `DELETE /api/avatar/{id}`.

- [ ] **Step 1: Write failing API tests with injected dependencies**

Create an aiohttp test app with a temporary `AvatarStore`, `AvatarAdminGuard("secret", {origin})`, a valid five-minute capability, and fake task manager. Cover:

```python
async def test_create_image_task_returns_ids(self):
    form = FormData()
    form.add_field("image_file", valid_jpeg, filename="crop.jpg", content_type="image/jpeg")
    form.add_field("display_name", "Alice")
    response = await client.post(
        "/api/avatar/image-task", data=form,
        headers={"Origin": ORIGIN, "X-Live-Avatar-Capability": CAPABILITY},
    )
    body = await response.json()
    self.assertEqual(body["code"], 0)
    self.assertRegex(body["data"]["avatar_id"], r"^avatar_[0-9]{8}_[a-z0-9]{8}$")

async def test_activate_requires_matching_live_session(self):
    response = await client.post(
        "/api/avatar/activate",
        json={"avatar_id": "avatar_abc", "sessionid": "sid-old"},
        headers=ADMIN_HEADERS,
    )
    self.assertEqual((await response.json())["code"], -1)
```

Also test anonymous rejection, invalid image code, list/active shape, thumbnail traversal rejection, and protected deletion.

- [ ] **Step 2: Run RED**

```powershell
E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe -m unittest tests.test_avatar_routes -v
```

Expected: the image route and dependency-aware setup signature are absent.

- [ ] **Step 3: Implement task stages and routes**

Use callbacks without serializing callables:

```python
class AvatarTask:
    def __init__(..., stage="queued", on_success=None, on_finally=None):
        self.stage = stage
        self.result = {}
        self.on_success = on_success
        self.on_finally = on_finally

def progress_callback(p):
    task.progress = int(p)
    task.stage = "generating"

# after generate_avatar returns
if task.on_success:
    task.result = task.on_success(task) or {}
task.status = "completed"
task.stage = "completed"

# finally
if task.on_finally:
    task.on_finally(task)
```

The image route validates before queuing, writes the 25-frame video under `<data>/temp/<task_id>/input.mp4`, uses `<data>/temp/<task_id>/generated` as `save_path`, and supplies callbacks that atomically commit and clean the task directory. Generate IDs with UTC date plus eight lowercase hex characters. Resolve active sessions from `session_manager.sessions` for activate/delete checks.

Pass `store`, `guard`, `task_manager`, and `session_manager` into `setup_avatar_routes`; production construction occurs in `app.py`, tests provide fakes.

- [ ] **Step 4: Run route and legacy regressions**

Run all five LiveTalking unittest modules and `python app.py --help`. Expected: tests pass and existing `POST /api/avatar/task` remains registered. Regenerate the patch and run `git diff --check`.

- [ ] **Step 5: Commit APIs**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add patches/livetalking-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: add image avatar task APIs"
```

### Task 5: Explicit WebRTC Session Close and Embed Protocol

**Files:**
- Modify: `deps/LiveTalking/server/rtc_manager.py`
- Modify: `deps/LiveTalking/server/avatar_routes.py`
- Create: `deps/LiveTalking/tests/test_rtc_session_close.py`
- Modify: `web/embed.html`
- Modify: `patches/livetalking-integration.patch`

**Interfaces:**
- Produces: `await RTCManager.close_session(sessionid: str) -> bool`.
- Produces: authenticated `DELETE /api/avatar/session/{sessionid}`.
- Embed consumes query `avatar`; posts `{type: "lt-session", sessionid, avatarId}` and `{type: "lt-state", state, avatarId}`.
- Embed consumes `{type: "lt-stop"}` and responds `{type: "lt-stopped", sessionid, avatarId}` without reconnecting.

- [ ] **Step 1: Write failing RTC close tests**

```python
class FakePc:
    def __init__(self): self.closed = False
    async def close(self): self.closed = True

class RTCSessionCloseTest(IsolatedAsyncioTestCase):
    async def test_close_session_closes_pc_and_removes_avatar_session(self):
        manager = RTCManager(SimpleNamespace())
        pc = FakePc()
        manager.session_pcs["sid"] = pc
        session_manager.sessions["sid"] = object()
        self.assertTrue(await manager.close_session("sid"))
        self.assertTrue(pc.closed)
        self.assertNotIn("sid", session_manager.sessions)
        self.assertNotIn("sid", manager.session_pcs)
```

- [ ] **Step 2: Run RED**

Run `python -m unittest tests.test_rtc_session_close -v`. Expected: `session_pcs`/`close_session` absent.

- [ ] **Step 3: Implement the map, close endpoint, and embed messages**

Keep the existing `pcs` set and add a session map:

```python
self.session_pcs: dict[str, RTCPeerConnection] = {}

async def close_session(self, sessionid: str) -> bool:
    pc = self.session_pcs.pop(sessionid, None)
    if pc is None:
        session_manager.remove_session(sessionid)
        return False
    await pc.close()
    self.pcs.discard(pc)
    session_manager.remove_session(sessionid)
    return True
```

Register the map in `_create_pc_and_answer`, and remove it in the existing connection-state handler and shutdown.

In `embed.html`, compute:

```javascript
const params = new URLSearchParams(location.search);
const avatarId = /^[a-z0-9][a-z0-9_-]{2,63}$/.test(params.get("avatar") || "")
  ? params.get("avatar") : "";
let allowRetry = true;
// /offer body
body: JSON.stringify({ sdp: offer.sdp, type: offer.type, avatar: avatarId || undefined })
```

The `lt-stop` handler sets `allowRetry = false`, clears the timer, closes PC, clears media elements, and posts `lt-stopped`. Retry paths check `allowRetry`.

- [ ] **Step 4: Run GREEN and static protocol assertions**

Run the RTC test. Use `rg` assertions for `avatar: avatarId || undefined`, `lt-stop`, `lt-stopped`, and `allowRetry` in `web/embed.html`. Copy it to `deps/LiveTalking/web/embed.html`, regenerate the patch for Python files, and run both root/upstream `diff --check`.

- [ ] **Step 5: Commit hot-close support**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add web/embed.html patches/livetalking-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: support explicit avatar session switching"
```

### Task 6: Crop Geometry and Authenticated Browser API Client

**Files:**
- Create: `deps/speech-to-speech/demo/ui/avatar-cropper.js`
- Create: `deps/speech-to-speech/demo/ui/avatar-api.js`
- Create: `deps/speech-to-speech/demo/ui/avatar-cropper.test.mjs`
- Create: `deps/speech-to-speech/demo/ui/avatar-api.test.mjs`
- Modify: `patches/s2s-integration.patch`

**Interfaces:**
- Produces: `initialCrop(imageWidth, imageHeight)`, `clampCrop(crop, imageWidth, imageHeight)`, `exportCrop(image, crop, canvas) -> Promise<Blob>`.
- Produces: `AvatarApi({origin, capability, fetchImpl, refreshCapability})` with `createImageTask`, `getTask`, `list`, `active`, `activate`, `delete`, `closeSession`, and `pollTask`.

- [ ] **Step 1: Write failing Node tests**

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import { initialCrop, clampCrop } from "./avatar-cropper.js";

test("landscape image gets centered 3:4 crop", () => {
  assert.deepEqual(initialCrop(1200, 800), { x: 300, y: 0, width: 600, height: 800 });
});

test("crop cannot leave image bounds", () => {
  assert.deepEqual(clampCrop({x:-20,y:50,width:600,height:800}, 1200, 800),
                   {x:0,y:0,width:600,height:800});
});
```

API tests inject a fake fetch and assert the exact origin, capability header, multipart body, one refresh/retry after HTTP 403, and polling sequence `running -> completed`.

- [ ] **Step 2: Run RED**

```powershell
node --test E:\AI\AI-Girlfriend2\deps\speech-to-speech\demo\ui\avatar-cropper.test.mjs E:\AI\AI-Girlfriend2\deps\speech-to-speech\demo\ui\avatar-api.test.mjs
```

Expected: modules do not exist.

- [ ] **Step 3: Implement pure crop and API modules**

Crop output is fixed:

```javascript
export async function exportCrop(image, crop, canvas) {
  canvas.width = 576; canvas.height = 768;
  canvas.getContext("2d").drawImage(
    image, crop.x, crop.y, crop.width, crop.height, 0, 0, 576, 768
  );
  return await new Promise((resolve, reject) =>
    canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error("JPEG export failed")), "image/jpeg", 0.92)
  );
}
```

Every management request sends `X-Live-Avatar-Capability`. On the first HTTP 403, call `refreshCapability()` once and retry with the new capability; a second 403 is terminal. `pollTask(taskId, {intervalMs=1000, timeoutMs=600000, signal})` stops on `completed`/`failed`, throws stable API messages, and supports AbortSignal.

- [ ] **Step 4: Run GREEN and regenerate s2s patch**

Run Node tests. Mark all four files intent-to-add in the s2s checkout, generate the binary patch with:

```powershell
git -c safe.directory=E:/AI/AI-Girlfriend2/deps/speech-to-speech -C E:\AI\AI-Girlfriend2\deps\speech-to-speech diff --binary --output=E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b\patches\s2s-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b diff --check
```

- [ ] **Step 5: Commit browser primitives**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add patches/s2s-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: add avatar crop and API client"
```

### Task 7: Settings UI and Rollback-Safe Switch Coordinator

**Files:**
- Create: `deps/speech-to-speech/demo/ui/avatar-manager.js`
- Create: `deps/speech-to-speech/demo/ui/avatar-manager.test.mjs`
- Modify: `deps/speech-to-speech/demo/index.html`
- Modify: `deps/speech-to-speech/demo/main.js`
- Modify: `deps/speech-to-speech/demo/style.css`
- Modify: `deps/speech-to-speech/demo/server.py`
- Create: `deps/speech-to-speech/demo/avatar_capability.py`
- Create: `deps/speech-to-speech/tests/test_demo_avatar_config.py`
- Modify: `patches/s2s-integration.patch`

**Interfaces:**
- Consumes: `AvatarApi`, cropper functions, iframe `lt-*` messages, app state getter, and `setMicPaused(bool)`.
- Produces: `AvatarManager.init()`, `openFile(file)`, `generateAndSwitch()`, `switchTo(avatarId)`.
- `/api/config` adds `avatarOrigin`, `avatarCapability`, and `avatarCapabilityExpires`, never the master token or a filesystem path.

- [ ] **Step 1: Write failing coordinator and config tests**

The Node test supplies fake API/iframe/state hooks and verifies call order:

```javascript
assert.deepEqual(events, [
  "poll:completed", "wait:conversation-idle", "mic:true", "iframe:lt-stop",
  "api:close:old-sid", "iframe:load:new-avatar", "wait:connected:new-sid",
  "api:activate:new-avatar:new-sid", "mic:false"
]);
```

A rollback test makes `wait:connected` reject and expects load/activate of the old avatar before `mic:false`.

Python config test reloads `demo.server` with environment values and asserts:

```python
self.assertEqual(body["avatarOrigin"], "http://127.0.0.1:8010")
self.assertTrue(body["avatarCapability"].startswith("v1."))
self.assertLessEqual(body["avatarCapabilityExpires"] - int(time.time()), 300)
self.assertNotEqual(body["avatarCapability"], "test-token")
self.assertNotIn("dataRoot", body)
```

- [ ] **Step 2: Run RED**

Run Node test and:

```powershell
E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe -m pytest tests/test_demo_avatar_config.py -q
```

Expected: missing AvatarManager and config keys.

- [ ] **Step 3: Implement the UI and coordinator**

Add Settings markup with exact IDs: `avatar-current`, `avatar-file`, `avatar-name`, `avatar-crop-dialog`, `avatar-crop-canvas`, `avatar-zoom`, `avatar-reset`, `avatar-generate`, `avatar-progress`, `avatar-list`.

Implement the demo-side capability mint with the same wire contract as Task 3:

```python
def mint_avatar_capability(secret: str, origin: str, now: int | None = None) -> tuple[str, int]:
    issued = int(time.time()) if now is None else int(now)
    expires = issued + 300
    nonce = secrets.token_urlsafe(18)
    message = f"v1\n{origin}\n{expires}\n{nonce}".encode("utf-8")
    signature = base64.urlsafe_b64encode(
        hmac.new(secret.encode("utf-8"), message, hashlib.sha256).digest()
    ).decode("ascii").rstrip("=")
    return f"v1.{expires}.{nonce}.{signature}", expires
```

`/api/config` calls this function for the request's configured local origin. It returns the capability and expiry, never `LIVE_AVATAR_ADMIN_TOKEN`.

File handling must reject non-image MIME and >10 MiB before `URL.createObjectURL`. Pointer movement updates crop state; zoom preserves crop center. Revoke every object URL on replace/cancel.

The coordinator waits for `getAppState()` to leave `processing`/`ai-speaking`, pauses mic, closes the exact old session, polls `/api/admin/sessions` through the authenticated close/status interface until absent, and loads `embed.html?avatar=${encodeURIComponent(id)}&v=${Date.now()}`. A 15-second connection timeout triggers rollback.

Initialize from `/api/config`; if avatar configuration is absent, hide the whole field without affecting existing Settings. Keep the selected ID in localStorage as a fast UI hint, but treat `GET /api/avatar/active` as authoritative.

- [ ] **Step 4: Run GREEN and focused regressions**

Run the Node and Python tests. Start the demo on a temporary port with `LIVE_AVATAR_ADMIN_TOKEN=test-token` and assert `/api/config` returns the two new fields. Regenerate the s2s patch with byte-preserving Git output and run `git diff --check`.

- [ ] **Step 5: Commit Settings integration**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add patches/s2s-integration.patch
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "feat: add avatar image controls to settings"
```

### Task 8: Clean-Patch, Live-Service, Audio, and Documentation Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/DEPLOYMENT.md`
- Verify: `patches/livetalking-integration.patch`
- Verify: `patches/s2s-integration.patch`
- Verify: `web/embed.html`

**Interfaces:**
- Produces the deployable integration artifacts and operator instructions.
- No new runtime API is introduced in this task.

- [ ] **Step 1: Add a clean-apply regression script to the verification notes**

Document and run clean detached worktrees at the two pinned commits. Use `git apply --check --binary`, then apply, then copy `web/embed.html`. Assert expected new files exist. Never test patch application against the already-patched live checkout.

- [ ] **Step 2: Run all automated tests**

```powershell
E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe -m unittest discover -s E:\AI\AI-Girlfriend2\deps\LiveTalking\tests -p "test_avatar_*.py" -v
node --test E:\AI\AI-Girlfriend2\deps\speech-to-speech\demo\ui\avatar-*.test.mjs
E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe -m pytest E:\AI\AI-Girlfriend2\deps\speech-to-speech\tests\test_demo_avatar_config.py -q
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b diff --check
```

Expected: all pass.

- [ ] **Step 3: Perform a real generation and switch**

Restart only Demo and LiveTalking with the updated sources. Use `deps/LiveTalking/data/avatars/myavatar/full_imgs/00000000.png` as the real face-bearing test image. In 7860 Settings: crop, generate, and switch. Record these assertions:

- task reaches `completed` and creates metadata/full/face/coords/thumbnail;
- exactly one admin session remains and its `avatar_id` is the new ID;
- 8765 remains listening and its PID does not change;
- 8080 remains healthy and its PID does not change;
- one Chinese request produces audible TTS and `speaking=true` for the new session;
- two screenshots during speech show different mouth pixels;
- selecting a nonexistent avatar triggers rollback to the previous active ID.

- [ ] **Step 4: Update operator documentation**

Document accepted formats/size, crop controls, stages, data directory, recovery, management token rotation, protected deletion, and the fact that original uploads are deleted. Add exact API examples that use a short-lived redacted capability header and loopback URLs; never show the master token.

- [ ] **Step 5: Commit and final verification**

```powershell
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b add README.md docs/DEPLOYMENT.md patches web/embed.html scripts
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b commit -m "docs: document image avatar workflow"
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b status --short
git -C E:\AI\AI-Girlfriend2\.worktrees\live-avatar-35b show --check --stat HEAD
```

Expected: status is clean; `git show --check` has no output beyond the commit/stat summary.
