/* ============================================================
   localflow — editorial version interactions
   1) animated wordmark (letter stagger)
   2) light waveform background
   3) auto-cycling chapters + counter
   4) hamburger + scroll reveals
   ============================================================ */
(function () {
  "use strict";
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* -------- wordmark letters -------- */
  var wm = document.querySelector(".wordmark");
  if (wm) {
    var word = wm.getAttribute("data-word") || "localflow";
    wm.textContent = "";
    word.split("").forEach(function (ch, i) {
      var s = document.createElement("span");
      s.className = "ltr";
      s.textContent = ch;
      s.style.animationDelay = (0.1 + i * 0.06) + "s";
      wm.appendChild(s);
    });
  }

  /* -------- hamburger -------- */
  var burger = document.getElementById("hamburger");
  var menu = document.getElementById("mobileMenu");
  if (burger && menu) {
    burger.addEventListener("click", function () {
      var open = burger.getAttribute("aria-expanded") === "true";
      burger.setAttribute("aria-expanded", String(!open));
      menu.hidden = open;
    });
  }

  /* -------- scroll reveals -------- */
  var rev = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduce) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { threshold: 0.2 });
    rev.forEach(function (el) { io.observe(el); });
  } else { rev.forEach(function (el) { el.classList.add("in"); }); }

  /* -------- auto-cycling chapters -------- */
  (function chapters() {
    var items = Array.prototype.slice.call(document.querySelectorAll(".chap"));
    var counter = document.getElementById("chapCounter");
    var label = document.getElementById("chapLabel");
    if (!items.length) return;
    var active = 0, timer = null;
    function set(i) {
      active = i;
      items.forEach(function (el, k) { el.classList.toggle("active", k === i); });
      var n = String(i + 1).padStart(2, "0");
      if (counter) counter.textContent = n;
      if (label) label.textContent = "Chapter " + n;
    }
    function start() { if (reduce) return; timer = setInterval(function () { set((active + 1) % items.length); }, 3500); }
    items.forEach(function (el, k) {
      el.addEventListener("click", function () { set(k); clearInterval(timer); start(); });
    });
    set(0); start();
  })();

  /* -------- light waveform background -------- */
  (function wave() {
    var c = document.getElementById("bgwave");
    if (!c) return;
    var ctx = c.getContext("2d");
    var w = 0, h = 0, dpr = Math.min(window.devicePixelRatio || 1, 2), t = 0, raf = null;
    var layers = [
      { amp: 0.10, freq: 1.5, speed: 0.006, y: 0.62, width: 1.2, alpha: 0.28 },
      { amp: 0.16, freq: 1.0, speed: 0.004, y: 0.70, width: 1.4, alpha: 0.16 },
      { amp: 0.06, freq: 2.6, speed: 0.011, y: 0.66, width: 0.9, alpha: 0.12 }
    ];
    function resize() { w = c.clientWidth; h = c.clientHeight; c.width = w * dpr; c.height = h * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0); }
    function draw(L) {
      var mid = h * L.y, amp = h * L.amp;
      ctx.beginPath();
      for (var x = 0; x <= w; x += 6) {
        var nx = x / w, env = 0.55 + 0.45 * Math.sin(nx * Math.PI);
        var yy = mid + Math.sin(nx * Math.PI * 2 * L.freq + t * L.speed * 60) * amp * env;
        x === 0 ? ctx.moveTo(x, yy) : ctx.lineTo(x, yy);
      }
      ctx.lineWidth = L.width; ctx.strokeStyle = "rgba(17,17,17," + L.alpha + ")"; ctx.stroke();
    }
    function frame() { ctx.clearRect(0, 0, w, h); layers.forEach(draw); t += 1; raf = requestAnimationFrame(frame); }
    resize(); window.addEventListener("resize", resize);
    if (reduce) { layers.forEach(draw); return; }
    frame();
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) { if (!raf) frame(); } else if (raf) { cancelAnimationFrame(raf); raf = null; } });
      }, { threshold: 0 }).observe(c);
    }
  })();
})();
