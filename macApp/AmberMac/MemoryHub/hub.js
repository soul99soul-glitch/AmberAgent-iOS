'use strict';
const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const state = { view:'pages', filter:'all', detail:null, scope:{workspace:'default',project:'amber',mode:'project'}, requestId:0 };
const embedded = Boolean(window.amber && window.amber.memoryHub);
const descriptions = {
  pages:['研发记忆','查看、编辑并整理跨设备共享的知识。','CROSS-DEVICE MEMORY','新建页面'],
  handoffs:['交接队列','查看尚未领取的交接，或创建共享交接。','HANDOFFS','新建交接'],
  timeline:['会话时间线','按最近活动查看不同设备和客户端的会话。','TIMELINE',''],
  local:['本机对话记忆','查看 Amber 保存的记忆与可追溯的来源消息。','ON THIS MAC','新建记忆']
};
function scopeArgs() { return {workspace:state.scope.workspace, project:state.scope.project}; }
function pageScope() { return state.scope.mode === 'profile' ? {scope:'profile'} : scopeArgs(); }
function ensureScope() {
  if (!state.scope.workspace || !state.scope.project) throw new Error('请填写工作区和项目。');
}
async function call(method,args={}) {
  if (embedded) return window.amber.memoryHub.call(method,args);
  const token = sessionStorage.getItem('memoryHubToken');
  if (!token) throw new Error('请通过本机面板启动命令提供的链接打开。');
  const response = await fetch('/api/memory',{method:'POST',headers:{'Content-Type':'application/json','X-Memory-Hub-Token':token},body:JSON.stringify({method,args})});
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || '记忆服务请求失败。');
  return data;
}
function setStatus(message='',isError=false) { $('status').textContent=message; $('status').className=isError?'error':''; }
function setView(view) {
  state.view=view; state.detail=null;
  document.querySelectorAll('.nav').forEach(b=>b.classList.toggle('active',b.dataset.view===view));
  const [title,subtitle,kicker,button] = descriptions[view];
  $('title').textContent=title; $('subtitle').textContent=subtitle; $('eyebrow').textContent=kicker;
  $('create').textContent=button; $('create').hidden=!button || (view==='local' && !embedded);
  $('scope-bar').hidden=view==='local';
  $('scope').disabled=view!=='pages';
  render();
}
function bind(id,action) { const el=$(id); if(el) el.addEventListener('click',action); }
function empty(title,description) { return `<div class="empty"><strong>${esc(title)}</strong>${esc(description)}</div>`; }
function fmt(date) {
  if (!date) return '';
  const d = new Date(typeof date==='number' && date<1e11 ? date*1000 : date);
  return Number.isNaN(d.valueOf()) ? String(date) : d.toLocaleString('zh-CN',{dateStyle:'medium',timeStyle:'short'});
}
async function render() {
  const requestId=++state.requestId;
  setStatus('正在读取…'); $('content').innerHTML='';
  try {
    if (state.view!=='local') ensureScope();
    if (state.view==='pages') await renderPages(requestId);
    else if (state.view==='handoffs') await renderHandoffs(requestId);
    else if (state.view==='timeline') await renderTimeline(requestId);
    else await renderLocal(requestId);
    if(requestId===state.requestId) setStatus();
  } catch(e) { if(requestId===state.requestId) setStatus(e.message || '读取失败。',true); }
}
async function renderPages(requestId) {
  const q=state.query || '';
  let result;
  if (q || state.scope.mode==='profile') {
    const args={...scopeArgs(),query:q,limit:100};
    if(state.scope.mode==='profile') args.path_prefix='profile/';
    result=await call('search',args);
  } else result=await call('recent',{...scopeArgs(),limit:100});
  if(requestId!==state.requestId) return;
  const all=(result.hits || []).filter(x => x && x.path);
  const hits=all.filter(x=>state.filter==='all'||x.path.startsWith(state.filter+'/'));
  const groups=[['all','全部'],['_rules','规则'],['decisions','决策'],['gotchas','注意'],['notes','笔记'],['sessions','会话']];
  $('content').innerHTML=`<div class="toolbar"><label>全文搜索<input id="search" value="${esc(q)}" placeholder="搜索页面内容"></label><button type="button" id="search-go">搜索</button></div>
    <p class="small-note">${q?'全文搜索':'最近更新的 100 条；使用搜索查找更早页面。'}</p><div class="filters">${groups.map(([id,label])=>`<button type="button" class="filter ${state.filter===id?'active':''}" data-filter="${esc(id)}">${esc(label)}</button>`).join('')}</div>
    <div class="list">${hits.map((item,i)=>`<article class="row"><div><h3>${esc(item.title||item.path)}</h3><p>${esc(item.snippet||'')}</p><div class="meta">${esc(item.path)}</div></div><div class="actions"><button type="button" data-open="${i}">查看</button></div></article>`).join('')}</div>
    ${hits.length?'':empty('没有找到页面', state.scope.mode==='profile'?'当前服务可能未向此账号提供 Profile 列表。':'调整搜索条件，或新建一个页面。')}`;
  const search=()=>{state.query=$('search').value.trim();render();};
  bind('search-go',search); $('search').addEventListener('keydown',e=>{if(e.key==='Enter')search();});
  document.querySelectorAll('[data-filter]').forEach(b=>b.addEventListener('click',()=>{state.filter=b.dataset.filter;render();}));
  document.querySelectorAll('[data-open]').forEach(b=>b.addEventListener('click',()=>openPage(hits[Number(b.dataset.open)].path)));
}
async function openPage(path, targetScope=pageScope(), projectScope=scopeArgs()) {
  const requestId=++state.requestId;
  setStatus('正在读取页面…');
  try {
    const page=await call('read',{...targetScope,path,max_chars:1000000});
    if(requestId!==state.requestId) return;
    page._scope=targetScope; page._projectScope=projectScope;
    state.detail=page;
    const pinned=Boolean(page.frontmatter && page.frontmatter.pinned);
    $('content').innerHTML=`<section class="detail"><button type="button" id="back">← 返回列表</button><div class="detail-head"><div><h3>${esc(page.title||path)}</h3><div class="meta">${esc(path)}${pinned?' · 已置顶':''}</div></div><div class="actions"><button id="edit" ${page.truncated?'disabled':''}>编辑</button><button id="pin" ${page.truncated?'disabled':''}>${pinned?'取消置顶':'置顶'}</button><button id="history" ${page._scope.scope==='profile'?'disabled title="Profile 不支持版本恢复"':''}>历史版本</button><button id="delete" class="danger">删除</button></div></div>${page.truncated?'<p class="error">页面未完整读取，已禁用编辑，避免覆盖原文。</p>':''}<pre>${esc(page.body||'')}</pre><div id="history-list"></div></section>`;
    bind('back',render); bind('edit',()=>editPage(page)); bind('pin',()=>savePage({...page,pinOverride:!pinned}));
    bind('delete',()=>deletePage(page)); bind('history',()=>historyPage(page)); setStatus();
  } catch(e) { setStatus(e.message,true); }
}
function preserved(page) {
  const front=page.frontmatter||{}, result={};
  ['kind','tier','tags','entities','abstract','relations','pinned','expires_at','applies_to','enforced_by'].forEach(k=>{if(front[k]!==undefined && front[k]!==null) result[k]=front[k];});
  return result;
}
async function savePage(page) {
  try {
    setStatus('正在保存…');
    const args={...page._scope,...preserved(page),path:page.path,body:page.body};
    if (page.title) args.title=page.title;
    if (page.pinOverride!==undefined) args.pinned=page.pinOverride;
    if (page.page_id) args.expected_page_id=page.page_id; else args.create_only=true;
    await call('write',args); $('editor').close(); await openPage(page.path,page._scope,page._projectScope); setStatus('已保存。');
  } catch(e) { if ($('editor').open) $('editor-error').textContent=e.message; else setStatus(e.message,true); }
}
async function deletePage(page) {
  if (!embedded && !window.confirm(`删除「${page.path}」？`)) return;
  try { await call('delete',{...page._scope,path:page.path,expected_page_id:page.page_id}); state.detail=null; await render(); setStatus('已删除。'); }
  catch(e) { setStatus(e.message,true); }
}
async function historyPage(page) {
  try {
    const result=await call('checkpoints',{...page._projectScope,path:page.path,limit:30});
    const entries=result.checkpoints||[];
    $('history-list').innerHTML=`<h3>历史版本</h3>${entries.length?entries.map((item,i)=>`<article class="row"><div><strong>${esc(item.summary||item.rev)}</strong><div class="meta">${esc(fmt(item.time))} · ${esc(item.rev)}</div></div><div class="actions"><button data-restore="${i}">恢复此版本</button></div></article>`).join(''):empty('没有可用版本','此页面没有可恢复的 Checkpoint。')}`;
    document.querySelectorAll('[data-restore]').forEach(b=>b.addEventListener('click',async()=>{
      const item=entries[Number(b.dataset.restore)]; if(!embedded&&!confirm(`恢复 ${item.rev}？当前版本会被替换。`))return;
      try { await call('restore',{...page._projectScope,path:page.path,rev:item.rev}); await openPage(page.path,page._scope,page._projectScope); setStatus('已恢复历史版本。'); } catch(e) {setStatus(e.message,true);}
    }));
  } catch(e) {setStatus(e.message,true);}
}
function dialog(title,kicker,fields,onSubmit) {
  $('editor-title').textContent=title; $('editor-kicker').textContent=kicker; $('editor-fields').innerHTML=fields; $('editor-error').textContent='';
  $('editor-form').onsubmit=e=>{e.preventDefault();onSubmit();}; $('editor').showModal();
}
function editPage(page=null) {
  const existing=page||{path:'notes/',body:'',frontmatter:{},_scope:pageScope(),_projectScope:scopeArgs()};
  dialog(page?'编辑页面':'新建页面','CROSS-DEVICE MEMORY',`<label>页面路径<input id="field-path" required value="${esc(existing.path)}" ${page?'readonly':''}></label><label>Markdown 正文<textarea id="field-body" required>${esc(existing.body)}</textarea></label><label class="inline"><input type="checkbox" id="field-pin" ${existing.frontmatter?.pinned?'checked':''}>置顶此页面</label><p class="small-note">路径使用 _rules、decisions、gotchas、notes 或 sessions 目录。</p>`,()=>{
    const path=$('field-path').value.trim();
    if (existing._scope.scope!=='profile'&&!/^(_rules|decisions|gotchas|notes|sessions)\/.+\.md$/.test(path)) { $('editor-error').textContent='请输入以上目录内的 .md 路径。'; return; }
    savePage({...existing,path,body:$('field-body').value,pinOverride:$('field-pin').checked});
  });
}
async function renderHandoffs(requestId) {
  const targetScope=scopeArgs();
  const result=await call('handoffs',{...targetScope,limit:100}), entries=result.handoffs||[];
  if(requestId!==state.requestId) return;
  $('content').innerHTML=`<div class="list">${entries.map((x,i)=>`<article class="row"><div><h3>${esc(x.summary||'未命名交接')}</h3><p>${esc((x.next_steps||[]).join('\n'))}</p><div class="meta">${esc(x.from_agent||'未知客户端')} · ${esc(x.cwd||'未知设备')} · ${esc(fmt(x.created_at))}</div></div><div class="actions"><button class="danger" data-cancel="${i}">作废</button></div></article>`).join('')}</div>${entries.length?'':empty('没有待领取的交接','可以为下一次会话创建共享交接。')}`;
  document.querySelectorAll('[data-cancel]').forEach(b=>b.addEventListener('click',async()=>{
    const item=entries[Number(b.dataset.cancel)]; if(!embedded&&!confirm('作废这条交接？'))return;
    try {await call('handoff_cancel',{...targetScope,handoff_id:item.id});await render();setStatus('交接已作废。');}catch(e){setStatus(e.message,true);}
  }));
}
function createHandoff() {
  const targetScope=scopeArgs();
  dialog('新建共享交接','HANDOFF',`<label>交接摘要<textarea id="field-summary" required></textarea></label><label>下一步（每行一项）<textarea id="field-next"></textarea></label>`,async()=>{
    try {await call('handoff_create',{...targetScope,summary:$('field-summary').value,next_steps:$('field-next').value.split('\n').map(x=>x.trim()).filter(Boolean),shared:true});$('editor').close();await render();setStatus('共享交接已创建。');}catch(e){$('editor-error').textContent=e.message;}
  });
}
async function renderTimeline(requestId) {
  const result=await call('briefing',{...scopeArgs(),recent_pages_limit:1}), entries=result.recent_sessions||[];
  if(requestId!==state.requestId) return;
  $('content').innerHTML=`<div class="list">${entries.map(x=>`<article class="row"><div><h3>${esc(x.agent_kind||'会话')} · ${x.ended?'已结束':'未结束'}</h3><div class="meta">${esc(fmt(x.last_activity_at))} · ${esc(x.cwd||'未知路径')}<br>${esc(x.session_id)}</div></div></article>`).join('')}</div>${entries.length?'':empty('暂无会话','捕获到会话活动后将在这里显示。')}`;
}
async function renderLocal(requestId) {
  if(!embedded) { $('content').innerHTML=empty('请在 Amber 中管理本机记忆','浏览器面板仅连接研发记忆；本机对话记忆由 Amber 应用安全管理。');return; }
  const [records,polluted]=await Promise.all([call('local_list',{query:state.localQuery||''}),call('local_polluted')]);
  if(requestId!==state.requestId) return;
  $('content').innerHTML=`<div class="toolbar"><label>搜索本机记忆<input id="local-search" value="${esc(state.localQuery||'')}"></label><button type="button" id="local-go">搜索</button></div><p class="small-note">macOS 尚未接入 Jev 自动提炼；下面显示已保存的本机记忆。</p><div class="list">${records.map((r,i)=>`<article class="row"><div><h3>${esc(r.kind)} · ${esc(r.scope)}${r.pinned?' · 已置顶':''}</h3><p>${esc(r.content)}</p><div class="meta">#${esc(r.id)} · ${esc(fmt(r.updatedAt))}${r.sourceConversationId?' · 来源 '+esc(r.sourceConversationId):''}</div></div><div class="actions"><button data-evidence="${i}">来源</button><button data-edit-local="${i}" ${r.kind==='topic'?'disabled':''}>编辑</button><button class="danger" data-delete-local="${i}">删除</button></div></article>`).join('')}</div>${records.length?'':empty('还没有本机记忆','对话中保存的记忆和手动添加的条目会显示在这里。')}<div id="evidence"></div><section class="detail"><h3>会话污染状态</h3><p class="small-note">外部内容曾进入的会话会被标记。清理后，该会话重新具备记忆提炼资格。</p><div class="list">${polluted.map((p,i)=>`<article class="row"><div><h3>${esc(p.title)}</h3><div class="meta">${esc(p.id)} · ${esc(fmt(p.updatedAt))}</div></div><div class="actions"><button data-clear-polluted="${i}">清理标记</button></div></article>`).join('')}</div>${polluted.length?'':empty('没有已标记的会话','当前存储中没有污染状态。')}</section>`;
  document.querySelectorAll('[data-clear-polluted]').forEach(b=>b.addEventListener('click',async()=>{try{await call('local_clear_polluted',{id:polluted[Number(b.dataset.clearPolluted)].id});await render();setStatus('污染标记已清理。');}catch(e){setStatus(e.message,true);}}));
  const search=()=>{state.localQuery=$('local-search').value.trim();render();};bind('local-go',search);$('local-search').addEventListener('keydown',e=>{if(e.key==='Enter')search();});
  document.querySelectorAll('[data-edit-local]').forEach(b=>b.addEventListener('click',()=>editLocal(records[Number(b.dataset.editLocal)])));
  document.querySelectorAll('[data-delete-local]').forEach(b=>b.addEventListener('click',async()=>{try{await call('local_delete',{id:records[Number(b.dataset.deleteLocal)].id});await render();setStatus('记忆已删除。');}catch(e){setStatus(e.message,true);}}));
  document.querySelectorAll('[data-evidence]').forEach(b=>b.addEventListener('click',async()=>{
    try {const result=await call('local_evidence',{id:records[Number(b.dataset.evidence)].id});$('evidence').innerHTML=`<section class="detail"><h3>来源：${esc(result.conversation||'不可用')}</h3>${(result.messages||[]).map(m=>`<article class="row"><div><div class="meta">${esc(m.role)} · ${esc(m.id)}</div><p>${esc(m.text)}</p></div></article>`).join('')||'<p class="small-note">没有可读取的来源原话。</p>'}</section>`;}catch(e){setStatus(e.message,true);}
  }));
}
function editLocal(record=null) {
  const r=record||{content:'',scope:'core',kind:'note',pinned:false};
  const options=(values,current)=>values.map(([v,l])=>`<option value="${v}" ${v===current?'selected':''}>${l}</option>`).join('');
  dialog(record?'编辑本机记忆':'新建本机记忆','ON THIS MAC',`<label>正文<textarea id="field-content" required>${esc(r.content)}</textarea></label><label>范围<select id="field-scope">${options([['core','核心'],['short_term','短期'],['long_term','长期']],r.scope)}</select></label><label>分类<select id="field-kind">${options([['user','偏好'],['feedback','反馈'],['project','项目'],['reference','资料'],['routine','习惯'],['note','笔记']],r.kind)}</select></label><label class="inline"><input type="checkbox" id="field-pin" ${r.pinned?'checked':''}>置顶</label>`,async()=>{
    try {await call('local_save',{id:r.id||0,content:$('field-content').value,scope:$('field-scope').value,kind:$('field-kind').value,pinned:$('field-pin').checked});$('editor').close();await render();setStatus('记忆已保存。');}catch(e){$('editor-error').textContent=e.message;}
  });
}
document.querySelectorAll('.nav').forEach(b=>b.addEventListener('click',()=>setView(b.dataset.view)));
bind('switch',()=>{state.scope={workspace:$('workspace').value.trim(),project:$('project').value.trim(),mode:$('scope').value};state.query='';state.filter='all';render();}); bind('close-editor',()=>$('editor').close());bind('cancel-editor',()=>$('editor').close());
bind('create',()=>{if(state.view==='pages')editPage();else if(state.view==='handoffs')createHandoff();else if(state.view==='local')editLocal();});
if(!embedded && location.hash.startsWith('#token=')) { sessionStorage.setItem('memoryHubToken',decodeURIComponent(location.hash.slice(7))); history.replaceState(null,'',location.pathname); }
setView('pages');
