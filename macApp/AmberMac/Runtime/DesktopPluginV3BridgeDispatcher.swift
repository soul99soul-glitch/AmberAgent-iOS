import Foundation

// MARK: - Client Bridge Bootstrap & Unified Bridge RPC Dispatcher

enum DesktopPluginWebViewBridgeScript {
    static func backgroundContextBootstrapJS(isV3: Bool) -> String {
        """
        function __amberUnwrap(raw) {
            if (typeof raw === 'string' && raw.indexOf('__AMBER_ERR__:') === 0) {
                const rest = raw.slice('__AMBER_ERR__:'.length);
                const match = /^(E_[A-Z_]+):([\\s\\S]*)$/.exec(rest);
                const err = new Error(match ? match[2] : rest);
                err.code = match ? match[1] : 'E_EXECUTION_FAILED';
                throw err;
            }
            return raw;
        }
        function __amberCall(ns, method, args) {
            const raw = __amberUnwrap(__amberDispatchSync(ns, method, JSON.stringify(args || [])));
            if (!raw || raw === '') return '';
            try { return JSON.parse(raw); } catch (e) { return raw; }
        }
        const __amberToolCallbacks = Object.create(null);
        const __amberCommandCallbacks = Object.create(null);
        const __amberEventListeners = Object.create(null);

        function __amberHasRegisteredTool(name) {
            return typeof __amberToolCallbacks[name] === 'function';
        }
        function __amberInvokeRegisteredTool(name, input) {
            const fn = __amberToolCallbacks[name];
            if (typeof fn !== 'function') throw new Error('未找到动态注册的工具函数：' + name);
            return fn(input);
        }
        function __amberEmitEvent(event, payload) {
            const list = __amberEventListeners[event] || [];
            for (let i = 0; i < list.length; i++) {
                try { list[i](payload); } catch (e) {}
            }
        }

        const amber = Object.freeze({
            settings: Object.freeze({
                get: function(key) { return __amberCall('settings', 'get', [String(key)]); },
                set: function(key, val) { return __amberCall('settings', 'set', [String(key), val]); },
                getAll: function() { return __amberCall('settings', 'getAll', []); }
            }),
            storage: Object.freeze({
                get: function(key) { return __amberCall('storage', 'get', [String(key)]); },
                set: function(key, val) { return __amberCall('storage', 'set', [String(key), typeof val === 'string' ? val : JSON.stringify(val)]); },
                remove: function(key) { return __amberCall('storage', 'remove', [String(key)]); },
                keys: function(key) { return __amberCall('storage', 'keys', []); },
                all: function() { return __amberCall('storage', 'all', []); }
            }),
            http: Object.freeze({
                fetch: function(url, options) {
                    return __amberCall('http', 'fetch', [String(url), options == null ? {} : options]);
                }
            }),
            workspace: Object.freeze({
                read: function(path) { return __amberCall('workspace', 'read', [String(path)]); },
                write: function(path, content) {
                    return __amberCall('workspace', 'write', [String(path), typeof content === 'string' ? content : JSON.stringify(content)]);
                },
                list: function(path) { return __amberCall('workspace', 'list', [path == null ? '' : String(path)]); },
                watch: function(prefix, callback) {
                    const p = prefix == null ? '' : String(prefix);
                    __amberCall('workspace', 'watch', [p]);
                    const listener = typeof callback === 'function' ? function(payload) {
                        const path = payload && typeof payload.path === 'string' ? payload.path : '';
                        if (!p || !path || path === p || path.indexOf(p.replace(/\\/+$/, '') + '/') === 0 || payload.prefix === p) {
                            callback(payload);
                        }
                    } : null;
                    if (listener) {
                        if (!__amberEventListeners['workspace:changed']) __amberEventListeners['workspace:changed'] = [];
                        __amberEventListeners['workspace:changed'].push(listener);
                    }
                    return function() {
                        if (!listener || !__amberEventListeners['workspace:changed']) return;
                        __amberEventListeners['workspace:changed'] = __amberEventListeners['workspace:changed'].filter(function(h) { return h !== listener; });
                    };
                }
            }),
            commands: Object.freeze({
                register: function(cmd) {
                    if (!cmd || !cmd.id) throw new Error('commands.register 需要提供 id');
                    if (typeof cmd.callback === 'function') {
                        __amberCommandCallbacks[cmd.id] = cmd.callback;
                    }
                    return __amberCall('commands', 'register', [cmd]);
                },
                list: function() { return __amberCall('commands', 'list', []); }
            }),
            events: Object.freeze({
                on: function(event, handler) {
                    const ev = String(event);
                    __amberCall('events', 'on', [ev]);
                    if (!__amberEventListeners[ev]) __amberEventListeners[ev] = [];
                    if (typeof handler === 'function') __amberEventListeners[ev].push(handler);
                    return function() { amber.events.off(ev, handler); };
                },
                off: function(event, handler) {
                    const ev = String(event);
                    __amberCall('events', 'off', [ev]);
                    if (!__amberEventListeners[ev]) return true;
                    __amberEventListeners[ev] = __amberEventListeners[ev].filter(function(h) { return h !== handler; });
                    return true;
                },
                emit: function(event, payload) {
                    // The host fans the event out to this runtime and every mounted view, so it is not delivered locally twice.
                    return __amberCall('events', 'emit', [String(event), payload == null ? {} : payload]);
                }
            }),
            ui: Object.freeze({
                notice: function(message, kind) { return __amberCall('ui', 'notice', [String(message), kind || 'info']); },
                confirm: function(options) { return __amberCall('ui', 'confirm', [options == null ? {} : options]); },
                openView: function(viewId, state) { return __amberCall('ui', 'openView', [String(viewId), state == null ? {} : state]); },
                openModal: function(viewId, options) { return __amberCall('ui', 'openModal', [String(viewId), options == null ? {} : options]); },
                closeModal: function() { return __amberCall('ui', 'closeModal', []); }
            }),
            agent: Object.freeze({
                registerTool: function(def) {
                    if (!def || !def.name) throw new Error('agent.registerTool 需要提供 name');
                    const run = typeof def.execute === 'function' ? def.execute : def.handler;
                    if (typeof run !== 'function') throw new Error('agent.registerTool 需要提供 execute(input) 函数');
                    __amberToolCallbacks[def.name] = run;
                    return __amberCall('agent', 'registerTool', [{
                        name: def.name,
                        description: def.description || def.name,
                        effect: def.effect || 'sideEffect',
                        entry: def.entry || def.name,
                        inputSchema: def.inputSchema || def.input_schema || { type: 'object', properties: {}, additionalProperties: false },
                        writesWorkspace: Boolean(def.writesWorkspace),
                        sendsHTTP: Boolean(def.sendsHTTP)
                    }]);
                },
                getConversation: function() { return __amberCall('agent', 'getConversation', []); },
                insertToComposer: function(text) { return __amberCall('agent', 'insertToComposer', [String(text)]); }
            })
        });
        globalThis.window = globalThis.window || globalThis;
        globalThis.window.amber = amber;
        """
    }

