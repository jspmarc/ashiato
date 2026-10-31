/* jp-reader — pick a photo, upload it with progress, then move to the page. */
(function () {
  "use strict";

  var API = "/api/jp-reader";
  var PW_KEY = "app-password";

  var state = {
    xhr: null,
    objectUrl: null,
    records: [],
    newIds: {},
    rotation: 0,
  };

  // ── helpers ────────────────────────────────────────────────────

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function toast(message, kind) {
    var host = $("jr-toast");
    if (!host) { return; }
    var box = document.createElement("div");
    box.className = "alert alert-" + (kind || "info") + " shadow-lg";
    box.textContent = message;
    host.appendChild(box);
    setTimeout(function () { box.remove(); }, 4000);
  }

  function password() {
    var input = $("jr-password");
    return input ? input.value.trim() : "";
  }

  function rememberPassword() {
    try { localStorage.setItem(PW_KEY, password()); } catch (e) { /* private mode */ }
  }

  function restorePassword() {
    var input = $("jr-password");
    if (!input) { return; }
    try { input.value = localStorage.getItem(PW_KEY) || ""; } catch (e) { /* ignore */ }
  }

  function setStatus(text) {
    var label = $("jr-status");
    if (label) { label.textContent = text; }
    var box = $("jr-progress-box");
    if (box) { box.classList.remove("hidden"); }
  }

  function setBusy(busy) {
    var button = $("jr-upload-btn");
    if (button) { button.disabled = busy; }
  }

  // ── preview ────────────────────────────────────────────────────

  function showPreview(file) {
    if (state.objectUrl) { URL.revokeObjectURL(state.objectUrl); }
    state.objectUrl = URL.createObjectURL(file);
    var img = $("jr-preview");
    if (img) {
      img.src = state.objectUrl;
      img.classList.remove("hidden");
    }
    // The straighten controls only mean something with a photo to straighten.
    var straighten = $("jr-straighten");
    if (straighten) { straighten.classList.remove("hidden"); }
  }

  // The photo is turned in the browser so you can see what you are sending;
  // the server does the same turn for real when it stores the page.
  function applyRotation(angle) {
    state.rotation = angle;
    var img = $("jr-preview");
    if (img) { img.style.transform = JREditor.transformFor(angle); }
    var hidden = $("jr-rotation");
    if (hidden) { hidden.value = angle; }
  }

  function selectedFile() {
    var form = $("jr-upload-form");
    if (!form) { return null; }
    var input = form.querySelector("input[type=file]");
    return input && input.files && input.files.length ? input.files[0] : null;
  }

  // ── upload ─────────────────────────────────────────────────────

  function upload(file) {
    if (!file) {
      toast("Choose a photo first", "warning");
      return;
    }
    if (!password()) {
      toast("Enter the password first", "warning");
      return;
    }
    rememberPassword();

    var data = new FormData();
    data.append("file", file);
    data.append("rotation_deg", String(state.rotation));

    var xhr = new XMLHttpRequest();
    xhr.open("POST", API + "/upload");
    xhr.setRequestHeader("X-App-Password", password());

    xhr.upload.onprogress = function (event) {
      if (!event.lengthComputable) { return; }
      var percent = Math.round(event.loaded / event.total * 100);
      var bar = $("jr-bar");
      if (bar) { bar.value = percent; }
      setStatus("Uploading… " + percent + "%");
    };

    xhr.onload = function () {
      state.xhr = null;
      setBusy(false);
      if (xhr.status === 200) {
        var body = JSON.parse(xhr.responseText);
        setStatus("Uploaded — opening the page…");
        window.location.href = "/jp-reader/" + body.id;
        return;
      }
      var message = "Upload failed (" + xhr.status + ")";
      try {
        var body = JSON.parse(xhr.responseText);
        message = body.detail || message;
      } catch (e) { /* not json */ }
      setStatus(message);
      toast(message, "error");
    };

    xhr.onerror = function () {
      state.xhr = null;
      setBusy(false);
      setStatus("Upload failed — is the server reachable?");
    };

    xhr.onabort = function () {
      state.xhr = null;
      setBusy(false);
      var bar = $("jr-bar");
      if (bar) { bar.value = 0; }
      setStatus("Upload cancelled");
    };

    state.xhr = xhr;
    setBusy(true);
    setStatus("Uploading…");
    xhr.send(data);
  }

  function cancelUpload() {
    if (state.xhr) {
      state.xhr.abort();
      return;
    }
    // Nothing in flight — clear the selection instead.
    var form = $("jr-upload-form");
    if (form) {
      var input = form.querySelector("input[type=file]");
      if (input) { input.value = ""; }
    }
    var img = $("jr-preview");
    if (img) { img.classList.add("hidden"); }
    // No photo, so nothing to straighten.
    var straighten = $("jr-straighten");
    if (straighten) { straighten.classList.add("hidden"); }
    applyRotation(0);
    var box = $("jr-progress-box");
    if (box) { box.classList.add("hidden"); }
  }

  // ── recent pages ───────────────────────────────────────────────

  function renderList() {
    var list = $("jr-list");
    if (!list) { return; }
    if (!state.records.length) {
      list.innerHTML = "<p class='text-sm opacity-60'>No pages scanned yet.</p>";
      return;
    }
    list.innerHTML = state.records.map(function (record) {
      var isNew = !!state.newIds[record.id];
      var failed = record.status === "error";
      var status;
      if (record.status === "done") {
        status = record.region_count + " lines";
      } else if (failed) {
        status = "Failed — open to retry";
      } else if (record.status === "text_ready") {
        status = "Translating…";
      } else {
        status = "Reading the page…";
      }
      var tone = failed
        ? "bg-base-200 ring-1 ring-error"
        : (isNew ? "bg-base-100 ring-2 ring-primary" : "bg-base-200 hover:bg-base-300");
      // The preview only exists once the page has been read.
      var preview = record.status === "done"
        ? "<figure class='h-40 bg-base-300 overflow-hidden'>" +
          "<img src='/api/jp-reader/records/" + esc(record.id) + "/thumb' " +
          "class='w-full h-full object-contain' alt='page preview' loading='lazy' " +
          "onerror=\"this.style.display='none'\" />" +
          "</figure>"
        : "<figure class='h-40 bg-base-300 flex items-center justify-center'>" +
          "<span class='loading loading-spinner loading-md'></span></figure>";
      // The delete button sits beside the link, not inside it, so pressing
      // it never opens the page.
      var deleteButton =
        "<button type='button' data-record-id='" + esc(record.id) + "' " +
        "title='Delete this page (shift-click skips the question)' " +
        "aria-label='Delete page' " +
        "class='jr-list-delete btn btn-sm btn-circle btn-ghost bg-base-100/80 " +
        "text-error absolute top-2 left-2 z-10'>" + trashIcon() + "</button>";
      return "<div class='relative'>" +
        "<a href='/jp-reader/" + esc(record.id) + "' " +
        "class='w-full h-full text-left card shadow-sm relative overflow-hidden " + tone + "'>" +
        (isNew
          ? "<span class='badge badge-primary badge-sm absolute top-2 right-2 z-10'>New</span>"
          : "") +
        preview +
        "<div class='card-body p-3'>" +
        "<div class='flex justify-between text-xs opacity-60'>" +
        "<span>" + esc(new Date(record.created_at * 1000).toLocaleString()) + "</span>" +
        "<span>" + status + "</span>" +
        "</div>" +
        "<div class='text-sm'>" + esc(record.preview || "") + "</div>" +
        "</div></a>" +
        deleteButton +
        "</div>";
    }).join("");
  }

  // The icon is rendered on the server by fastlucide, like every other
  // icon on the site; the list only copies it.
  function trashIcon() {
    var template = $("jr-icon-trash");
    return template ? template.innerHTML : "Delete";
  }

  function forgetRecord(recordId) {
    state.records = state.records.filter(function (r) { return r.id !== recordId; });
    delete state.newIds[recordId];
    renderList();
  }

  function refreshList() {
    fetch(API + "/records")
      .then(function (res) { return res.json(); })
      .then(function (records) {
        state.records = records;
        renderList();
      })
      .catch(function () { /* the list is best-effort */ });
  }

  function markNew(recordId) {
    state.newIds[recordId] = true;
    renderList();
    // The marker fades so the list does not stay loud.
    setTimeout(function () {
      delete state.newIds[recordId];
      renderList();
    }, 20000);
  }

  function findRecord(recordId) {
    for (var i = 0; i < state.records.length; i++) {
      if (state.records[i].id === recordId) { return state.records[i]; }
    }
    return null;
  }

  // ── live updates ───────────────────────────────────────────────

  function connectStream() {
    var source = new EventSource(API + "/stream");

    source.onmessage = function (message) {
      var event;
      try { event = JSON.parse(message.data); } catch (e) { return; }

      if (event.type === "created") {
        if (!findRecord(event.id)) {
          state.records.unshift({
            id: event.id,
            created_at: event.created_at,
            status: event.status,
            region_count: event.region_count,
            preview: event.preview,
          });
        }
        markNew(event.id);
        return;
      }

      if (event.type === "updated") {
        var record = findRecord(event.id);
        if (record) {
          record.status = event.status;
          record.region_count = event.region_count;
          record.preview = event.preview;
          renderList();
        }
        return;
      }

      if (event.type === "deleted") {
        // Deleted here or on another device.
        forgetRecord(event.id);
      }
    };

    source.onerror = function () {
      // The stream dropped — pick up anything that happened meanwhile.
      refreshList();
    };
  }

  // ── boot ───────────────────────────────────────────────────────

  document.addEventListener("DOMContentLoaded", function () {
    restorePassword();

    var form = $("jr-upload-form");
    if (form) {
      form.addEventListener("submit", function (event) {
        event.preventDefault();
        upload(selectedFile());
      });
      var input = form.querySelector("input[type=file]");
      if (input) {
        input.addEventListener("change", function () {
          var file = selectedFile();
          if (file) { showPreview(file); }
        });
      }
    }

    var cancel = $("jr-cancel");
    if (cancel) { cancel.addEventListener("click", cancelUpload); }

    var pw = $("jr-password");
    if (pw) { pw.addEventListener("change", rememberPassword); }

    var list = $("jr-list");
    if (list) {
      list.addEventListener("click", function (event) {
        var button = event.target.closest(".jr-list-delete");
        if (!button) { return; }

        event.preventDefault();
        event.stopPropagation();

        var recordId = button.getAttribute("data-record-id");
        if (!recordId) { return; }

        // The shared delete uses the remembered password, so remember
        // whatever is typed now.
        rememberPassword();
        window.JRDelete.request(recordId, event.shiftKey, function () {
          forgetRecord(recordId);
        });
      });
    }

    JREditor.init(applyRotation, 0);

    refreshList();
    connectStream();
  });
})();
