// Amber host integration for the bundled transitions.dev runtime; no generated progress logs.
let consumed = false;
let generation = 0;
let active = null;
let preparing = false;
let cleanup = () => {};
const pause = (ms) => new Promise(resolve => setTimeout(resolve, ms));
const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));

function cancelGeneration() {
  if (preparing || active) consumed = true;
  preparing = false;
  generation++;
  cleanup();
  cleanup = () => {};
  if (active) active.cancel();
  active = null;
}

async function playGeneration(selector, reduceMotion) {
  if (consumed || preparing) return consumed;
  const media = matchMedia('(prefers-reduced-motion: reduce)');
  if (reduceMotion || media.matches) { consumed = true; return true; }
  preparing = true;
  const request = ++generation;

  const events = ['pointerdown', 'touchstart', 'keydown', 'scroll', 'pagehide'];
  events.forEach(name => window.addEventListener(name, cancelGeneration, {capture: true, passive: true}));
  let resumeVisibility;
  const visible = () => document.hidden ? new Promise(resolve => { resumeVisibility = resolve; }) : Promise.resolve();
  const visibilityChanged = () => {
    if (!document.hidden) resumeVisibility?.();
    else if (active) cancelGeneration();
  };
  const resized = () => { if (active) cancelGeneration(); };
  document.addEventListener('visibilitychange', visibilityChanged);
  window.addEventListener('resize', resized);
  media.addEventListener('change', cancelGeneration);
  let observer;
  let watchdog;
  const imageWaiters = [];
  cleanup = () => {
    events.forEach(name => window.removeEventListener(name, cancelGeneration, true));
    document.removeEventListener('visibilitychange', visibilityChanged);
    window.removeEventListener('resize', resized);
    resumeVisibility?.();
    imageWaiters.forEach(finish => finish());
    media.removeEventListener('change', cancelGeneration);
    if (observer) observer.disconnect();
    clearTimeout(watchdog);
  };

  await visible();
  if (request !== generation) return consumed;
  await Promise.race([document.fonts.ready, pause(500)]);
  // Allow the native card's asynchronous height report to settle before measuring.
  await pause(120);
  await nextFrame();
  await nextFrame();
  if (request !== generation) return consumed;
  let element = selector.split(',').map(value => document.querySelector(value.trim())).find(Boolean);
  if (!element || element === document.body) {
    element = [...document.body.children].find(node =>
      !node.matches('script, style, .t-gen') && node.getBoundingClientRect().height >= 60);
  }
  if (!element) { cancelGeneration(); return true; }
  const images = [...element.querySelectorAll('img')].filter(img => !img.complete);
  // Keep the result visible while images load; input or closing the page cancels this wait.
  await Promise.race([Promise.all(images.map(img => new Promise(resolve => {
    const finish = () => {
      img.removeEventListener('load', finish);
      img.removeEventListener('error', finish);
      resolve();
    };
    imageWaiters.push(finish);
    img.addEventListener('load', finish, {once: true});
    img.addEventListener('error', finish, {once: true});
  }))), pause(3000)]);
  if (request !== generation) return consumed;
  await visible();
  if (request !== generation) return consumed;
  // A stalled image ends this decoration attempt; never hide content or schedule retries.
  if (images.some(img => !img.complete)) { cancelGeneration(); return true; }
  const rect = element.getBoundingClientRect();
  // shortcut: animate one viewport-sized card; large documents need a dedicated bounded preview.
  if (rect.width < 120 || rect.height < 60 || rect.width > innerWidth + 2 || rect.height > innerHeight + 2 ||
      rect.bottom <= 0 || rect.top >= innerHeight || element.querySelectorAll('*').length > 400) {
    cancelGeneration(); return true;
  }
  observer = new ResizeObserver(() => {
    const current = element.getBoundingClientRect();
    if (Math.abs(current.width - rect.width) > 1 || Math.abs(current.height - rect.height) > 1) cancelGeneration();
  });
  observer.observe(element);
  active = generate(element, {mode: 'skeleton', maxParts: 40});
  consumed = true;
  preparing = false;
  // A runtime/frame failure must not leave an otherwise usable result transparent.
  watchdog = setTimeout(cancelGeneration, 3200);
  active.finished.then(() => { if (request === generation) cancelGeneration(); });
  return true;
}

window.__amberGenerationCancel = cancelGeneration;
window.__amberGenerationPlay = (selector, reduceMotion) => {
  return playGeneration(selector, reduceMotion).catch(error => {
    preparing = false;
    cancelGeneration();
    console.warn('Amber UI reveal failed; keeping the result visible', error);
    return false;
  });
};