    static func webViewBootstrapJS(pluginID: String, viewID: String, isDark: Bool, isCompact: Bool? = nil) -> String {
        let css = DesktopPluginThemeCSS.stylesheet(isDark: isDark)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        return """
        (function() {
            const __pending = Object.create(null);
            const __listeners = Object.create(null);
            let __seq = 0;
            let __compact = \(isCompact.map { $0 ? "true" : "false" } ?? "null");
            let __morphAnimations = [];

            window.__amberSetCompact = function(compact) {
                const changed = __compact !== compact;
                if (!changed) {
                    if (document.documentElement) {
                        document.documentElement.dataset.amberPresentation = compact == null ? 'regular' : compact ? 'compact' : 'expanded';
                    }
                    return;
                }
                const reduce = typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
                const nodes = changed && !reduce && document.documentElement && typeof document.querySelectorAll === 'function'
                    ? Array.from(document.querySelectorAll('[data-amber-morph]')) : [];
                const before = nodes.map(function(node) { return node.getBoundingClientRect(); });
                __morphAnimations.forEach(function(animation) { animation.cancel(); });
                __morphAnimations.length = 0;
                __compact = compact;
                if (document.documentElement) {
                    document.documentElement.dataset.amberPresentation = compact == null ? 'regular' : compact ? 'compact' : 'expanded';
                }
                nodes.forEach(function(node, index) {
                    const from = before[index], to = node.getBoundingClientRect();
                    if (!from.width || !from.height || !to.width || !to.height || typeof node.animate !== 'function') return;
                    const dx = from.left - to.left, dy = from.top - to.top;
                    const sx = from.width / to.width, sy = from.height / to.height;
                    __morphAnimations.push(node.animate([
                        { transformOrigin: 'top left', transform: 'translate(' + dx + 'px,' + dy + 'px) scale(' + sx + ',' + sy + ')' },
                        { transformOrigin: 'top left', transform: 'none' }
                    ], { duration: 240, easing: 'ease-in-out' }));
                });
            };
            window.__amberSetCompact(__compact);

            function applyTheme(theme, cssText) {
                if (document.documentElement) {
                    document.documentElement.dataset.theme = theme;
                }
                let styleEl = document.getElementById('amber-theme-tokens');
                if (!styleEl && document.head) {
                    styleEl = document.createElement('style');
                    styleEl.id = 'amber-theme-tokens';
                    document.head.prepend(styleEl);
                }
                if (styleEl && cssText) {
                    styleEl.textContent = cssText;
                }
            }

            document.addEventListener('DOMContentLoaded', function() {
                applyTheme('\(isDark ? "dark" : "light")', `\(css)`);
                window.__amberSetCompact(__compact);
            });
            applyTheme('\(isDark ? "dark" : "light")', `\(css)`);

            window.__amberBridgeResolve = function(requestId, result) {
                const entry = __pending[requestId];
                if (!entry) return;
                delete __pending[requestId];
                entry.resolve(result);
            };
            window.__amberBridgeReject = function(requestId, errorMessage, code) {
                const entry = __pending[requestId];
                if (!entry) return;
                delete __pending[requestId];
                const err = new Error(String(errorMessage || 'Amber Bridge RPC Error'));
                err.code = code || 'E_EXECUTION_FAILED';
                entry.reject(err);
            };
            window.__amberBridgeEmit = function(event, payload) {
                if (event === 'theme:changed' && payload && payload.theme) {
                    applyTheme(payload.theme, payload.css || '');
                }
                const handlers = __listeners[event] || [];
                for (let i = 0; i < handlers.length; i++) {
                    try { handlers[i](payload); } catch (e) { console.error(e); }
                }
            };

            function rpc(namespace, method, args) {
                return new Promise(function(resolve, reject) {
                    const requestId = 'req_' + (++__seq);
                    __pending[requestId] = { resolve: resolve, reject: reject };
                    const payload = {
                        requestId: requestId,
                        pluginId: '\(pluginID)',
                        viewId: '\(viewID)',
                        namespace: namespace,
                        method: method,
                        args: Array.from(args || [])
                    };
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.amberBridge) {
                        window.webkit.messageHandlers.amberBridge.postMessage(payload);
                    } else {
                        delete __pending[requestId];
                        reject(new Error('amberBridge messageHandler 未挂载'));
                    }
                });
            }

            window.amber = Object.freeze({
                pluginId: '\(pluginID)',
                viewId: '\(viewID)',
                neteaseMusic: Object.freeze({
                    call: function(action, value) { return rpc('neteaseMusic', String(action), value == null ? [] : [value]); }
                }),
                settings: Object.freeze({
                    get: function(key) { return rpc('settings', 'get', [String(key)]); },
                    set: function(key, val) { return rpc('settings', 'set', [String(key), val]); },
                    getAll: function() { return rpc('settings', 'getAll', []); }
                }),
                storage: Object.freeze({
                    get: function(key) { return rpc('storage', 'get', [String(key)]); },
                    set: function(key, val) { return rpc('storage', 'set', [String(key), typeof val === 'string' ? val : JSON.stringify(val)]); },
                    remove: function(key) { return rpc('storage', 'remove', [String(key)]); },
                    keys: function() { return rpc('storage', 'keys', []); },
                    all: function() { return rpc('storage', 'all', []); }
                }),
                http: Object.freeze({
                    fetch: function(url, options) { return rpc('http', 'fetch', [String(url), options == null ? {} : options]); }
                }),
                workspace: Object.freeze({
                    read: function(path) { return rpc('workspace', 'read', [String(path)]); },
                    write: function(path, content) {
                        return rpc('workspace', 'write', [String(path), typeof content === 'string' ? content : JSON.stringify(content)]);
                    },
                    list: function(path) { return rpc('workspace', 'list', [path == null ? '' : String(path)]); },
                    watch: function(prefix, callback) {
                        const p = prefix == null ? '' : String(prefix);
                        const listener = typeof callback === 'function' ? function(payload) {
                            const path = payload && typeof payload.path === 'string' ? payload.path : '';
                            if (!p || !path || path === p || path.indexOf(p.replace(/\\/+$/, '') + '/') === 0 || payload.prefix === p) {
                                callback(payload);
                            }
                        } : null;
                        return rpc('workspace', 'watch', [p]).then(function() {
                            if (listener) {
                                if (!__listeners['workspace:changed']) __listeners['workspace:changed'] = [];
                                __listeners['workspace:changed'].push(listener);
                            }
                            return function() {
                                if (!listener || !__listeners['workspace:changed']) return;
                                __listeners['workspace:changed'] = __listeners['workspace:changed'].filter(function(h) { return h !== listener; });
                            };
                        });
                    }
                }),
                commands: Object.freeze({
                    register: function(cmd) {
                        const c = cmd || {};
                        return rpc('commands', 'register', [{
                            id: c.id, title: c.title, slash: c.slash, symbol: c.symbol,
                            promptTemplate: c.promptTemplate || c.prompt_template || ''
                        }]);
                    },
                    list: function() { return rpc('commands', 'list', []); }
                }),
                events: Object.freeze({
                    on: function(event, handler) {
                        const ev = String(event);
                        return rpc('events', 'on', [ev]).then(function() {
                            if (!__listeners[ev]) __listeners[ev] = [];
                            if (typeof handler === 'function') __listeners[ev].push(handler);
                            return function() { window.amber.events.off(ev, handler); };
                        });
                    },
                    off: function(event, handler) {
                        const ev = String(event);
                        if (__listeners[ev]) {
                            __listeners[ev] = __listeners[ev].filter(function(h) { return h !== handler; });
                        }
                        return rpc('events', 'off', [ev]);
                    },
                    emit: function(event, payload) {
                        return rpc('events', 'emit', [String(event), payload == null ? {} : payload]);
                    }
                }),
                ui: Object.freeze({
                    notice: function(message, kind) { return rpc('ui', 'notice', [String(message), kind || 'info']); },
                    confirm: function(options) { return rpc('ui', 'confirm', [options == null ? {} : options]); },
                    openView: function(viewId, state) { return rpc('ui', 'openView', [String(viewId), state == null ? {} : state]); },
                    openModal: function(viewId, options) { return rpc('ui', 'openModal', [String(viewId), options == null ? {} : options]); },
                    closeModal: function() { return rpc('ui', 'closeModal', []); }
                }),
                agent: Object.freeze({
                    registerTool: function(def) {
                        const err = new Error('agent.registerTool 只能在后台主脚本（main.js）中调用：工具执行体必须常驻在插件运行时里。');
                        err.code = 'E_INVALID_ARGUMENT';
                        return Promise.reject(err);
                    },
                    getConversation: function() { return rpc('agent', 'getConversation', []); },
                    insertToComposer: function(text) { return rpc('agent', 'insertToComposer', [String(text)]); }
                })
            });
        })();
        """
    }
}

