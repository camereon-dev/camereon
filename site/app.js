(() => {
  const root = document.documentElement;
  const toggle = document.querySelector(".theme-toggle");
  const systemTheme = matchMedia("(prefers-color-scheme: dark)");
  let preference = "system";
  try {
    preference = localStorage.getItem("camereon-theme") || "system";
  } catch {}

  function updateTheme() {
    const dark =
      preference === "dark" || (preference === "system" && systemTheme.matches);
    root.dataset.theme = dark ? "dark" : "light";
    toggle.setAttribute(
      "aria-label",
      dark ? "ライトモードに切り替える" : "ダークモードに切り替える",
    );
    document.querySelector('meta[name="theme-color"]').content = dark
      ? "#121b16"
      : "#f6f7f2";
  }

  toggle.hidden = false;
  toggle.addEventListener("click", () => {
    preference = root.dataset.theme === "dark" ? "light" : "dark";
    try {
      localStorage.setItem("camereon-theme", preference);
    } catch {}
    updateTheme();
  });
  systemTheme.addEventListener("change", updateTheme);
  updateTheme();

  // Only the ink moves: the headline itself stays still and readable.
  const headline = document.querySelector("#hero-title");
  const hero = document.querySelector(".hero");
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let visible = true;
  let frame = 0;
  let heroHeight = hero.offsetHeight;
  let pointerX = 0.5;
  let pointerY = 0.5;
  let inkX = 45;
  let inkY = 50;
  let inkTurn = 30;

  function scheduleInk() {
    if (!frame && visible && !reducedMotion.matches) {
      frame = requestAnimationFrame(paintInk);
    }
  }

  function paintInk() {
    frame = 0;
    if (!visible || reducedMotion.matches) return;
    const progress = Math.min(1, Math.max(0, scrollY / heroHeight));
    const targetX = 15 + pointerX * 60 + progress * 35;
    const targetY = 20 + pointerY * 60 - progress * 30;
    const targetTurn = -110 + pointerX * 220 + pointerY * 60 + progress * 250;
    inkX += (targetX - inkX) * 0.12;
    inkY += (targetY - inkY) * 0.12;
    inkTurn += (targetTurn - inkTurn) * 0.12;
    headline.style.setProperty("--ink-x", `${inkX.toFixed(2)}%`);
    headline.style.setProperty("--ink-y", `${inkY.toFixed(2)}%`);
    headline.style.setProperty("--ink-turn", `${inkTurn.toFixed(2)}deg`);
    if (
      Math.abs(targetX - inkX) > 0.03 ||
      Math.abs(targetY - inkY) > 0.03 ||
      Math.abs(targetTurn - inkTurn) > 0.03
    )
      scheduleInk();
  }

  addEventListener(
    "pointermove",
    (event) => {
      if (event.pointerType === "touch") return;
      pointerX = event.clientX / innerWidth;
      pointerY = event.clientY / innerHeight;
      scheduleInk();
    },
    { passive: true },
  );
  addEventListener("scroll", scheduleInk, { passive: true });
  addEventListener(
    "resize",
    () => {
      heroHeight = hero.offsetHeight;
      scheduleInk();
    },
    { passive: true },
  );
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) scheduleInk();
  }).observe(hero);
  reducedMotion.addEventListener("change", () => {
    if (reducedMotion.matches) {
      cancelAnimationFrame(frame);
      frame = 0;
      ["--ink-x", "--ink-y", "--ink-turn"].forEach((name) =>
        headline.style.removeProperty(name),
      );
    } else {
      scheduleInk();
    }
  });
  scheduleInk();
})();
