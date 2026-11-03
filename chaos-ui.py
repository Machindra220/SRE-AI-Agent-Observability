from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess, json

HTML = """
<html>
<head>
  <title>SRE Chaos Dashboard</title>
  <style>
    body { font-family: sans-serif; padding: 40px; background: #111; color: #eee; max-width: 700px; }
    h2 { color: #ff6b6b; }
    .btn { padding: 14px 28px; background: #e53935; color: white; border: none;
           border-radius: 6px; font-size: 16px; cursor: pointer; margin-right: 10px; }
    .btn:hover { background: #c62828; }
    .btn-status { background: #1565c0; }
    .btn-status:hover { background: #0d47a1; }
    pre { margin-top: 20px; background: #222; padding: 20px; border-radius: 6px;
          font-size: 13px; overflow-x: auto; white-space: pre-wrap; }
    .tag { display: inline-block; padding: 3px 10px; border-radius: 12px;
           font-size: 12px; margin-bottom: 20px; }
    .live { background: #1b5e20; color: #69f0ae; }
    a { color: #64b5f6; }
  </style>
</head>
<body>
  <h2>SRE Chaos Dashboard</h2>
  <span class="tag live">LIVE</span>
  <p>Kill the app pod to trigger <strong>PodRestartRateHigh</strong> alert and watch the AI agent generate an RCA automatically.</p>

  <button class="btn" onclick="killPod()">Kill App Pod</button>
  <button class="btn btn-status" onclick="getStatus()">Get Pod Status</button>

  <pre id="out">Click a button to begin...</pre>

  <script>
    const AGENT = "http://k8s-sreaiage-sreaiage-4090e2247d-edfb6ed9b022f889.elb.ap-south-1.amazonaws.com";

    function killPod() {
      document.getElementById("out").innerText = "Killing pod...";
      fetch("/kill", {method: "POST"})
        .then(r => r.json())
        .then(d => {
          let msg = "Pod killed: " + d.killed + "\\n\\nGrafana alert fires in ~2 minutes.\\n";
          msg += "Watch for RCA at:\\n" + AGENT + "/agent/history";
          document.getElementById("out").innerText = msg;
        })
        .catch(e => document.getElementById("out").innerText = "Error: " + e);
    }

    function getStatus() {
      document.getElementById("out").innerText = "Fetching pod status...";
      fetch("/status")
        .then(r => r.json())
        .then(d => document.getElementById("out").innerText = JSON.stringify(d, null, 2))
        .catch(e => document.getElementById("out").innerText = "Error: " + e);
    }
  </script>
</body>
</html>
"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/status":
            result = subprocess.run(
                ["kubectl", "get", "pods", "-n", "sre-ai-agent", "-o", "wide"],
                capture_output=True, text=True)
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"pods": result.stdout}).encode())
        else:
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            self.wfile.write(HTML.encode("utf-8"))

    def do_POST(self):
        if self.path == "/kill":
            result = subprocess.run(
                ["kubectl", "get", "pods", "-n", "sre-ai-agent",
                 "-o", "jsonpath={.items[0].metadata.name}"],
                capture_output=True, text=True)
            pod = result.stdout.strip()
            subprocess.run(["kubectl", "delete", "pod", pod, "-n", "sre-ai-agent"])
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"killed": pod, "status": "ok"}).encode())

    def log_message(self, format, *args):
        pass

print("Chaos UI running at http://localhost:8888")
HTTPServer(("0.0.0.0", 8888), Handler).serve_forever()
