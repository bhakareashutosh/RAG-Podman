"""Container health check: exits 0 if the ADK API server answers, 1 otherwise."""
import sys
import urllib.request

try:
    urllib.request.urlopen("http://localhost:8080/list-apps", timeout=5)
except Exception:
    sys.exit(1)
