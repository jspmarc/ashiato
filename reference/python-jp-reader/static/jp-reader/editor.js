/* jp-reader — the rotation controls, shared by the upload page and the
 * detail page's editor.
 *
 * The browser's preview is a CSS turn; the server's result is the one that
 * counts. `fitScale` is the same "rotate and fit the frame" trick a desktop
 * image editor uses.
 */
(function () {
  "use strict";

  function $(id) { return document.getElementById(id); }

  function normalise(angle) {
    var value = angle % 360;
    if (value > 180) { value -= 360; }
    if (value < -180) { value += 360; }
    return Math.round(value * 10) / 10;
  }

  function fitScale(degrees) {
    var rad = degrees * Math.PI / 180;
    return 1 / (Math.abs(Math.cos(rad)) + Math.abs(Math.sin(rad)));
  }

  function transformFor(degrees) {
    return "rotate(" + degrees + "deg) scale(" + fitScale(degrees) + ")";
  }

  /* Wires up the angle controls and calls back with the new angle.
   * Returns the current angle. */
  function init(onChange, initial) {
    var angle = normalise(initial || 0);

    function set(value) {
      angle = normalise(value);
      var slider = $("jr-angle");
      var number = $("jr-angle-num");
      if (slider) { slider.value = angle; }
      if (number) { number.value = angle; }
      if (onChange) { onChange(angle); }
    }

    var slider = $("jr-angle");
    if (slider) {
      slider.addEventListener("input", function () {
        set(parseFloat(slider.value) || 0);
      });
    }
    var number = $("jr-angle-num");
    if (number) {
      number.addEventListener("input", function () {
        var value = parseFloat(number.value);
        if (!isNaN(value)) { set(value); }
      });
    }
    Array.prototype.forEach.call(
      document.querySelectorAll("[data-rot]"),
      function (button) {
        button.addEventListener("click", function () {
          set(angle + parseFloat(button.dataset.rot));
        });
      }
    );
    var down = $("jr-rot-down");
    if (down) { down.addEventListener("click", function () { set(angle - 0.1); }); }
    var up = $("jr-rot-up") ;
    if (up) { up.addEventListener("click", function () { set(angle + 0.1); }); }

    set(angle);
    return angle;
  }

  window.JREditor = {
    init: init,
    normalise: normalise,
    fitScale: fitScale,
    transformFor: transformFor,
  };
})();
