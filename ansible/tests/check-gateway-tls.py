#!/usr/bin/env python3
"""Run with .venv/bin/python ansible/tests/check-gateway-tls.py; no Docker needed."""
import http.server
import ssl
import subprocess
import tempfile
import threading
from pathlib import Path

import yaml
from jinja2 import Template


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(404 if self.path == '/__gateway_ready' else 200)
        self.end_headers()

    def log_message(self, *_args):
        pass


def require_sni(_socket, name, _context):
    if name != 'gateway.test':
        return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME


root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    cert, key = Path(directory) / 'cert.pem', Path(directory) / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1',
                    '-subj', '/CN=gateway.test'], check=True, capture_output=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    context.set_servername_callback(require_sni)
    with http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
        port = server.server_port
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for filename in ['deploy-gateway.yml', 'verify-deployment.yml']:
                plays = yaml.safe_load((root / 'ansible/playbooks' / filename).read_text())
                for task in plays[0]['tasks']:
                    command = task.get('ansible.builtin.command', {}).get('argv')
                    if not command or command[0] != 'curl':
                        continue
                    for item in task.get('loop', [dict(path='/__gateway_ready', status='404')]):
                        values = dict(api_server_names='gateway.test', item=dict(item, host='gateway.test'))
                        argv = [Template(arg).render(**values).replace(':443:', f':{port}:')
                                .replace('https://gateway.test/', f'https://gateway.test:{port}/')
                                for arg in command]
                        result = subprocess.run(argv, capture_output=True, text=True, check=True)
                        assert result.stdout == item['status'], (filename, result.stdout)
        finally:
            server.shutdown()
            thread.join()
print('Gateway and verification probes pass with required SNI (200 and 404).')
