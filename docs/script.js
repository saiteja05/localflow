/* ============================================================
   localflow — liquid glass interactions
   1) orb video fallback (if the external .webm won't load)
   2) before -> after cleanup demo
   3) scroll reveals + year
   ============================================================ */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = new Date().getFullYear();

  /* -------- orb video fallback -------- */
  (function orb() {
    var wrap = document.querySelector(".hero-orb");
    var video = wrap ? wrap.querySelector(".orb-video") : null;
    if (!wrap || !video) return;
    function fail() { wrap.classList.add("no-video"); }
    video.addEventListener("error", fail, true);
    // if the external asset hasn't started within a few seconds, fall back
    setTimeout(function () {
      if (video.readyState < 2 || video.networkState === 3) fail();
    }, 4000);
  })();

  /* -------- scroll reveals -------- */
  var revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -8% 0px" });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("in"); });
  }

  /* -------- before -> after cleanup demo -------- */
  (function cleanupDemo() {
    var beforeEl = document.getElementById("demo-before-text");
    var afterEl = document.getElementById("demo-after-text");
    if (!beforeEl || !afterEl) return;

    var pairs = [
      { raw: "um so i think we should uh no wait we should definitely um ship on friday",
        clean: "I think we should definitely ship on Friday." },
      { raw: "hey can you uh send me the the deck before like end of day thanks",
        clean: "Hey, can you send me the deck before end of day? Thanks." },
      { raw: "lets add eggs scratch that add milk and um bread to the list",
        clean: "Let's add milk and bread to the list." }
    ];
    var idx = 0;

    function type(el, text, speed) {
      return new Promise(function (resolve) {
        el.classList.add("typing"); el.textContent = "";
        var i = 0;
        (function step() {
          if (i <= text.length) { el.textContent = text.slice(0, i); i++; setTimeout(step, speed); }
          else { el.classList.remove("typing"); resolve(); }
        })();
      });
    }
    function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
    function visible(el) {
      return new Promise(function (resolve) {
        if (!("IntersectionObserver" in window)) return resolve();
        var o = new IntersectionObserver(function (entries) {
          if (entries[0].isIntersecting) { o.disconnect(); resolve(); }
        }, { threshold: 0.3 });
        o.observe(el);
      });
    }

    async function run() {
      if (reduceMotion) { beforeEl.textContent = pairs[0].raw; afterEl.textContent = pairs[0].clean; return; }
      await visible(beforeEl);
      while (true) {
        var p = pairs[idx % pairs.length];
        afterEl.textContent = "";
        await type(beforeEl, p.raw, 26);
        await wait(650);
        await type(afterEl, p.clean, 30);
        await wait(2600);
        idx++;
      }
    }
    run();
  })();
})();