extension DesktopPluginStore {
    func dispatchBridgeRPC(
        pluginID: String,
        viewID: String = "",
        namespace: String,
        method: String,
        args: [Any],
        workspaceDirectory: URL? = nil
    ) async throws -> String {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 当前已停用。")
        }

        let targetWorkspace = workspaceDirectory ?? self.workspaceDirectory

        if namespace == "http" && method == "fetch" {
            return try await handleHTTPFetchAsyncBridgeCall(plugin: plugin, args: args)
        }

        if namespace == "ui" && method == "confirm" {
            return try await handleUIConfirmAsyncBridgeCall(plugin: plugin, args: args)
        }

        if namespace == "neteaseMusic" {
            try requirePermission(plugin: plugin, permission: "music.netease")
            let arguments = try DesktopNeteaseMusicCLI.arguments(method: method, args: args)
            return try await Task.detached(priority: .userInitiated) {
                try DesktopNeteaseMusicCLI.run(arguments: arguments)
            }.value
        }

        return try performSynchronousBridgeCall(
            pluginID: pluginID,
            runtimeHost: runtimeHosts[pluginID],
            namespace: namespace,
            method: method,
            args: args,
            workspaceDirectory: targetWorkspace,
            activeToolEffect: nil
        )
    }

    func performSynchronousBridgeCall(
        pluginID: String,
        runtimeHost: DesktopPluginRuntimeHost?,
        namespace: String,
        method: String,
        args: [Any],
        workspaceDirectory: URL,
        activeToolEffect: DesktopToolEffect?
    ) throws -> String {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 当前已停用。")
        }

        switch namespace {
        case "storage":
            return try handleStorageBridgeCall(plugin: plugin, method: method, args: args)
        case "settings":
            return try handleSettingsBridgeCall(plugin: plugin, method: method, args: args)
        case "workspace":
            return try handleWorkspaceBridgeCall(
                plugin: plugin,
                runtimeHost: runtimeHost,
                method: method,
                args: args,
                workspaceDirectory: workspaceDirectory,
                activeToolEffect: activeToolEffect
            )
        case "http":
            return try handleHTTPSyncBridgeCall(
                plugin: plugin,
                method: method,
                args: args,
                activeToolEffect: activeToolEffect
            )
        case "commands":
            return try handleCommandsBridgeCall(plugin: plugin, runtimeHost: runtimeHost, method: method, args: args)
        case "events":
            return try handleEventsBridgeCall(plugin: plugin, runtimeHost: runtimeHost, method: method, args: args)
        case "ui":
            return try handleUIBridgeCall(plugin: plugin, method: method, args: args)
        case "agent":
            return try handleAgentBridgeCall(plugin: plugin, runtimeHost: runtimeHost, method: method, args: args)
        default:
            throw DesktopRuntimeError.message("未知的插件桥命名空间：\(namespace)")
        }
    }
}
