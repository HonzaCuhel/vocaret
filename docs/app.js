/* Original WebGL voice sculpture. No CDN, framework, microphone or network calls. */
(() => {
  const stage = document.querySelector("[data-stage]");
  const canvas = document.querySelector("#voice-space");
  const toggle = document.querySelector("[data-motion]");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const status = document.querySelector("[data-scene-status]");
  let paused = false,
    visible = true,
    lost = false,
    frame = 0,
    last = 0,
    time = 0;
  let targetX = 0,
    targetY = 0,
    pointerX = 0,
    pointerY = 0,
    mode = 0;
  let gl,
    program,
    buffer,
    uniforms,
    count = 0;
  const examples = {
    dictate: [
      "Dictation",
      "Capture the idea\nwhile it’s fresh.",
      "Hold ⌃⌥D · speak · release",
      0,
    ],
    meeting: [
      "Local meeting",
      "Stay with the conversation.\nFollow both sides.",
      "Mic + system audio · on your Mac",
      1,
    ],
    remember: [
      "Remember",
      "Keep this thought.\nMake it your own.",
      "Edit the local draft · save explicitly",
      2,
    ],
  };
  document.querySelectorAll("[data-mode]").forEach((button) =>
    button.addEventListener("click", () => {
      const example = examples[button.dataset.mode];
      document.querySelector("[data-widget-state]").textContent = example[0];
      document.querySelector("[data-widget-copy]").textContent = example[1];
      document.querySelector("[data-widget-detail]").textContent = example[2];
      document
        .querySelectorAll("[data-mode]")
        .forEach((item) =>
          item.setAttribute("aria-pressed", String(item === button)),
        );
      mode = example[3];
      render();
    }),
  );
  function fallback() {
    cancelAnimationFrame(frame);
    frame = 0;
    stage.dataset.renderer = "fallback";
    stage.dataset.animating = "false";
    status.textContent = "Static illustration · 3D unavailable";
    toggle.hidden = true;
  }
  function shader(type, source) {
    const result = gl.createShader(type);
    gl.shaderSource(result, source);
    gl.compileShader(result);
    if (!gl.getShaderParameter(result, gl.COMPILE_STATUS)) {
      gl.deleteShader(result);
      throw new Error("Shader unavailable");
    }
    return result;
  }
  function setup() {
    try {
      gl = canvas.getContext("webgl", {
        alpha: true,
        antialias: false,
        powerPreference: "low-power",
        preserveDrawingBuffer: false,
      });
      if (!gl) {
        fallback();
        return;
      }
      const vertex = shader(
        gl.VERTEX_SHADER,
        `
        attribute vec4 point;
        uniform float time, aspect, pixelRatio, mode;
        uniform vec2 pointer;
        varying vec3 tint;
        varying float opacity;
        void main() {
          vec3 p = point.xyz;
          float a = time * .14 + pointer.x * .45;
          float b = -.22 + pointer.y * .32;
          float pulse = 1.0 + .035 * sin(time * 1.6 + p.y * 4.0);
          p *= pulse;
          p.xz = mat2(cos(a), -sin(a), sin(a), cos(a)) * p.xz;
          p.yz = mat2(cos(b), -sin(b), sin(b), cos(b)) * p.yz;
          float depth = 3.5 - p.z;
          vec2 projected = p.xy * 2.55 / depth;
          projected.x /= aspect;
          projected.y += .16;
          gl_Position = vec4(projected, 0., 1.);
          gl_PointSize = clamp((point.w + 1.1) * 3.0 / depth * pixelRatio, 1.0, 8.0);
          tint = mix(vec3(.32,.85,1.), vec3(.66,.46,1.), clamp((p.y+1.5)/3.0 + mode*.12,0.,1.));
          opacity = .25 + .7 * ((p.z + 1.7) / 3.4);
        }`,
      );
      const fragment = shader(
        gl.FRAGMENT_SHADER,
        `precision mediump float; varying vec3 tint; varying float opacity; void main(){float d=length(gl_PointCoord-vec2(.5));float a=(1.-smoothstep(.12,.5,d))*opacity;gl_FragColor=vec4(tint,a);}`,
      );
      program = gl.createProgram();
      gl.attachShader(program, vertex);
      gl.attachShader(program, fragment);
      gl.linkProgram(program);
      gl.deleteShader(vertex);
      gl.deleteShader(fragment);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS))
        throw new Error("Program unavailable");
      const points = [];
      // Deterministic Fibonacci sphere with intersecting orbital bands, all true 3D points.
      const total = 1900;
      for (let i = 0; i < total; i++) {
        const y = 1 - (2 * (i + 0.5)) / total,
          radius = Math.sqrt(1 - y * y),
          angle = i * 2.3999632297;
        points.push(
          Math.cos(angle) * radius,
          y,
          Math.sin(angle) * radius,
          0.7 + (i % 5) * 0.2,
        );
      }
      for (let ring = 0; ring < 3; ring++)
        for (let i = 0; i < 460; i++) {
          const a = (i / 460) * Math.PI * 2,
            tilt = 0.55 + ring * 0.8,
            r = 1.35 + ring * 0.13;
          points.push(
            Math.cos(a) * r,
            Math.sin(a) * r * Math.cos(tilt),
            Math.sin(a) * r * Math.sin(tilt),
            0.45,
          );
        }
      count = points.length / 4;
      buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(points), gl.STATIC_DRAW);
      gl.useProgram(program);
      const location = gl.getAttribLocation(program, "point");
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, 4, gl.FLOAT, false, 0, 0);
      uniforms = Object.fromEntries(
        ["time", "aspect", "pixelRatio", "mode", "pointer"].map((name) => [
          name,
          gl.getUniformLocation(program, name),
        ]),
      );
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE);
      gl.clearColor(0, 0, 0, 0);
      lost = false;
      stage.dataset.renderer = "webgl";
      toggle.hidden = false;
      resize();
      update();
    } catch {
      fallback();
    }
  }
  function render() {
    if (!gl || lost || stage.dataset.renderer !== "webgl") return;
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(program);
    gl.uniform1f(uniforms.time, time);
    gl.uniform1f(uniforms.aspect, canvas.width / canvas.height);
    gl.uniform1f(uniforms.pixelRatio, Math.min(devicePixelRatio || 1, 1.75));
    gl.uniform1f(uniforms.mode, mode);
    gl.uniform2f(uniforms.pointer, pointerX, pointerY);
    gl.drawArrays(gl.POINTS, 0, count);
  }
  function resize() {
    const bounds = canvas.getBoundingClientRect(),
      dpr = Math.min(devicePixelRatio || 1, 1.75);
    canvas.width = Math.max(1, Math.round(bounds.width * dpr));
    canvas.height = Math.max(1, Math.round(bounds.height * dpr));
    if (gl && !lost) gl.viewport(0, 0, canvas.width, canvas.height);
    render();
  }
  function canAnimate() {
    return (
      !paused &&
      !reduced.matches &&
      !document.hidden &&
      visible &&
      !lost &&
      stage.dataset.renderer === "webgl"
    );
  }
  function tick(now) {
    frame = 0;
    if (!canAnimate()) {
      update();
      return;
    }
    // Limit drawing to 30 fps, including high refresh-rate displays.
    if (now - last >= 32) {
      time += Math.min((now - last) / 1000, 0.05);
      last = now;
      pointerX += (targetX - pointerX) * 0.07;
      pointerY += (targetY - pointerY) * 0.07;
      render();
    }
    frame = requestAnimationFrame(tick);
  }
  function update() {
    cancelAnimationFrame(frame);
    frame = 0;
    const active = canAnimate();
    stage.dataset.animating = String(active);
    document.body.classList.toggle("motion-paused", paused || reduced.matches);
    toggle.textContent = reduced.matches
      ? "Reduced motion"
      : paused
        ? "Resume motion"
        : "Pause motion";
    toggle.disabled = reduced.matches;
    toggle.setAttribute("aria-pressed", String(paused || reduced.matches));
    if (stage.dataset.renderer === "webgl")
      status.textContent = reduced.matches
        ? "3D illustration · reduced motion"
        : paused
          ? "3D illustration · paused"
          : "Interactive 3D · move your pointer";
    if (active) {
      last = performance.now();
      frame = requestAnimationFrame(tick);
    } else render();
  }
  toggle.addEventListener("click", () => {
    paused = !paused;
    update();
  });
  reduced.addEventListener("change", update);
  document.addEventListener("visibilitychange", update);
  stage.addEventListener(
    "pointermove",
    (event) => {
      if (!canAnimate() || event.pointerType === "touch") return;
      const r = stage.getBoundingClientRect();
      targetX = (event.clientX - r.left) / r.width - 0.5;
      targetY = (event.clientY - r.top) / r.height - 0.5;
    },
    { passive: true },
  );
  stage.addEventListener("pointerleave", () => {
    targetX = targetY = 0;
  });
  if ("IntersectionObserver" in window)
    new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      update();
    }).observe(stage);
  if ("ResizeObserver" in window) new ResizeObserver(resize).observe(stage);
  else window.addEventListener("resize", resize);
  canvas.addEventListener("webglcontextlost", (event) => {
    event.preventDefault();
    lost = true;
    fallback();
  });
  canvas.addEventListener("webglcontextrestored", setup);
  window.addEventListener("pagehide", () => {
    cancelAnimationFrame(frame);
    frame = 0;
  });
  window.addEventListener("pageshow", update);
  setup();
})();
