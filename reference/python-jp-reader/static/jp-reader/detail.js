/* jp-reader — the detail page.
 *
 * The page itself is rendered on the server (see views.py). This file only
 * does what JavaScript has to do: the live preview while editing, the corner
 * dragging, the region drawing, and the clicks that pick words.
 */
(function () {
  "use strict";

  var API = "/api/jp-reader";

  var state = {
    recordId: null,
    record: null,
    activeRegion: null,
    selected: {},      // token index -> true, per active region
    previewTimer: null,
    previewAbort: null,
    preview: null,     // the phrase currently being shown
    source: null,      // this page's progress stream
    stream: null,      // the stream of changes made elsewhere
    deleted: false,    // the page is gone; stop asking about it
    lastProgressAt: 0,
    staleShown: false,
    staleTimer: null,
    regionCount: 0,    // how many lines the page had
    regionPending: false,
    phrase: "",         // what was typed, kept across a body refresh
    edit: {
      open: false,
      cornersMode: false,
      rotation: 0,     // the pending angle, in degrees
      corners: null,   // the pending quad, as fractions of the base image
      baseWidth: 0,
      baseHeight: 0,
    },
  };

  // A page normally takes well under a minute. After this long with no
  // progress the job was probably lost — a worker restart, or a stage that
  // hung — so offer a retry.
  //
  // This has to stay above the server's own worst case (OCR_TIMEOUT 300s plus
  // TRANSLATE_TIMEOUT 240s), otherwise a page that is still working gets
  // flagged as lost and a retry queues a second, competing job.
  var STALE_AFTER = 600000;

  // ── helpers ────────────────────────────────────────────────────

  function $(id) { return document.getElementById(id); }

  // Built from char codes so the entities cannot be mangled by an editor.
  var ENTITIES = {
    "&": String.fromCharCode(38) + "amp;",
    "<": String.fromCharCode(38) + "lt;",
    ">": String.fromCharCode(38) + "gt;",
    '"': String.fromCharCode(38) + "quot;",
  };

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/[&<>"]/g, function (c) { return ENTITIES[c]; });
  }

  function toast(message, kind, link) {
    var host = $("jr-toast");
    if (!host) { return; }
    var box = document.createElement("div");
    box.className = "alert alert-" + (kind || "info") + " shadow-lg";
    box.textContent = message;
    if (link) {
      var anchor = document.createElement("a");
      anchor.href = link;
      anchor.className = "link";
      anchor.textContent = "open";
      box.appendChild(anchor);
    }
    host.appendChild(box);
    setTimeout(function () { box.remove(); }, link ? 8000 : 4000);
  }

  function password() {
    try { return (localStorage.getItem("app-password") || "").trim(); } catch (e) { return ""; }
  }

  function rubyHtml(token) {
    if (!token.ruby) { return esc(token.surface); }
    return "<ruby>" + esc(token.base) + "<rp>(</rp><rt>" + esc(token.ruby) +
      "</rt><rp>)</rp></ruby>" + esc(token.okurigana);
  }

  function copyLink() {
    var url = window.location.href;
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(url).then(function () {
        toast("Link copied — open it on your laptop", "success");
      }, function () {
        showUrlFallback(url);
      });
      return;
    }
    // Plain HTTP on a LAN address has no clipboard API.
    showUrlFallback(url);
  }

  function showUrlFallback(url) {
    var field = document.createElement("textarea");
    field.value = url;
    field.setAttribute("readonly", "");
    field.style.position = "absolute";
    field.style.left = "-9999px";
    document.body.appendChild(field);
    field.select();
    try {
      document.execCommand("copy");
      toast("Link copied — open it on your laptop", "success");
    } catch (e) {
      toast(url, "info");
    }
    field.remove();
  }

  // ── progress ───────────────────────────────────────────────────

  function showProgress(message) {
    var box = $("jr-status-box");
    if (!box) { return; }
    box.classList.remove("hidden");
    box.innerHTML =
      "<div class='flex items-center gap-3'>" +
      "<span class='loading loading-spinner loading-md'></span>" +
      "<span>" + esc(message || "Working…") + "</span>" +
      "</div>";
  }

  function showFailed(message) {
    var box = $("jr-status-box");
    if (!box) { return; }
    box.classList.remove("hidden");
    box.innerHTML =
      "<div class='alert alert-error flex-col items-start gap-2'>" +
      "<span>" + esc(message || "Reading the page failed.") + "</span>" +
      "<button type='button' id='jr-retry' class='btn btn-sm'>Retry</button>" +
      "</div>";
    var retry = $("jr-retry");
    if (retry) { retry.addEventListener("click", retryScan); }
  }

  function showStale(message) {
    var box = $("jr-status-box");
    if (!box) { return; }
    box.classList.remove("hidden");
    box.innerHTML =
      "<div class='alert alert-warning flex-col items-start gap-2'>" +
      "<span>" + esc(message) + "</span>" +
      "<button type='button' id='jr-retry' class='btn btn-sm'>Retry</button>" +
      "</div>";
    var retry = $("jr-retry");
    if (retry) { retry.addEventListener("click", retryScan); }
  }

  function retryScan() {
    fetch(API + "/records/" + state.recordId + "/retry", {
      method: "POST",
      headers: { "X-App-Password": password() },
    })
      .then(function (res) {
        if (!res.ok) {
          return res.json().then(function (body) {
            throw new Error(body.detail || "Could not retry");
          });
        }
        return res.json();
      })
      .then(function () {
        toast("Queued again", "success");
        watch();
      })
      .catch(function (err) { toast(err.message, "error"); });
  }

  function checkStale() {
    state.staleTimer = null;
    if (state.staleShown) { return; }
    if (Date.now() - state.lastProgressAt < STALE_AFTER) {
      state.staleTimer = setTimeout(checkStale, 5000);
      return;
    }
    state.staleShown = true;
    showStale(
      "This is taking longer than expected. The job may have been lost — retry it?"
    );
  }

  function hideProgress() {
    var box = $("jr-status-box");
    if (box) {
      box.classList.add("hidden");
      box.innerHTML = "";
    }
  }

  // ── loading ────────────────────────────────────────────────────

  function watch() {
    if (state.source) { state.source.close(); }
    if (state.staleTimer) { clearTimeout(state.staleTimer); }
    var source = new EventSource(API + "/events/" + state.recordId);
    state.source = source;
    state.lastProgressAt = Date.now();
    state.staleShown = false;
    // Start the watchdog now, not on the first message: a job lost before the
    // worker ever wrote progress would otherwise never be offered a retry.
    state.staleTimer = setTimeout(checkStale, 5000);

    source.onmessage = function (message) {
      var progress;
      try { progress = JSON.parse(message.data); } catch (e) { return; }

      if (progress.error) {
        // The progress record is gone — the page itself may still be there.
        source.close();
        loadRecord();
        return;
      }
      if (progress.status === "done") {
        source.close();
        loadRecord();
        return;
      }
      if (progress.status === "error") {
        source.close();
        showFailed(progress.message);
        loadRecord();
        return;
      }
      state.lastProgressAt = Date.now();
      showProgress(progress.message);
      checkStale();
    };

    source.onerror = function () {
      source.close();
      loadRecord();
    };
  }

  function loadRecord() {
    if (state.deleted) { return; }
    fetch(API + "/records/" + state.recordId)
      .then(function (res) {
        if (!res.ok) { throw new Error("gone"); }
        return res.json();
      })
      .then(function (record) {
        state.record = record;
        var before = state.regionCount;
        state.regionCount = (record.regions || []).length;
        if (state.regionPending && state.regionCount > before) {
          toast("Read " + (state.regionCount - before) + " more lines", "success");
        }
        state.regionPending = false;
        if (record.status === "error") {
          showFailed(record.error);
          return;
        }
        if (record.status !== "done") {
          state.lastProgressAt = Date.now();
          showProgress(record.error || "Still working…");
          // The text arrives before the translation, so refresh either way.
          refreshFragment();
          checkStale();
          return;
        }
        hideProgress();
        refreshFragment();
      })
      .catch(function () {
        showError("That page is no longer available.");
      });
  }

  // The body is rendered on the server, so the page and the fragment are
  // always the same markup.
  function refreshFragment() {
    fetch("/jp-reader/" + state.recordId + "/fragment")
      .then(function (res) { return res.text(); })
      .then(function (html) {
        var host = $("jr-detail");
        if (!host) { return; }
        host.innerHTML = html;
        hydrate();
      })
      .catch(function () { /* the page keeps what it has */ });
  }

  function showError(message) {
    var box = $("jr-status-box");
    if (!box) { return; }
    box.classList.remove("hidden");
    box.innerHTML = "<div class='alert alert-error'>" + esc(message) + "</div>";
  }

  // ── wiring up the server-rendered page ──────────────────────────

  function hydrate() {
    var record = state.record || {};

    state.edit.baseWidth = record.base_width || record.width || 1;
    state.edit.baseHeight = record.base_height || record.height || 1;
    var transform = record.transform || {};
    state.edit.rotation = transform.rotation_deg || 0;
    state.edit.corners = cornersToFractions(transform.corners);

    Array.prototype.forEach.call(
      document.querySelectorAll("[data-region]"),
      function (box) {
        box.addEventListener("click", function () {
          pickRegion(parseInt(box.dataset.region, 10));
        });
      }
    );

    wireEditor();
    wireRegion();
    renderChips(null);
    renderOrientation(record);

    // The body was just replaced, so put back what the reader had chosen.
    if (state.activeRegion !== null) {
      var box = document.querySelector(
        "[data-region='" + state.activeRegion + "']"
      );
      if (box) { box.classList.add("is-active"); }
    }
    var phrase = $("jr-phrase");
    if (phrase && state.phrase) {
      phrase.value = state.phrase;
      schedulePreview();
    }
  }

  // ── picking words ──────────────────────────────────────────────

  function activeRegion() {
    if (!state.record || state.activeRegion === null) { return null; }
    var found = null;
    (state.record.regions || []).forEach(function (r) {
      if (r.i === state.activeRegion) { found = r; }
    });
    return found;
  }

  function setActiveRegion(index) {
    if (state.activeRegion !== null) {
      var previous = document.querySelector("[data-region='" + state.activeRegion + "']");
      if (previous) { previous.classList.remove("is-active"); }
    }
    state.activeRegion = index;
    if (index !== null) {
      var box = document.querySelector("[data-region='" + index + "']");
      if (box) { box.classList.add("is-active"); }
    }
  }

  function pickRegion(index) {
    state.selected = {};
    setActiveRegion(index);
    var region = activeRegion();
    renderChips(region);
    var input = $("jr-phrase");
    if (input && region) {
      input.value = region.text;
      state.phrase = region.text;
    }
    schedulePreview();
  }

  function renderChips(region) {
    var host = $("jr-chips");
    if (!host) { return; }
    if (!region) {
      host.innerHTML = "<p class='text-sm opacity-60'>Tap a box on the page.</p>";
      return;
    }
    if (!region.tokens || !region.tokens.length) {
      host.innerHTML = "<p class='text-sm opacity-60'>No words in this line.</p>";
      return;
    }
    host.innerHTML = "";
    region.tokens.forEach(function (token, index) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "btn btn-xs " +
        (state.selected[index] ? "btn-primary" : "btn-outline");
      chip.innerHTML = rubyHtml(token);
      chip.addEventListener("click", function () { toggleToken(index); });
      host.appendChild(chip);
    });
  }

  function toggleToken(index) {
    var region = activeRegion();
    if (!region) { return; }
    if (state.selected[index]) { delete state.selected[index]; }
    else { state.selected[index] = true; }

    var phrase = region.tokens.filter(function (_, i) {
      return state.selected[i];
    }).map(function (t) { return t.surface; }).join("");

    var input = $("jr-phrase");
    if (input) { input.value = phrase; }
    state.phrase = phrase;

    renderChips(region);
    schedulePreview();
  }

  function schedulePreview() {
    if (state.previewTimer) { clearTimeout(state.previewTimer); }
    state.previewTimer = setTimeout(renderPreview, 700);
  }

  function renderPreview() {
    var input = $("jr-phrase");
    var host = $("jr-preview-box");
    if (!input || !host) { return; }
    var phrase = input.value.trim();
    if (!phrase) { host.innerHTML = ""; state.preview = null; return; }

    // A newer phrase supersedes whatever is still in flight.
    if (state.previewAbort) { state.previewAbort.abort(); }
    var controller = new AbortController();
    state.previewAbort = controller;

    fetch(API + "/records/" + state.recordId + "/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ phrase: phrase }),
      signal: controller.signal,
    })
      .then(function (res) {
        if (!res.ok) { throw new Error("preview failed"); }
        return res.json();
      })
      .then(function (data) {
        if (controller.signal.aborted) { return; }
        state.preview = data;
        renderPreviewBox();
      })
      .catch(function (err) {
        if (err.name !== "AbortError") { host.innerHTML = ""; }
      });
  }

  function renderPreviewBox() {
    var host = $("jr-preview-box");
    var data = state.preview;
    if (!host || !data) { return; }
    var translation = data.translation_pending
      ? "<div class='text-sm flex items-center gap-2 opacity-70'>" +
      "<span class='loading loading-spinner loading-xs'></span>translating…</div>"
      : "<div class='text-sm'>" + esc(data.translation) + "</div>";
    host.innerHTML =
      "<div class='text-lg'>" + data.ruby_html + "</div>" +
      "<div class='text-xs opacity-60'>" + esc(data.reading) + "</div>" +
      translation;
  }

  function renderOrientation(record) {
    var host = $("jr-orientation");
    if (!host) { return; }
    var orientation = record.orientation;
    if (!orientation || !orientation.angle) {
      host.classList.add("hidden");
      host.innerHTML = "";
      return;
    }
    host.classList.remove("hidden");
    host.innerHTML =
      "<div class='flex items-center justify-between gap-3'>" +
      "<span>This page looks sideways — rotate it?</span>" +
      "<button type='button' id='jr-rotate-suggested' class='btn btn-xs btn-primary'>" +
      "Rotate " + orientation.angle + "°</button>" +
      "</div>";
    var button = $("jr-rotate-suggested");
    if (button) {
      button.addEventListener("click", function () {
        state.edit.open = true;
        state.edit.rotation = orientation.angle;
        var panel = $("jr-edit");
        if (panel) { panel.open = true; }
        applyPreview();
      });
    }
  }

  // ── the image editor ────────────────────────────────────────────

  function cornersToFractions(corners) {
    if (!corners || !corners.length) { return null; }
    return corners.map(function (c) {
      return [c[0] / state.edit.baseWidth, c[1] / state.edit.baseHeight];
    });
  }

  function fractionsToCorners(fractions) {
    if (!fractions) { return null; }
    return fractions.map(function (p) {
      return [
        Math.round(p[0] * state.edit.baseWidth),
        Math.round(p[1] * state.edit.baseHeight),
      ];
    });
  }

  function wireEditor() {
    var panel = $("jr-edit");
    if (panel) {
      // The panel is a native <details>: it opens and closes itself.
      panel.addEventListener("toggle", function () {
        state.edit.open = panel.open;
        if (!state.edit.open) {
          state.edit.cornersMode = false;
          var cornersButton = $("jr-corners");
          if (cornersButton) { cornersButton.classList.remove("btn-primary"); }
        }
        applyPreview();
      });
    }

    // The angle controls are shared with the upload page.
    JREditor.init(function (angle) {
      state.edit.rotation = angle;
      applyPreview();
    }, state.edit.rotation);

    var cornersButton = $("jr-corners");
    if (cornersButton) {
      cornersButton.addEventListener("click", function () {
        state.edit.cornersMode = !state.edit.cornersMode;
        cornersButton.classList.toggle("btn-primary", state.edit.cornersMode);
        if (state.edit.cornersMode && !state.edit.corners) {
          state.edit.corners = [
            [0.02, 0.02], [0.98, 0.02], [0.98, 0.98], [0.02, 0.98],
          ];
        }
        applyPreview();
      });
    }

    var reset = $("jr-reset");
    if (reset) {
      reset.addEventListener("click", function () {
        state.edit.rotation = 0;
        state.edit.corners = null;
        state.edit.cornersMode = false;
        if (cornersButton) { cornersButton.classList.remove("btn-primary"); }
        applyPreview();
      });
    }

    var apply = $("jr-apply");
    if (apply) { apply.addEventListener("click", applyEdit); }
  }

  function applyPreview() {
    var pivot = $("jr-edit-pivot");
    if (!pivot) { return; }
    // The page's picture is left alone; the panel shows what a change
    // would do to it.
    pivot.style.transform = JREditor.transformFor(state.edit.rotation);
    drawQuad(state.edit.corners);
  }

  function drawQuad(corners) {
    var svg = $("jr-quad");
    if (!svg) { return; }
    if (!corners) {
      svg.innerHTML = "";
      return;
    }
    var quad = corners.map(function (p) {
      return (p[0] * 100) + " " + (p[1] * 100);
    }).join(" L ");

    // Everything outside the square is darkened; the square itself stays
    // clear, so the cropped text is not hidden away.
    var mask = "M0 0 L100 0 L100 100 L0 100 Z M" + quad + " Z";

    var handles = corners.map(function (p, index) {
      return "<circle cx='" + (p[0] * 100) + "' cy='" + (p[1] * 100) + "' r='1.8' " +
        "fill='#60a5fa' stroke='white' stroke-width='0.6' " +
        "vector-effect='non-scaling-stroke' style='cursor:move' " +
        "data-corner='" + index + "' />";
    }).join("");

    svg.innerHTML =
      "<path d='" + mask + "' fill='rgba(0,0,0,0.55)' fill-rule='evenodd' />" +
      "<polygon points='" + quad + "' fill='none' stroke='#60a5fa' " +
      "stroke-width='0.6' vector-effect='non-scaling-stroke' />" +
      handles;

    Array.prototype.forEach.call(
      svg.querySelectorAll("[data-corner]"),
      function (handle) {
        handle.addEventListener("mousedown", startDrag);
        handle.addEventListener("touchstart", startDrag, { passive: false });
      }
    );
  }

  // Where the pointer is, in the base image's own coordinates — undoing the
  // preview's turn and scale.
  function pointerToBase(event) {
    var preview = $("jr-edit-preview");
    if (!preview) { return [0, 0]; }
    var rect = preview.getBoundingClientRect();
    var rad = state.edit.rotation * Math.PI / 180;
    var scale = 1 / (Math.abs(Math.cos(rad)) + Math.abs(Math.sin(rad)));
    var point = event.touches ? event.touches[0] : event;
    var cx = rect.left + rect.width / 2;
    var cy = rect.top + rect.height / 2;
    var dx = (point.clientX - cx) / scale;
    var dy = (point.clientY - cy) / scale;
    var a = -rad;
    return [
      (dx * Math.cos(a) - dy * Math.sin(a) + cx - rect.left) / rect.width,
      (dx * Math.sin(a) + dy * Math.cos(a) + cy - rect.top) / rect.height,
    ];
  }

  function startDrag(event) {
    event.preventDefault();
    event.stopPropagation();
    var index = parseInt(event.target.dataset.corner, 10);
    if (isNaN(index)) { return; }

    function move(ev) {
      var point = pointerToBase(ev);
      if (!state.edit.corners) { return; }
      state.edit.corners[index] = [
        Math.min(1, Math.max(0, point[0])),
        Math.min(1, Math.max(0, point[1])),
      ];
      applyPreview();
    }

    function stop() {
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", stop);
      document.removeEventListener("touchmove", move);
      document.removeEventListener("touchend", stop);
    }

    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", stop);
    document.addEventListener("touchmove", move, { passive: false });
    document.addEventListener("touchend", stop);
  }

  function applyEdit() {
    var corners = fractionsToCorners(state.edit.corners);
    fetch(API + "/records/" + state.recordId + "/transform", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-App-Password": password(),
      },
      body: JSON.stringify({
        rotation_deg: state.edit.rotation,
        corners: corners,
      }),
    })
      .then(function (res) {
        if (!res.ok) {
          return res.json().then(function (body) {
            throw new Error(body.detail || "Could not apply the change");
          });
        }
        return res.json();
      })
      .then(function () {
        toast("Reading the page again…", "success");
        state.edit.open = false;
        var panel = $("jr-edit");
        if (panel) { panel.open = false; }
        showProgress("Reading the page again…");
        watch();
      })
      .catch(function (err) { toast(err.message, "error"); });
  }

  // ── region OCR ─────────────────────────────────────────────────

  function wireRegion() {
    var button = $("jr-region");
    if (!button) { return; }
    button.addEventListener("click", function () {
      startRegionSelection(button);
    });
  }

  // Only the label changes, so the button keeps its icon.
  function setRegionLabel(button, text) {
    var label = button.querySelector("[data-label]");
    if (label) { label.textContent = text; } else { button.textContent = text; }
  }

  function setRegionStatus(text) {
    var status = $("jr-region-status");
    if (status) { status.textContent = text || ""; }
  }

  function startRegionSelection(button) {
    var canvas = $("jr-canvas");
    var image = $("jr-image");
    if (!canvas || !image) { return; }

    button.classList.add("btn-primary");
    setRegionLabel(button, "Drag over the original…");

    var marker = document.createElement("div");
    marker.className = "absolute border-2 border-warning bg-warning/20 pointer-events-none";
    marker.style.display = "none";
    canvas.appendChild(marker);

    var start = null;

    function point(ev) {
      var rect = image.getBoundingClientRect();
      var p = ev.touches ? ev.touches[0] : ev;
      return {
        x: Math.min(1, Math.max(0, (p.clientX - rect.left) / rect.width)),
        y: Math.min(1, Math.max(0, (p.clientY - rect.top) / rect.height)),
      };
    }

    function down(ev) {
      ev.preventDefault();
      start = point(ev);
      marker.style.display = "block";
      move(ev);
    }

    function move(ev) {
      if (!start) { return; }
      var now = point(ev);
      var left = Math.min(start.x, now.x);
      var top = Math.min(start.y, now.y);
      marker.style.left = (left * 100) + "%";
      marker.style.top = (top * 100) + "%";
      marker.style.width = (Math.abs(now.x - start.x) * 100) + "%";
      marker.style.height = (Math.abs(now.y - start.y) * 100) + "%";
    }

    function up(ev) {
      if (!start) { return; }
      var now = point(ev);
      var box = [
        Math.min(start.x, now.x), Math.min(start.y, now.y),
        Math.max(start.x, now.x), Math.max(start.y, now.y),
      ];
      start = null;
      marker.remove();
      button.classList.remove("btn-primary");
      setRegionLabel(button, "Select region");
      canvas.removeEventListener("mousedown", down);
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
      if (box[2] - box[0] < 0.01 || box[3] - box[1] < 0.01) { return; }
      runRegionOcr(box);
    }

    canvas.addEventListener("mousedown", down);
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  }

  function runRegionOcr(box) {
    state.regionPending = true;
    setRegionStatus("Reading that region…");
    toast("Reading that region…", "info");
    fetch(API + "/records/" + state.recordId + "/regions/ocr", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-App-Password": password(),
      },
      body: JSON.stringify({ box: box, replace_intersecting: true }),
    })
      .then(function (res) {
        if (!res.ok) {
          return res.json().then(function (body) {
            throw new Error(body.detail || "Could not read the region");
          });
        }
        return res.json();
      })
      .then(function () {
        setRegionStatus("Reading the region…");
      })
      .catch(function (err) {
        setRegionStatus(err.message);
        toast(err.message, "error");
      });
  }

  // ── live updates from other devices ────────────────────────────

  function connectStream() {
    var source = new EventSource(API + "/stream");

    source.onmessage = function (message) {
      var event;
      try { event = JSON.parse(message.data); } catch (e) { return; }

      if (event.type === "created") {
        toast("A new page was scanned", "info", "/jp-reader/" + event.id);
        return;
      }
      if (event.type === "deleted" && event.id === state.recordId) {
        // Deleted here, or from another device: either way it is gone.
        pageGone();
        return;
      }
      if (event.type === "updated" && event.id === state.recordId) {
        loadRecord();
        return;
      }
      if (event.type === "translated") {
        // The translation for the phrase on screen arrived.
        if (state.preview && state.preview.phrase === event.phrase) {
          state.preview.translation = event.translation;
          state.preview.translation_pending = false;
          renderPreviewBox();
        }
        if (event.id === state.recordId) { loadRecord(); }
      }
    };

    source.onerror = function () {
      // The stream dropped — pick up anything that happened meanwhile.
      loadRecord();
    };
    state.stream = source;
  }

  function pageGone() {
    if (state.deleted) { return; }
    state.deleted = true;
    if (state.source) { state.source.close(); }
    if (state.stream) { state.stream.close(); }
    if (state.staleTimer) { clearTimeout(state.staleTimer); }
    var body = $("jr-detail");
    if (body) { body.innerHTML = ""; }
    showError("This page was deleted.");
  }

  // ── boot ───────────────────────────────────────────────────────

  document.addEventListener("DOMContentLoaded", function () {
    var root = $("jr-root");
    state.recordId = root ? root.getAttribute("data-record-id") : null;
    if (!state.recordId) {
      showError("No page was given.");
      return;
    }
    var copy = $("jr-copy");
    if (copy) { copy.addEventListener("click", copyLink); }

    var remove = $("jr-delete");
    if (remove) {
      remove.addEventListener("click", function (event) {
        window.JRDelete.request(state.recordId, event.shiftKey, function () {
          state.deleted = true;
          window.location.href = "/jp-reader/";
        });
      });
    }

    var phrase = $("jr-phrase");
    if (phrase) {
      phrase.addEventListener("input", function () {
        state.phrase = phrase.value;
        state.selected = {};
        renderChips(null);
        schedulePreview();
      });
    }

    loadRecord();
    watch();
    connectStream();
  });
})();
