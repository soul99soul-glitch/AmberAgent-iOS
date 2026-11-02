import os, sys, json, stat, hashlib, mimetypes, base64
mimetypes.knownfiles=[]
mimetypes.init(files=[])
r=json.load(sys.stdin)
root=os.open('.', os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
def parts(path):
    if not isinstance(path,str) or path.startswith('/') or '\x00' in path: raise ValueError('relative task path required')
    p=[x for x in path.split('/') if x not in ('','.')] 
    if '..' in p: raise ValueError('path escapes task')
    return p
def parent(path, create=False):
    p=parts(path)
    if not p: raise ValueError('file path required')
    fd=os.dup(root)
    try:
        for x in p[:-1]:
            if create:
                try: os.mkdir(x, dir_fd=fd)
                except FileExistsError: pass
            nxt=os.open(x, os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW, dir_fd=fd);os.close(fd);fd=nxt
        return fd,p[-1]
    except BaseException: os.close(fd);raise
def read(path):
    fd,name=parent(path)
    try:
        f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
        with os.fdopen(f,'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): raise ValueError('not a regular file')
            data=stream.read(32*1024*1024+1)
            if len(data)>32*1024*1024: raise ValueError('file exceeds 32MiB')
            return data
    finally: os.close(fd)
def meta(path,data=None):
    if data is None: data=read(path)
    return dict(path=path,sizeBytes=len(data),sha256=hashlib.sha256(data).hexdigest(),contentType=mimetypes.guess_type(path)[0] or 'application/octet-stream')
def write(path,data):
    if len(data)>32*1024*1024: raise ValueError('file exceeds 32MiB')
    fd,name=parent(path,True)
    try:
        f=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600,dir_fd=fd)
        with os.fdopen(f,'wb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): raise ValueError('not a regular file')
            stream.truncate(0);stream.write(data)
    finally: os.close(fd)
    return meta(path,data)
def files():
    out=[]
    def walk(fd,prefix,depth):
        if depth>8:return
        for name in sorted(os.listdir(fd)):
            if name.startswith('.') or len(out)>=200:continue
            info=os.stat(name,dir_fd=fd,follow_symlinks=False);path=prefix+name
            if stat.S_ISREG(info.st_mode):out.append(path)
            elif stat.S_ISDIR(info.st_mode):
                child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                try:walk(child,path+'/',depth+1)
                finally:os.close(child)
    walk(root,'',0);return out
try:
    op=r['op'];p=r.get('path','')
    if op=='list': result=files()
    elif op=='read': result=read(p).decode('utf-8')[:min(100000,max(1,r.get('maxChars',40000)))]
    elif op=='bytes':result=base64.b64encode(read(p)).decode()
    elif op=='write':result=write(p,r['content'].encode('utf-8'))
    elif op=='write_bytes':result=write(p,base64.b64decode(r['data'],validate=True))
    elif op=='artifact':result=meta(p)
    elif op=='edit':
        data=read(p).decode('utf-8');old=r['old']
        if not old or data.count(old)!=1: raise ValueError('old_text must match exactly once')
        result=write(p,data.replace(old,r['replacement'],1).encode('utf-8'))
    elif op=='search':
        q=r['query'].lower()
        if not q:raise ValueError('query required')
        result=[]
        for name in files():
            try: text=read(name).decode('utf-8')[:100000]
            except (UnicodeError,ValueError):continue
            for n,line in enumerate(text.splitlines(),1):
                if q in line.lower():result.append(dict(path=name,line=n,text=line[:500]));break
            if len(result)>=40:break
    else:raise ValueError('unknown file operation')
    print(json.dumps(dict(ok=True,result=result),ensure_ascii=False))
except Exception as e:
    print(json.dumps(dict(ok=False,error=str(e)),ensure_ascii=False));sys.exit(1)
finally:os.close(root)
