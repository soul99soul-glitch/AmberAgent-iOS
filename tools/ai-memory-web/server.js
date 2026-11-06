'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const execFileAsync = promisify(execFile);

const PORT = Number(process.env.PORT || 47890);
const HOST = '127.0.0.1';
const ROOT = path.join(__dirname, 'public');
const CLI = process.env.AI_MEMORY_CLI || 'ai-memory';
const allowedHosts = new Set((process.env.PANEL_ALLOWED_HOSTS || `127.0.0.1:${PORT},localhost:${PORT}`).split(',').map(s => s.trim().toLowerCase()));
const methods = new Set(['memory_briefing', 'memory_recent', 'memory_query', 'memory_read_page', 'memory_read_session_observations', 'memory_handoff_list', 'memory_handoff_begin', 'memory_handoff_cancel', 'memory_restore_page']);
let child, pending = new Map(), nextId = 1, buffer = '', ready;

function bridge() {
  if (ready) return ready;
  ready = new Promise((resolve, reject) => {
    child = spawn(CLI, ['mcp-bridge', '--no-session-id'], { stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
    let settled = false;
    const fail = err => {
      for (const p of pending.values()) { clearTimeout(p.timer); p.reject(err); }
      pending.clear(); child = null; ready = null;
      if (!settled) { settled = true; reject(err); }
    };
    child.on('error', fail);
    child.on('exit', () => fail(new Error('ai-memory 连接已中断，请检查 CLI 和服务连接。')));
    // The bridge may write diagnostics containing server details; never relay them to a browser or log them.
    child.stderr.resume();
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        let msg; try { msg = JSON.parse(line); } catch { continue; }
        const p = pending.get(msg.id); if (!p) continue;
        pending.delete(msg.id); clearTimeout(p.timer);
        if (msg.error) p.reject(new Error(msg.error.message || '上游请求失败')); else p.resolve(msg.result);
      }
    });
    rpc('initialize', {protocolVersion: '2025-03-26', capabilities: {}, clientInfo: {name: 'ai-memory-web', version: '1.0.0'}})
      .then(() => {
        child.stdin.write(JSON.stringify({jsonrpc:'2.0', method:'notifications/initialized'}) + '\n');
        settled = true; resolve();
      }).catch(fail);
  });
  return ready;
}
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    if (!child || !child.stdin.writable) return reject(new Error('ai-memory 连接不可用'));
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('ai-memory 请求超时')); }, 25000);
    pending.set(id, {resolve, reject, timer});
    child.stdin.write(JSON.stringify({jsonrpc:'2.0', id, method, params}) + '\n');
  });
}
async function call(name, args) {
  await bridge();
  const result = await rpc('tools/call', {name, arguments: args});
  const content = (result.content || []).filter(item => item.type === 'text').map(item => item.text).join('\n');
  if (result.isError) throw new Error(content || '上游请求失败');
  try { return JSON.parse(content); } catch { return {message: content}; }
}
function scopeArgs(scope, operation) {
  if (!scope || typeof scope !== 'object') throw new Error('请选择作用域');
  if (scope.type === 'profile') {
    if (['read','write','delete'].includes(operation)) return {scope:'profile'};
    throw new Error('Profile 列表需要管理员权限，请检查配置。');
  }
  if (scope.type === 'global') {
    if (['read','write','delete'].includes(operation)) return {scope:'global'};
    return {workspace:'default', project:'_global'};
  }
  if (scope.type !== 'project' || !/^[\w.-]{1,100}$/.test(scope.workspace || '') || !/^[\w.-]{1,100}$/.test(scope.project || '')) throw new Error('无效的项目作用域');
  return {workspace:scope.workspace, project:scope.project};
}
function checkedPath(value) {
  if (typeof value !== 'string' || value.length > 500 || !value.endsWith('.md') || value.startsWith('/') || value.split('/').some(s => !s || s === '.' || s === '..')) throw new Error('请输入有效的相对 Markdown 路径');
  return value;
}
const str = (v, max = 64000) => typeof v === 'string' ? v.slice(0, max) : '';
async function readPage(scope, pagePath) {
  return call('memory_read_page', {...scopeArgs(scope, 'read'), path: checkedPath(pagePath), max_chars:64000});
}
async function profileList() {
  // Profile inspection is root-only on multi-user servers, and the CLI applies the same upstream access check.
  try {
    const {stdout} = await execFileAsync(CLI, ['profile', 'list'], {timeout:25000, maxBuffer:1024*1024});
    return {text:stdout.trim()};
  } catch (e) {
    if (/403|root.only|permission|forbidden/i.test(String(e.stderr || e.message))) throw new Error('Profile 列表需要 ai-memory 管理员权限；当前凭据无权访问。');
    throw new Error('无法读取 Profile 列表，请检查 ai-memory 连接和权限。');
  }
}
async function action(input) {
  const {method, scope, args = {}} = input || {};
  if (method === 'profile_list') return profileList();
  if (method === 'save_page') {
    const pagePath = checkedPath(args.path), body = str(args.body);
    if (!/^#\s+\S/m.test(body.split('\n')[0] || '')) throw new Error('正文第一行必须是 # 标题。');
    const common = {...scopeArgs(scope, 'write'), path:pagePath, body};
    if (args.create_only === true) return call('memory_write_page', {...common, create_only:true, pinned:!!args.pinned});
    if (typeof args.expected_page_id !== 'string' || !args.expected_page_id) throw new Error('缺少页面版本，无法安全保存。');
    const previous = await readPage(scope, pagePath);
    if (previous.truncated) throw new Error('页面超过 64000 字符，无法安全编辑。');
    if (previous.page_id !== args.expected_page_id) throw new Error('页面已被其他设备修改。请重新加载后再编辑。');
    const fm = previous.frontmatter || {};
    for (const key of ['kind','tier','tags','entities','abstract','relations','expires_at','applies_to','enforced_by']) if (fm[key] != null) common[key] = fm[key];
    common.pinned = args.pinned === undefined ? !!fm.pinned : !!args.pinned;
    common.expected_page_id = args.expected_page_id;
    return call('memory_write_page', common);
  }
  if (method === 'delete_page') {
    if (!args.expected_page_id) throw new Error('缺少页面版本，无法安全删除。');
    return call('memory_delete_page', {...scopeArgs(scope, 'delete'), path:checkedPath(args.path), expected_page_id:str(args.expected_page_id,200)});
  }
  if (!methods.has(method)) throw new Error('不支持的操作');
  let clean = scopeArgs(scope, method === 'memory_read_page' ? 'read' : 'other');
  switch (method) {
    case 'memory_briefing': clean.recent_pages_limit=100; break;
    case 'memory_recent': clean.limit=100; break;
    case 'memory_query':
      clean.query=str(args.query,500).trim(); if (!clean.query) throw new Error('请输入搜索关键词。');
      clean.limit=100; clean.include_expired=!!args.include_expired; clean.include_superseded=!!args.include_superseded;
      if (args.kind) clean.kind=str(args.kind,64); if (args.path_prefix) clean.path_prefix=str(args.path_prefix,500); break;
    case 'memory_read_page': return readPage(scope, args.path);
    case 'memory_read_session_observations':
      clean.session_id=str(args.session_id,200); clean.limit=Math.min(Math.max(Number(args.limit) || 20,1),50);
      clean.offset=Math.max(Number(args.offset) || 0,0); clean.order=args.order === 'desc' ? 'desc' : 'asc'; clean.body_max_chars=2000; break;
    case 'memory_handoff_list': clean.limit=100; break;
    case 'memory_handoff_begin':
      clean.summary=str(args.summary,4000).trim(); if (!clean.summary) throw new Error('请输入交接摘要。');
      clean.shared=true; clean.cwd=str(args.cwd,1000) || undefined;
      clean.next_steps=Array.isArray(args.next_steps) ? args.next_steps.map(x=>str(x,1000)).filter(Boolean).slice(0,20) : [];
      clean.open_questions=Array.isArray(args.open_questions) ? args.open_questions.map(x=>str(x,1000)).filter(Boolean).slice(0,20) : []; break;
    case 'memory_handoff_cancel': clean.handoff_id=str(args.handoff_id,200); if (!clean.handoff_id) throw new Error('缺少交接 ID'); break;
    case 'memory_restore_page':
      if (scope.type !== 'project') throw new Error('Checkpoint 仅支持项目页面。');
      clean.path=checkedPath(args.path); clean.limit=30;
      if (args.rev) {
        if (!/^[a-fA-F0-9]{7,64}$/.test(args.rev)) throw new Error('无效的 checkpoint 版本');
        if (!args.expected_page_id) throw new Error('缺少当前页面版本，无法检查回滚冲突。');
        const current = await readPage(scope, args.path);
        if (current.page_id !== args.expected_page_id) throw new Error('页面已被其他设备修改，请重新加载后回滚。');
        clean.rev=args.rev;
      }
      break;
  }
  return call(method, clean);
}
function respond(res, status, data) {
  res.writeHead(status, {'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'}); res.end(JSON.stringify(data));
}
const server = http.createServer(async (req,res) => {
  const host = (req.headers.host || '').toLowerCase();
  if (!allowedHosts.has(host)) return respond(res,403,{error:'不允许的 Host。'});
  if (req.method === 'POST' && req.url === '/api/call') {
    const origin = req.headers.origin;
    if (origin && origin !== `http://${host}` && origin !== `https://${host}`) return respond(res,403,{error:'不允许跨站请求。'});
    if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) return respond(res,415,{error:'需要 JSON 请求。'});
    let data='';
    try {
      for await (const part of req) { data += part; if (data.length > 512000) throw new Error('请求过大。'); }
      const result = await action(JSON.parse(data)); respond(res,200,{result});
    } catch (error) { respond(res,400,{error:error.message || '请求失败'}); }
    return;
  }
  if (req.method !== 'GET') return respond(res,405,{error:'不支持的请求。'});
  const files = {'/':'index.html','/index.html':'index.html','/app.js':'app.js','/styles.css':'styles.css'};
  const file = files[(req.url || '').split('?')[0]];
  if (!file) return respond(res,404,{error:'未找到'});
  try {
    const body = await fs.promises.readFile(path.join(ROOT,file));
    res.writeHead(200, {'content-type':file.endsWith('.html')?'text/html; charset=utf-8':file.endsWith('.css')?'text/css; charset=utf-8':'text/javascript; charset=utf-8', 'cache-control':'no-store', 'x-content-type-options':'nosniff', 'content-security-policy':"default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",'referrer-policy':'no-referrer'});
    res.end(body);
  } catch { respond(res,500,{error:'无法加载页面。'}); }
});
server.listen(PORT, HOST, () => console.log(`ai-memory 面板已启动：http://${HOST}:${PORT}`));
process.on('SIGTERM', () => { if (child) child.kill(); server.close(() => process.exit(0)); });
