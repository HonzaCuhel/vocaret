const transcriptLines = [
  "Capture the idea while it’s fresh.",
  "Dneska projdu výsledky.",
  "The right words, in the right place.",
  "One shortcut. Keep the thought.",
  "Pak pustím zkratku. Text se vloží.",
  "No window change. Keep moving.",
  "Let’s ship it.",
];

const transcript = document.querySelector("[data-transcript]");
const stage = document.querySelector(".caption-stage");
const motionButton = document.querySelector("[data-motion]");
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let transcriptIndex = 4;
let transcriptInterval;
let transcriptTimeout;
let manuallyPaused = false;
let stageVisible = true;

function renderTranscript() {
  if (!transcript) return;
  const visible = Array.from({ length: 4 }, (_, offset) => {
    const index = (transcriptIndex - 3 + offset + transcriptLines.length) % transcriptLines.length;
    return transcriptLines[index];
  });
  transcript.classList.add("is-updating");
  transcriptTimeout = window.setTimeout(() => {
    const paragraphs = transcript.querySelectorAll("p");
    paragraphs.forEach((paragraph, index) => {
      paragraph.textContent = visible[index];
      paragraph.classList.toggle("is-current", index === paragraphs.length - 1);
      paragraph.classList.toggle("is-short", index === paragraphs.length - 1 && visible[index].split(/\s+/).length <= 3);
    });
    const cursor = document.createElement("span");
    cursor.className = "cursor";
    paragraphs[paragraphs.length - 1]?.append(cursor);
    transcript.classList.remove("is-updating");
    transcriptIndex = (transcriptIndex + 1) % transcriptLines.length;
  }, 180);
}

function updateMotion() {
  window.clearInterval(transcriptInterval);
  window.clearTimeout(transcriptTimeout);
  transcript?.classList.remove("is-updating");
  const paused = manuallyPaused || reduceMotion.matches || document.hidden || !stageVisible;
  stage?.classList.toggle("motion-paused", paused);
  if (transcript && !paused) transcriptInterval = window.setInterval(renderTranscript, 2_600);
  if (motionButton) {
    motionButton.textContent = manuallyPaused ? "Resume animation" : "Pause animation";
    motionButton.setAttribute("aria-pressed", String(manuallyPaused));
  }
}

motionButton?.classList.add("is-ready");
motionButton?.addEventListener("click", () => {
  manuallyPaused = !manuallyPaused;
  updateMotion();
});
reduceMotion.addEventListener("change", updateMotion);
document.addEventListener("visibilitychange", updateMotion);
if (stage && "IntersectionObserver" in window) {
  new IntersectionObserver(([entry]) => {
    stageVisible = entry.isIntersecting;
    updateMotion();
  }).observe(stage);
}
updateMotion();

const copyStatus = document.querySelector("[data-copy-status]");
document.querySelectorAll("[data-copy]").forEach((button) => {
  let resetTimeout;
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copy);
    if (!target) return;
    window.clearTimeout(resetTimeout);
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      button.dataset.copied = "true";
      button.querySelector("span").textContent = "Copied";
      if (copyStatus) copyStatus.textContent = "Command copied to clipboard.";
      resetTimeout = window.setTimeout(() => {
        delete button.dataset.copied;
        button.querySelector("span").textContent = "Copy";
      }, 1_500);
    } catch {
      window.getSelection()?.selectAllChildren(target);
      button.querySelector("span").textContent = "Selected";
      if (copyStatus) copyStatus.textContent = "Clipboard unavailable. The command is selected; press Control+C or Command+C to copy.";
    }
  });
});
