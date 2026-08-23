const transcriptLines = [
  "Capture the idea while it’s fresh.",
  "Dneska projdu výsledky.",
  "Audio stays local on this Mac.",
  "Soniox streams words live.",
  "Pak pustím zkratku. Text se vloží.",
  "No window change. Keep moving.",
  "Let’s ship it.",
];

const transcript = document.querySelector("[data-transcript]");
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let transcriptIndex = 4;

function renderTranscript() {
  if (!transcript) return;
  const visible = Array.from({ length: 4 }, (_, offset) => {
    const index = (transcriptIndex - 3 + offset + transcriptLines.length) % transcriptLines.length;
    return transcriptLines[index];
  });

  transcript.classList.add("is-updating");
  window.setTimeout(() => {
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

if (transcript && !reduceMotion.matches) {
  window.setInterval(renderTranscript, 2_600);
}

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copy);
    if (!target) return;

    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      button.dataset.copied = "true";
      button.querySelector("span").textContent = "Copied";
      window.setTimeout(() => {
        delete button.dataset.copied;
        button.querySelector("span").textContent = "Copy";
      }, 1_500);
    } catch {
      target.focus?.();
      window.getSelection()?.selectAllChildren(target);
      button.querySelector("span").textContent = "Select text";
    }
  });
});
