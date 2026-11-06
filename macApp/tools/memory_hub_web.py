#!/usr/bin/env python3
"""Run the cloud-memory panel on this computer; the token never reaches ai-memory."""
import argparse
import json
import secrets
import shutil
import subprocess
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'AmberMac' / 'MemoryHub'
TOOLS = {
    'recent': ('memory_recent', {'workspace', 'project', 'limit'}),
    'search': ('memory_query', {'workspace', 'project', 'query', 'path_prefix', 'limit'}),
    'read': ('memory_read_page', {'workspace', 'project', 'scope', 'path', 'max_chars'}),
    'write': ('memory_write_page', {'workspace', 'project', 'scope', 'path', 'body', 'title', 'kind', 'tier', 'tags', 'entities', 'abstract', 'relations', 'pinned', 'expires_at', 'applies_to', 'enforced_by', 'expected_page_id', 'create_only'}),
    'delete': ('memory_delete_page', {'workspace', 'project', 'scope', 'path', 'expected_page_id'}),
    'handoffs': ('memory_handoff_list', {'workspace', 'project', 'limit'}),
    'handoff_create': ('memory_handoff_begin', {'workspace', 'project', 'summary', 'open_questions', 'next_steps', 'shared'}),
    'handoff_cancel': ('memory_handoff_cancel', {'workspace', 'project', 'handoff_id'}),
    'briefing': ('memory_briefing', {'workspace', 'project', 'recent_pages_limit'}),
    'checkpoints': ('memory_restore_page', {'workspace', 'project', 'path', 'limit'}),
    'restore': ('memory_restore_page', {'workspace', 'project', 'path', 'rev'}),
}
ASSETS = {'/': ('index.html', 'text/html; charset=utf-8'), '/styles.css': ('styles.css', 'text/css; charset=utf-8'), '/hub.js': ('hub.js', 'text/javascript; charset=utf-8')}
MUTATIONS = {'write', 'delete', 'handoff_create', 'handoff_cancel', 'restore'}


def call_mcp(executable, method, args):
    if method not in TOOLS or not isinstance(args, dict) or set(args) - TOOLS[method][1]:
        raise ValueError('不支持的记忆操作或参数。')
    messages = [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'Amber Memory Hub', 'version': '1'}}},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': TOOLS[method][0], 'arguments': args}},
    ]
    try:
        process = subprocess.run([executable, 'mcp-bridge', '--no-session-id'], input=''.join(json.dumps(x, ensure_ascii=False) + '\n' for x in messages), capture_output=True, text=True, timeout=35, check=False)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError('请求超时；如果是写入，请先刷新检查结果，避免重复操作。') from exc
    for line in process.stdout.splitlines():
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            continue
        if response.get('id') != 2:
            continue
        if 'error' in response:
            raise RuntimeError(response['error'].get('message', '记忆服务返回错误。'))
        result = response.get('result', {})
        text = '\n'.join(x.get('text', '') for x in result.get('content', []) if x.get('type') == 'text')
        if result.get('isError'):
            raise RuntimeError(text or '记忆服务返回错误。')
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise RuntimeError('记忆服务返回了无法识别的数据。') from exc
    suffix = '；写入结果未知，请先刷新检查。' if method in MUTATIONS else '。'
    raise RuntimeError('无法确认记忆服务请求结果' + suffix)


def make_handler(token, executable):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            pass  # Requests can contain private memory; do not log them.

        def valid_host(self):
            return self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}'

        def reply(self, status, data, content_type):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split('?', 1)[0]
            if not self.valid_host() or path not in ASSETS:
                self.send_error(404)
                return
            name, content_type = ASSETS[path]
            self.reply(200, (ROOT / name).read_bytes(), content_type)

        def do_POST(self):
            origin = f'http://127.0.0.1:{self.server.server_port}'
            if (not self.valid_host() or self.path != '/api/memory' or self.headers.get('Origin') != origin
                    or not secrets.compare_digest(self.headers.get('X-Memory-Hub-Token', ''), token)
                    or self.headers.get_content_type() != 'application/json'):
                self.send_error(403)
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 1_000_000:
                    raise ValueError('请求数据无效或超过 1 MB。')
                payload = json.loads(self.rfile.read(size))
                if not isinstance(payload, dict):
                    raise ValueError('请求必须是 JSON 对象。')
                result = call_mcp(executable, payload.get('method'), payload.get('args'))
                self.reply(200, json.dumps(result, ensure_ascii=False).encode(), 'application/json; charset=utf-8')
            except (ValueError, RuntimeError, OSError) as error:
                self.reply(400, json.dumps({'error': str(error)}, ensure_ascii=False).encode(), 'application/json; charset=utf-8')
    return Handler


def main():
    parser = argparse.ArgumentParser(description='在本机启动 Amber 研发记忆 Web 面板。')
    parser.add_argument('--port', type=int, default=0, help='本机端口；默认由系统选择')
    parser.add_argument('--open', action='store_true', help='在默认浏览器打开')
    args = parser.parse_args()
    executable = shutil.which('ai-memory') or str(Path.home() / '.local/bin/ai-memory')
    if not Path(executable).is_file():
        sys.exit('未找到 ai-memory CLI，请先配置现有服务连接。')
    token = secrets.token_urlsafe(32)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), make_handler(token, executable))
    url = f'http://127.0.0.1:{server.server_port}/#token={token}'
    print('记忆面板仅监听本机。请勿分享此链接：', url, flush=True)
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
