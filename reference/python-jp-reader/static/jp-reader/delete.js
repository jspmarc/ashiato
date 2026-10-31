/* jp-reader — deleting a page, shared by the page list and the page itself.
 *
 * Holding shift while pressing delete skips the question.
 */
(function () {
  "use strict";

  var API = "/api/jp-reader";
  var pending = null;

  function password() {
    try {
      return (localStorage.getItem("app-password") || "").trim();
    } catch (e) {
      return "";
    }
  }

  function notify(message, kind) {
    var host = document.getElementById("jr-toast");
    if (!host) { return; }
    var box = document.createElement("div");
    box.className = "alert alert-" + (kind || "info") + " shadow-lg";
    box.textContent = message;
    host.appendChild(box);
    setTimeout(function () { box.remove(); }, 4000);
  }

  function remove(recordId, onDone) {
    if (!password()) {
      notify("Enter the password on the upload page first", "warning");
      return Promise.resolve();
    }
    return fetch(API + "/records/" + encodeURIComponent(recordId), {
      method: "DELETE",
      headers: { "X-App-Password": password() },
    })
      .then(function (res) {
        if (!res.ok) {
          return res.json().then(function (body) {
            throw new Error(body.detail || "Could not delete the page");
          });
        }
        return res.json();
      })
      .then(function () {
        notify("Page deleted", "success");
        if (onDone) { onDone(); }
      })
      .catch(function (err) { notify(err.message, "error"); });
  }

  window.JRDelete = {
    remove: remove,

    /* Deletes at once when shift is held, otherwise asks first. */
    request: function (recordId, shiftKey, onDone) {
      if (shiftKey) {
        remove(recordId, onDone);
        return;
      }
      pending = { id: recordId, done: onDone };
      var modal = document.getElementById("jr-delete-modal");
      if (modal) { modal.showModal(); }
    },

    confirm: function () {
      var job = pending;
      pending = null;
      var modal = document.getElementById("jr-delete-modal");
      if (modal) { modal.close(); }
      if (job) { remove(job.id, job.done); }
    },
  };

  document.addEventListener("DOMContentLoaded", function () {
    var confirmButton = document.getElementById("jr-delete-confirm");
    if (confirmButton) {
      confirmButton.addEventListener("click", function () {
        window.JRDelete.confirm();
      });
    }
    var cancelButton = document.getElementById("jr-delete-cancel");
    if (cancelButton) {
      cancelButton.addEventListener("click", function () {
        pending = null;
        var modal = document.getElementById("jr-delete-modal");
        if (modal) { modal.close(); }
      });
    }
  });
})();
