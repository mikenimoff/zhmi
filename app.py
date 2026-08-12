#!/usr/bin/env python3
import json
import os
import selectors
import signal
import subprocess
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8766
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}
STALL_TIMEOUT_SECONDS = 120

FFMPEG = os.environ.get("FFMPEG", "/opt/homebrew/bin/ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "/opt/homebrew/bin/ffprobe")

RESOLUTIONS = {
    "original": None,
    "1440": 1440,
    "1080": 1080,
    "720": 720,
}

COMPRESSION = {
    "light": {"crf": "23", "preset": "fast", "audio": "160k"},
    "balanced": {"crf": "28", "preset": "veryfast", "audio": "128k"},
    "strong": {"crf": "32", "preset": "veryfast", "audio": "96k"},
    "maximum": {"crf": "36", "preset": "veryfast", "audio": "64k"},
}


INDEX_HTML = r"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Жми</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f5f7;
      --panel: rgba(255,255,255,.82);
      --panel-strong: #fff;
      --text: #1d1d1f;
      --muted: #6e6e73;
      --line: rgba(0,0,0,.12);
      --accent: #0071e3;
      --accent-press: #005bb5;
      --danger: #d92d20;
      --ok: #1c7c36;
      --shadow: 0 20px 55px rgba(0,0,0,.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--text);
      font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
      letter-spacing: 0;
    }
    main {
      width: min(1040px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 42px 0;
    }
    header {
      display: flex;
      align-items: end;
      justify-content: space-between;
      gap: 20px;
      margin-bottom: 22px;
    }
    h1 {
      margin: 0;
      font-size: 44px;
      line-height: 1.05;
      font-weight: 760;
    }
    .subtitle {
      margin: 8px 0 0;
      color: var(--muted);
      font-size: 17px;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 32px;
      padding: 6px 12px;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: var(--muted);
      background: rgba(255,255,255,.55);
      white-space: nowrap;
    }
    .dot {
      width: 8px;
      height: 8px;
      border-radius: 99px;
      background: #8e8e93;
    }
    .dot.running { background: var(--accent); box-shadow: 0 0 0 4px rgba(0,113,227,.12); }
    .dot.done { background: var(--ok); }
    .dot.error { background: var(--danger); }
    .grid {
      display: grid;
      grid-template-columns: 1fr 360px;
      gap: 18px;
      align-items: start;
    }
    section, aside {
      background: var(--panel);
      border: 1px solid rgba(255,255,255,.75);
      border-radius: 18px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(22px);
    }
    section { padding: 22px; }
    aside { padding: 18px; position: sticky; top: 18px; }
    .stack { display: grid; gap: 18px; }
    .row {
      display: grid;
      gap: 10px;
    }
    label {
      color: var(--muted);
      font-size: 13px;
      font-weight: 650;
    }
    .folder-line {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 10px;
      align-items: center;
    }
    .path {
      min-height: 42px;
      display: flex;
      align-items: center;
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 10px;
      background: rgba(255,255,255,.7);
      color: var(--muted);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    button, select {
      appearance: none;
      border: 0;
      border-radius: 10px;
      font: inherit;
      min-height: 42px;
    }
    button {
      padding: 0 15px;
      background: #e8e8ed;
      color: var(--text);
      cursor: pointer;
      font-weight: 650;
    }
    button:hover { filter: brightness(.98); }
    button:active { transform: translateY(1px); }
    button.primary {
      width: 100%;
      background: var(--accent);
      color: #fff;
      min-height: 48px;
      font-size: 16px;
    }
    button.primary:active { background: var(--accent-press); }
    button.danger {
      width: 100%;
      background: #fff1f0;
      color: var(--danger);
      border: 1px solid rgba(217,45,32,.2);
    }
    button:disabled {
      opacity: .48;
      cursor: default;
      transform: none;
    }
    .controls {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 14px;
    }
    select {
      width: 100%;
      padding: 0 38px 0 12px;
      border: 1px solid var(--line);
      background:
        linear-gradient(45deg, transparent 50%, #86868b 50%) calc(100% - 18px) 18px / 7px 7px no-repeat,
        linear-gradient(135deg, #86868b 50%, transparent 50%) calc(100% - 13px) 18px / 7px 7px no-repeat,
        rgba(255,255,255,.75);
      color: var(--text);
    }
    .summary {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 10px;
    }
    .metric {
      background: rgba(255,255,255,.62);
      border: 1px solid rgba(0,0,0,.08);
      border-radius: 12px;
      padding: 12px;
    }
    .metric strong { display: block; font-size: 22px; line-height: 1.05; }
    .metric span { color: var(--muted); font-size: 12px; }
    .progress-label {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 8px;
    }
    .bar {
      width: 100%;
      height: 10px;
      border-radius: 99px;
      background: #d9d9de;
      overflow: hidden;
    }
    .bar > div {
      height: 100%;
      width: 0%;
      border-radius: inherit;
      background: linear-gradient(90deg, #0071e3, #34c759);
      transition: width .2s ease;
    }
    .log {
      min-height: 180px;
      max-height: 300px;
      overflow: auto;
      border-radius: 12px;
      border: 1px solid var(--line);
      background: rgba(255,255,255,.72);
      padding: 12px;
      color: #3a3a3c;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      white-space: pre-wrap;
    }
    .hint { color: var(--muted); font-size: 13px; margin: 0; }
    @media (max-width: 860px) {
      main { padding: 24px 0; }
      header, .grid, .controls { grid-template-columns: 1fr; display: grid; }
      h1 { font-size: 36px; }
      aside { position: static; }
      .summary { grid-template-columns: 1fr; }
      .folder-line { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Жми</h1>
        <p class="subtitle">Пакетное сжатие видео без лишних окон.</p>
      </div>
      <div class="pill"><span id="statusDot" class="dot"></span><span id="statusText">Готово</span></div>
    </header>

    <div class="grid">
      <section class="stack">
        <div class="row">
          <label>Папка с видео</label>
          <div class="folder-line">
            <div id="inputPath" class="path">Не выбрана</div>
            <button id="pickInput">Выбрать</button>
          </div>
        </div>

        <div class="row">
          <label>Папка для готовых файлов</label>
          <div class="folder-line">
            <div id="outputPath" class="path">Не выбрана</div>
            <button id="pickOutput">Выбрать</button>
          </div>
        </div>

        <div class="controls">
          <div class="row">
            <label>Разрешение</label>
            <select id="resolution">
              <option value="original">Оригинал</option>
              <option value="1440">2560 x 1440</option>
              <option value="1080" selected>1920 x 1080</option>
              <option value="720">1280 x 720</option>
            </select>
          </div>
          <div class="row">
            <label>Сжатие</label>
            <select id="compression">
              <option value="light">Легкое</option>
              <option value="balanced" selected>Сбалансированное</option>
              <option value="strong">Сильное</option>
              <option value="maximum">Максимальное</option>
            </select>
          </div>
        </div>

        <div class="summary">
          <div class="metric"><strong id="fileCount">0</strong><span>файлов найдено</span></div>
          <div class="metric"><strong id="doneCount">0</strong><span>готово</span></div>
          <div class="metric"><strong id="failedCount">0</strong><span>ошибок</span></div>
        </div>

        <div>
          <div class="progress-label"><span>Общий прогресс</span><span id="overallPercent">0%</span></div>
          <div class="bar"><div id="overallBar"></div></div>
        </div>
        <div>
          <div class="progress-label"><span id="currentFile">Текущий файл</span><span id="currentPercent">0%</span></div>
          <div class="bar"><div id="currentBar"></div></div>
        </div>

        <div class="log" id="log">Выберите папки и нажмите «Начать сжатие».</div>
      </section>

      <aside class="stack">
        <button id="start" class="primary">Начать сжатие</button>
        <button id="stop" class="danger" disabled>Остановить</button>
        <p class="hint">Готовые файлы сохраняются с суффиксом <b>_compressed</b>. Если обработчик не получает прогресс больше двух минут, задача будет остановлена с ошибкой.</p>
      </aside>
    </div>
  </main>

  <script>
    const state = { input: "", output: "", running: false };
    const $ = (id) => document.getElementById(id);

    async function api(path, options = {}) {
      const response = await fetch(path, {
        headers: { "Content-Type": "application/json" },
        ...options
      });
      const data = await response.json();
      if (!response.ok || data.error) throw new Error(data.error || "Ошибка запроса");
      return data;
    }

    function setPath(kind, value) {
      state[kind] = value || "";
      $(kind === "input" ? "inputPath" : "outputPath").textContent = value || "Не выбрана";
      refreshFiles();
    }

    async function pick(kind) {
      try {
        const data = await api(`/api/pick-folder?kind=${kind}`);
        if (data.path) setPath(kind, data.path);
      } catch (error) {
        appendLog(error.message);
      }
    }

    async function refreshFiles() {
      if (!state.input) return;
      try {
        const data = await api("/api/scan", {
          method: "POST",
          body: JSON.stringify({ input: state.input })
        });
        $("fileCount").textContent = data.count;
      } catch (error) {
        $("fileCount").textContent = "0";
      }
    }

    async function start() {
      try {
        const payload = {
          input: state.input,
          output: state.output,
          resolution: $("resolution").value,
          compression: $("compression").value
        };
        await api("/api/start", { method: "POST", body: JSON.stringify(payload) });
        appendLog("Задача запущена.");
        poll();
      } catch (error) {
        appendLog(error.message);
      }
    }

    async function stop() {
      try {
        await api("/api/stop", { method: "POST", body: "{}" });
      } catch (error) {
        appendLog(error.message);
      }
    }

    function appendLog(text) {
      const log = $("log");
      const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 8;
      log.textContent = `${log.textContent}\n${text}`.trim();
      if (atBottom) log.scrollTop = log.scrollHeight;
    }

    function render(data) {
      state.running = data.running;
      $("statusText").textContent = data.status;
      $("statusDot").className = `dot ${data.state}`;
      $("doneCount").textContent = data.done;
      $("failedCount").textContent = data.failed;
      $("fileCount").textContent = data.total;
      $("currentFile").textContent = data.current_file || "Текущий файл";

      const overall = Math.max(0, Math.min(100, data.overall_percent || 0));
      const current = Math.max(0, Math.min(100, data.current_percent || 0));
      $("overallBar").style.width = `${overall}%`;
      $("currentBar").style.width = `${current}%`;
      $("overallPercent").textContent = `${Math.round(overall)}%`;
      $("currentPercent").textContent = `${Math.round(current)}%`;
      $("start").disabled = data.running;
      $("stop").disabled = !data.running;
      $("pickInput").disabled = data.running;
      $("pickOutput").disabled = data.running;
      $("resolution").disabled = data.running;
      $("compression").disabled = data.running;

      $("log").textContent = data.log.join("\n") || "Выберите папки и нажмите «Начать сжатие».";
      $("log").scrollTop = $("log").scrollHeight;
    }

    async function poll() {
      try {
        const data = await api("/api/status");
        render(data);
        setTimeout(poll, data.running ? 700 : 1400);
      } catch (error) {
        appendLog(error.message);
        setTimeout(poll, 2000);
      }
    }

    $("pickInput").addEventListener("click", () => pick("input"));
    $("pickOutput").addEventListener("click", () => pick("output"));
    $("start").addEventListener("click", start);
    $("stop").addEventListener("click", stop);
    poll();
  </script>
</body>
</html>
"""


class JobState:
    def __init__(self):
        self.lock = threading.Lock()
        self.running = False
        self.state = "idle"
        self.status = "Готово"
        self.total = 0
        self.done = 0
        self.failed = 0
        self.current_file = ""
        self.current_percent = 0.0
        self.overall_percent = 0.0
        self.log = []
        self.stop_requested = False
        self.process = None
        self.thread = None

    def reset(self, total):
        with self.lock:
            self.running = True
            self.state = "running"
            self.status = "Работает"
            self.total = total
            self.done = 0
            self.failed = 0
            self.current_file = ""
            self.current_percent = 0.0
            self.overall_percent = 0.0
            self.log = []
            self.stop_requested = False
            self.process = None

    def append(self, text):
        timestamp = time.strftime("%H:%M:%S")
        with self.lock:
            self.log.append(f"[{timestamp}] {text}")
            self.log = self.log[-240:]

    def snapshot(self):
        with self.lock:
            return {
                "running": self.running,
                "state": self.state,
                "status": self.status,
                "total": self.total,
                "done": self.done,
                "failed": self.failed,
                "current_file": self.current_file,
                "current_percent": self.current_percent,
                "overall_percent": self.overall_percent,
                "log": list(self.log),
            }


JOB = JobState()


def json_response(handler, payload, status=200):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def read_json(handler):
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length == 0:
        return {}
    return json.loads(handler.rfile.read(length).decode("utf-8"))


def choose_folder():
    script = 'POSIX path of (choose folder with prompt "Выберите папку")'
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("Выбор папки отменен.")
    return result.stdout.strip()


def scan_videos(folder):
    root = Path(folder).expanduser()
    if not root.exists() or not root.is_dir():
        raise RuntimeError("Папка с видео не найдена.")
    files = [
        path for path in sorted(root.iterdir(), key=lambda p: p.name.lower())
        if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
    ]
    return files


def probe_duration(path):
    result = subprocess.run(
        [
            FFPROBE,
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Не удалось прочитать длительность файла.")
    try:
        return max(0.1, float(result.stdout.strip()))
    except ValueError:
        return 0.1


def safe_output_path(input_path, output_dir):
    output = Path(output_dir) / f"{input_path.stem}_compressed.mp4"
    if not output.exists():
        return output
    for index in range(2, 1000):
        candidate = Path(output_dir) / f"{input_path.stem}_compressed_{index}.mp4"
        if not candidate.exists():
            return candidate
    raise RuntimeError("Не удалось подобрать имя выходного файла.")


def scale_filter(resolution_key):
    height = RESOLUTIONS[resolution_key]
    if height is None:
        return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    return f"scale=-2:'min({height},ih)'"


def terminate_process(process):
    if process.poll() is not None:
        return
    try:
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=8)
    except Exception:
        try:
            process.kill()
        except Exception:
            pass


def compress_one(input_path, output_path, resolution_key, compression_key, file_index, total):
    duration = probe_duration(input_path)
    settings = COMPRESSION[compression_key]
    command = [
        FFMPEG,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-dn",
        "-sn",
        "-vf",
        scale_filter(resolution_key),
        "-c:v",
        "libx264",
        "-preset",
        settings["preset"],
        "-crf",
        settings["crf"],
        "-pix_fmt",
        "yuv420p",
        "-tag:v",
        "avc1",
        "-c:a",
        "aac",
        "-b:a",
        settings["audio"],
        "-movflags",
        "+faststart",
        "-progress",
        "pipe:1",
        "-nostats",
        str(output_path),
    ]

    JOB.append(f"Сжимаю: {input_path.name}")
    last_progress = time.time()
    current_percent = 0.0
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    with JOB.lock:
        JOB.process = process
        JOB.current_file = input_path.name
        JOB.current_percent = 0.0

    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    while True:
        if JOB.stop_requested:
            terminate_process(process)
            raise RuntimeError("Остановлено пользователем.")

        events = selector.select(timeout=0.5)
        if events:
            line = process.stdout.readline()
            if not line:
                if process.poll() is not None:
                    break
                continue
            line = line.strip()
            if line.startswith("out_time_ms="):
                try:
                    out_seconds = int(line.split("=", 1)[1]) / 1_000_000
                    current_percent = min(99.0, (out_seconds / duration) * 100)
                    last_progress = time.time()
                    with JOB.lock:
                        JOB.current_percent = current_percent
                        JOB.overall_percent = ((file_index + (current_percent / 100)) / total) * 100
                except ValueError:
                    pass
            elif line == "progress=end":
                current_percent = 100.0
                with JOB.lock:
                    JOB.current_percent = 100.0
                    JOB.overall_percent = ((file_index + 1) / total) * 100
            elif "Error" in line or "Invalid" in line:
                JOB.append(line[:300])
        elif process.poll() is not None:
            break
        elif time.time() - last_progress > STALL_TIMEOUT_SECONDS:
            terminate_process(process)
            raise RuntimeError("ffmpeg не отдавал прогресс больше двух минут. Процесс остановлен.")

    code = process.wait()
    selector.close()
    with JOB.lock:
        JOB.process = None
    if code != 0:
        raise RuntimeError(f"ffmpeg завершился с кодом {code}.")


def run_job(input_dir, output_dir, resolution_key, compression_key):
    try:
        files = scan_videos(input_dir)
        Path(output_dir).mkdir(parents=True, exist_ok=True)
        if not files:
            raise RuntimeError("В выбранной папке нет поддерживаемых видеофайлов.")
        JOB.reset(len(files))
        JOB.append(f"Найдено файлов: {len(files)}")

        for index, input_path in enumerate(files):
            if JOB.stop_requested:
                raise RuntimeError("Остановлено пользователем.")
            output_path = safe_output_path(input_path, output_dir)
            try:
                compress_one(input_path, output_path, resolution_key, compression_key, index, len(files))
                with JOB.lock:
                    JOB.done += 1
                    JOB.current_percent = 100.0
                    JOB.overall_percent = (JOB.done + JOB.failed) / JOB.total * 100
                JOB.append(f"Готово: {output_path.name}")
            except Exception as error:
                with JOB.lock:
                    JOB.failed += 1
                    JOB.state = "error"
                    JOB.status = "Ошибка"
                JOB.append(f"Ошибка: {input_path.name}: {error}")
                raise

        with JOB.lock:
            JOB.running = False
            JOB.state = "done"
            JOB.status = "Готово"
            JOB.current_file = ""
            JOB.current_percent = 0.0
            JOB.overall_percent = 100.0
        JOB.append("Пакетная обработка завершена.")
    except Exception as error:
        with JOB.lock:
            JOB.running = False
            if JOB.state != "error":
                JOB.state = "error"
                JOB.status = "Ошибка"
            JOB.process = None
        JOB.append(str(error))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            body = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif parsed.path == "/api/status":
            json_response(self, JOB.snapshot())
        elif parsed.path == "/api/pick-folder":
            try:
                json_response(self, {"path": choose_folder()})
            except Exception as error:
                json_response(self, {"error": str(error)}, 400)
        else:
            json_response(self, {"error": "Не найдено."}, 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        try:
            if parsed.path == "/api/scan":
                payload = read_json(self)
                files = scan_videos(payload.get("input", ""))
                json_response(self, {"count": len(files)})
            elif parsed.path == "/api/start":
                payload = read_json(self)
                with JOB.lock:
                    if JOB.running:
                        raise RuntimeError("Обработка уже идет.")

                input_dir = payload.get("input", "")
                output_dir = payload.get("output", "")
                resolution = payload.get("resolution", "1080")
                compression = payload.get("compression", "balanced")

                if resolution not in RESOLUTIONS:
                    raise RuntimeError("Некорректное разрешение.")
                if compression not in COMPRESSION:
                    raise RuntimeError("Некорректная степень сжатия.")
                if not Path(input_dir).is_dir():
                    raise RuntimeError("Выберите папку с видео.")
                if not output_dir:
                    raise RuntimeError("Выберите папку для готовых файлов.")
                if not Path(FFMPEG).exists() or not Path(FFPROBE).exists():
                    raise RuntimeError("ffmpeg или ffprobe не найдены.")

                files = scan_videos(input_dir)
                if not files:
                    raise RuntimeError("В выбранной папке нет поддерживаемых видеофайлов.")

                thread = threading.Thread(
                    target=run_job,
                    args=(input_dir, output_dir, resolution, compression),
                    daemon=True,
                )
                with JOB.lock:
                    JOB.thread = thread
                thread.start()
                json_response(self, {"ok": True})
            elif parsed.path == "/api/stop":
                with JOB.lock:
                    JOB.stop_requested = True
                    process = JOB.process
                if process:
                    terminate_process(process)
                json_response(self, {"ok": True})
            else:
                json_response(self, {"error": "Не найдено."}, 404)
        except Exception as error:
            json_response(self, {"error": str(error)}, 400)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    url = f"http://{HOST}:{PORT}/"
    print(f"Жми запущен: {url}")
    threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        with JOB.lock:
            process = JOB.process
        if process:
            terminate_process(process)
        server.server_close()


if __name__ == "__main__":
    main()
