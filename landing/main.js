/**
 * Subtle 3D parallax for the hero stage.
 * Respects prefers-reduced-motion.
 */
(() => {
  const header = document.querySelector(".site-header");
  const stage = document.getElementById("hero-stage");
  const scene = document.getElementById("stage-scene");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Sticky header border
  const onScroll = () => {
    if (!header) return;
    header.classList.toggle("is-scrolled", window.scrollY > 8);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  if (!stage || !scene || reduceMotion) return;

  let raf = 0;
  let targetX = 0;
  let targetY = 0;
  let currentX = 0;
  let currentY = 0;

  const base = { rotateX: 12, rotateY: -18 };

  const render = () => {
    currentX += (targetX - currentX) * 0.08;
    currentY += (targetY - currentY) * 0.08;
    scene.style.transform =
      `rotateX(${base.rotateX + currentY}deg) rotateY(${base.rotateY + currentX}deg)`;
    raf = requestAnimationFrame(render);
  };

  const onMove = (event) => {
    const rect = stage.getBoundingClientRect();
    const px = (event.clientX - rect.left) / rect.width - 0.5;
    const py = (event.clientY - rect.top) / rect.height - 0.5;
    targetX = px * 14;
    targetY = -py * 10;
  };

  const onLeave = () => {
    targetX = 0;
    targetY = 0;
  };

  stage.addEventListener("pointermove", onMove);
  stage.addEventListener("pointerleave", onLeave);
  raf = requestAnimationFrame(render);

  // Pause when off-screen
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          cancelAnimationFrame(raf);
          raf = requestAnimationFrame(render);
        } else {
          cancelAnimationFrame(raf);
        }
      },
      { threshold: 0.05 }
    );
    io.observe(stage);
  }
})();
