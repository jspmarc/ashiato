# ashiato-ocr — service card

**Status: unbuilt, and external to this repository.** The service does not exist
yet. This card records the wire contract the Elixir side already speaks
(`Ashiato.Ocr`, `Ashiato.Ocr.Socket`, `Ashiato.Ocr.Fake`) so the service can be
built against it later. Nothing in this repository's gate builds, ships, or starts
it; wave 3 runs against the fake.

## Engine

| Aspect | Value |
|---|---|
| Model | PaddleOCR **PP-OCRv6 `medium`** det + rec, `lang="japan"` |
| Hardware | CPU only. PaddlePaddle's CPU wheel requires AVX; without it the import dies with SIGILL |
| Process shape | **Resident**: one model load at boot (loading costs seconds; an 18-image batch took 137 s with a single load), requests answered in-process afterwards |
| Flags | `enable_mkldnn=False` **and** `FLAGS_enable_pir_api=0`. Paddle 3.x + oneDNN fails every image with `(Unimplemented) ConvertPirAttribute2RuntimeAttribute`; miss either flag and nothing works |
| Threads | Capped at **4**. The default is every core, which oversubscribes badly: one page cost 85 CPU-seconds on 16 threads, 22 on one |
| Reference wrapper | `reference/python-jp-reader/core/ocr.py` — a working PaddleOCR wrapper returning `rec_boxes` per line; the detector half can be lifted rather than rewritten |

## Transport

A **Unix domain socket**, not HTTP: no published port, no bind address, no auth,
nothing reachable off-host. Erlang opens it with
`:gen_tcp.connect({:local, path}, 0, [:binary, packet: 4])` — `packet: 4` is the
whole framing: a 4-byte big-endian length prefix handled by the socket, **one
compact JSON object per frame**. One request frame, one reply frame. Connect, send,
and recv are bounded (default 60 s) so a dead service cannot block the caller.

App-side config: `config :ashiato, Ashiato.Ocr, socket_path: "/run/ashiato/ocr.sock"`
(or the `ASHIATO_OCR_SOCKET` environment variable).

## Request

One JSON object per frame, carrying a **locator only — never image bytes** —
exactly one of:

```json
{"op": "ocr", "path": "/shared/pages/1.png"}
{"op": "ocr", "url": "https://example.test/pages/1.png"}
{"op": "ocr", "key": "users/1/pages/1.png"}
```

With the `local` image store, `Ashiato.Storage.locator/2` returns `{:key, key}` and
the request carries `key`. The OCR side has its own **configured image root** on the
shared page-image volume and resolves `key` under it with the **same key-validation
rules as the app** (`Ashiato.Storage.valid_key?/1`: relative, no `..`, no null byte;
the resolved path must stay under the root). The two containers agree on the volume
and the root, never on an absolute path. A future `s3` store returns
`{:url, presigned}` and the request carries `url`. Base64 over the socket would
inflate every image by a third and hold it in memory twice.

## Reply

One JSON object, one entry per detected line:

```json
{"lines": [{"bbox": [x1, y1, x2, y2], "text": "...", "score": 0.98, "crop": "<base64 JPEG>"}]}
```

- `bbox` — integers, normalised **0–1000**: fractions of the frame, identical on a
  400×225 and a 1920×1080 image. Convert with `x_px = x × width / 1000`; the client
  asserts the range on ingest.
- `text`, `score` — the recognised line and its confidence in 0..1.
- `crop` — **required**. That line's image as base64-encoded JPEG. The client
  decodes it and requires a **non-empty binary**; it performs no JPEG signature
  check and no image decode, and writes no storage.

**Size cap.** The reply body is capped at exactly `16_777_216` bytes (16 MiB), the
4-byte length prefix excluded. A body of that size is accepted; one byte more is
rejected cleanly instead of being buffered.

## Errors

The client never raises; every failure is `{:error, term}`:

| Shape | Meaning |
|---|---|
| `{:invalid_line, index}` | Line block `index` (0-based) is malformed: bad bbox, score outside 0..1, a missing or non-binary field, or a `crop` that is absent, not valid base64, or decodes to empty. **A corrupt block rejects the whole reply** — the request fails, it is never passed through partially |
| `:invalid_json` | The reply frame is not parseable JSON |
| `:invalid_response` | Valid JSON, but not a `"lines"` object |
| socket/connect errors | Absent socket, refused or closed connection, send or recv timeout — returned as `{:error, reason}` from the transport |

Client-side guards before the wire: `:socket_path_missing` (no socket configured),
`:invalid_locator` (not a `{kind, binary}` tuple), `:encode_failed`.

## Topology

Exactly **two containers in one pod**:

- `ashiato-web` — the Phoenix app
- `ashiato-ocr` — the resident PaddleOCR service

Shared volumes:

- a **socket volume** hosting the Unix socket;
- a **page-image volume** holding the stored page images, mounted read-write by the
  app and read by the OCR side through its configured image root.

Each container keeps its own crash and restart behaviour: this OCR path has failed
independently before (SIGILL without AVX, then the oneDNN PIR failure), and an OCR
crash must not take the review UI with it. The dictionary service stays outside the
pod: shared, versioned, its own release cadence.

**The orchestration mechanism is left open.** Creating and supervising the pod is an
operations choice, and this card mandates no product. Only the topology is
required: two containers, one socket volume, one page-image volume. The image root
is service-side configuration on the OCR container, not application env.

## Fixture corpus

Accuracy is measured by a **fixture corpus**, not by retained production output: a
small set of screenshots with hand-checked ground-truth transcriptions, run against
every backend change. That is why no `ocr_raw` column exists — a fixture has ground
truth, and retaining per-page output would store the same bytes twice on pages
nobody corrected.
