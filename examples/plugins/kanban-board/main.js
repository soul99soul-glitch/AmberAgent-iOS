// Amber Plugin v3 Example: Interactive Kanban Board (Background Runtime & Agent Tools)

const KANBAN_JSON_PATH = "kanban/board.json";
const KANBAN_MD_PATH = "kanban/BOARD.md";
const KANBAN_STORAGE_KEY = "kanban_board_state_v3";

const DEFAULT_COLUMNS = [
  { id: "todo", title: "待办 (To Do)" },
  { id: "in_progress", title: "进行中 (In Progress)" },
  { id: "done", title: "已完成 (Done)" }
];

function _defaultBoard() {
  const title = amber.settings.get("board_title") || "Amber 研发任务看板";
  return {
    title: title,
    updatedAt: amber.settings.get("today") || "2026-10-31",
    columns: DEFAULT_COLUMNS,
    cards: [
      {
        id: "card_v3_bridge",
        title: "设计并实现 amber.plugin.v3 Promise 桥",
        description: "提供 storage / workspace / http / commands / events / ui / agent / settings 八大命名空间。",
        column: "done",
        priority: "high",
        tags: ["architecture", "v3"],
        order: 0
      },
      {
        id: "card_v3_webview",
        title: "接入 amber-plugin:// 受控 WKWebView 视图",
        description: "支持主工作区、侧栏、检查器与模态弹窗，自动同步亮暗色主题。",
        column: "in_progress",
        priority: "high",
        tags: ["ui", "webview"],
        order: 0
      },
      {
        id: "card_v3_kanban",
        title: "验证看板拖拽与 Markdown 双向导出",
        description: "支持跨列拖拽排序并将结果写入 kanban/board.json 与 kanban/BOARD.md。",
        column: "todo",
        priority: "medium",
        tags: ["kanban", "workspace"],
        order: 0
      }
    ]
  };
}

function _normalizeBoard(raw) {
  const base = _defaultBoard();
  if (!raw || typeof raw !== "object") return base;
  const columns = Array.isArray(raw.columns) && raw.columns.length > 0 ? raw.columns : DEFAULT_COLUMNS;
  const cards = Array.isArray(raw.cards) ? raw.cards.map(function (c, idx) {
    return {
      id: String(c.id || ("card_" + (idx + 1))),
      title: String(c.title || "未命名任务"),
      description: String(c.description || ""),
      column: String(c.column || "todo"),
      priority: String(c.priority || "medium"),
      tags: Array.isArray(c.tags) ? c.tags.map(String) : [],
      order: typeof c.order === "number" ? c.order : idx
    };
  }) : base.cards;
  return {
    title: String(raw.title || base.title),
    updatedAt: String(raw.updatedAt || amber.settings.get("today") || "2026-10-31"),
    columns: columns,
    cards: cards
  };
}

function _loadBoard() {
  try {
    const fileText = amber.workspace.read(KANBAN_JSON_PATH);
    if (fileText && fileText.trim().length > 0) {
      const parsed = JSON.parse(fileText);
      const board = _normalizeBoard(parsed);
      amber.storage.set(KANBAN_STORAGE_KEY, JSON.stringify(board));
      amber.storage.set("badge:kanban_board", String(board.cards.length));
      return board;
    }
  } catch (e) {
    // Fall back to plugin storage if kanban/board.json does not exist yet
  }

  try {
    const cached = amber.storage.get(KANBAN_STORAGE_KEY);
    if (cached && cached.trim().length > 0) {
      return _normalizeBoard(JSON.parse(cached));
    }
  } catch (e) {}

  return _defaultBoard();
}

function _renderBoardMarkdown(board) {
  const lines = [
    "# " + board.title,
    "",
    "> 更新日期：" + board.updatedAt + " · 总卡片数：" + board.cards.length,
    ""
  ];
  for (let i = 0; i < board.columns.length; i++) {
    const col = board.columns[i];
    const colCards = board.cards
      .filter(function (c) { return c.column === col.id; })
      .sort(function (a, b) { return (a.order || 0) - (b.order || 0); });
    lines.push("## " + col.title + " (" + colCards.length + ")");
    lines.push("");
    if (colCards.length === 0) {
      lines.push("- _暂无卡片_");
    } else {
      for (let j = 0; j < colCards.length; j++) {
        const card = colCards[j];
        const checkbox = col.id === "done" ? "[x]" : "[ ]";
        const prio = card.priority ? " `[" + card.priority + "]`" : "";
        const tagText = card.tags && card.tags.length > 0 ? " (" + card.tags.map(function (t) { return "#" + t; }).join(" ") + ")" : "";
        lines.push("- " + checkbox + " **" + card.title + "**" + prio + tagText + " `id:" + card.id + "`");
        if (card.description) {
          lines.push("  - " + card.description);
        }
      }
    }
    lines.push("");
  }
  return lines.join("\n");
}

function _saveBoard(board) {
  const normalized = _normalizeBoard(board);
  normalized.updatedAt = amber.settings.get("today") || normalized.updatedAt;
  const jsonText = JSON.stringify(normalized, null, 2);

  amber.storage.set(KANBAN_STORAGE_KEY, jsonText);
  amber.storage.set("board", jsonText);
  amber.storage.set("badge:kanban_main", String(normalized.cards.length));
  amber.storage.set("badge:kanban_board", String(normalized.cards.length));
  amber.workspace.write(KANBAN_JSON_PATH, jsonText);

  const autoExport = amber.settings.get("auto_export_markdown");
  const mdText = _renderBoardMarkdown(normalized);
  if (autoExport !== "false") {
    amber.workspace.write(KANBAN_MD_PATH, mdText);
  }
  amber.events.emit("kanban:updated", {
    totalCards: normalized.cards.length,
    updatedAt: normalized.updatedAt
  });
  amber.events.emit("kanban:board_updated", normalized);
  return { board: normalized, markdown: mdText };
}

function _reindexColumn(cards, columnId) {
  const inCol = cards
    .filter(function (c) { return c.column === columnId; })
    .sort(function (a, b) { return (a.order || 0) - (b.order || 0); });
  for (let i = 0; i < inCol.length; i++) {
    inCol[i].order = i;
  }
}

// Lifecycle Hooks
function onload() {
  const board = _loadBoard();
  _saveBoard(board);
  amber.workspace.watch("kanban", function (ev) {
    amber.events.emit("kanban:workspace-sync", ev || {});
  });
}

function onunload() {
  // Clean teardown hook
}

// Inspector Card Snapshot
function renderInspector() {
  const board = _loadBoard();
  const todoCount = board.cards.filter(function (c) { return c.column === "todo"; }).length;
  const inProgressCount = board.cards.filter(function (c) { return c.column === "in_progress"; }).length;
  const doneCount = board.cards.filter(function (c) { return c.column === "done"; }).length;

  const activeItems = board.cards
    .filter(function (c) { return c.column !== "done"; })
    .slice(0, 4)
    .map(function (c) {
      return {
        id: c.id,
        badge: c.column === "in_progress" ? "进行中" : "待办",
        title: c.title,
        subtitle: c.description || ("优先级：" + c.priority),
        actionTitle: "推进",
        prompt: "请帮我拆解并推进看板卡片「" + c.title + "」（ID: " + c.id + "），完成后调用 kanban_move_card 更新状态。"
      };
    });

  return {
    statusBadge: todoCount + " 待办 · " + inProgressCount + " 进行中 · " + doneCount + " 完成",
    emptyMessage: "所有看板任务均已完成！",
    footerActionTitle: "打开任务看板",
    opensWorkspaceViewID: "kanban_main",
    items: activeItems
  };
}

// Agent Tool 1: kanban_list_cards
function kanbanListCards(input) {
  const board = _loadBoard();
  const filterColumn = input && input.column ? String(input.column).trim() : "";
  const cards = filterColumn
    ? board.cards.filter(function (c) { return c.column === filterColumn; })
    : board.cards;
  return {
    ok: true,
    title: board.title,
    updatedAt: board.updatedAt,
    columns: board.columns,
    totalCards: cards.length,
    cards: cards
  };
}

// Agent Tool 2: kanban_add_card
function kanbanAddCard(input) {
  const title = String((input && input.title) || "").trim();
  if (!title) {
    throw new Error("kanban_add_card 需要非空的卡片标题 title。");
  }
  const board = _loadBoard();
  const column = String((input && input.column) || "todo").trim();
  const validCol = board.columns.some(function (c) { return c.id === column; }) ? column : "todo";
  const colCount = board.cards.filter(function (c) { return c.column === validCol; }).length;
  const newCard = {
    id: "card_" + Date.now().toString(36) + "_" + Math.random().toString(36).slice(2, 6),
    title: title,
    description: String((input && input.description) || "").trim(),
    column: validCol,
    priority: String((input && input.priority) || "medium").trim(),
    tags: Array.isArray(input && input.tags) ? input.tags.map(String) : [],
    order: colCount
  };
  board.cards.push(newCard);
  const saved = _saveBoard(board);
  return {
    ok: true,
    card: newCard,
    totalCards: saved.board.cards.length,
    jsonPath: KANBAN_JSON_PATH,
    markdownPath: KANBAN_MD_PATH
  };
}

// Agent Tool 3: kanban_move_card
function kanbanMoveCard(input) {
  const cardId = String((input && input.card_id) || "").trim();
  const toColumn = String((input && (input.to_column || input.target_column || input.column)) || "").trim();
  if (!cardId || !toColumn) {
    throw new Error("kanban_move_card 需要提供 card_id 与 to_column。");
  }
  const board = _loadBoard();
  const target = board.cards.find(function (c) { return c.id === cardId; });
  if (!target) {
    throw new Error("未找到卡片 ID：" + cardId);
  }
  if (!board.columns.some(function (c) { return c.id === toColumn; })) {
    throw new Error("无效的目标列 ID：" + toColumn);
  }
  const fromColumn = target.column;
  target.column = toColumn;

  const siblings = board.cards
    .filter(function (c) { return c.column === toColumn && c.id !== cardId; })
    .sort(function (a, b) { return (a.order || 0) - (b.order || 0); });
  const rawIdx = input && typeof input.index === "number"
    ? input.index
    : (input && typeof input.position === "number" ? input.position : null);
  const targetIndex = (typeof rawIdx === "number")
    ? Math.max(0, Math.min(siblings.length, rawIdx))
    : siblings.length;
  siblings.splice(targetIndex, 0, target);
  for (let i = 0; i < siblings.length; i++) {
    siblings[i].order = i;
  }
  if (fromColumn !== toColumn) {
    _reindexColumn(board.cards, fromColumn);
  }

  const saved = _saveBoard(board);
  return {
    ok: true,
    card: target,
    fromColumn: fromColumn,
    toColumn: toColumn,
    totalCards: saved.board.cards.length
  };
}

// Agent Tool 4: kanban_update_card
function kanbanUpdateCard(input) {
  const cardId = String((input && input.card_id) || "").trim();
  if (!cardId) {
    throw new Error("kanban_update_card 需要提供 card_id。");
  }
  const board = _loadBoard();
  const target = board.cards.find(function (c) { return c.id === cardId; });
  if (!target) {
    throw new Error("未找到卡片 ID：" + cardId);
  }
  if (input.title != null && String(input.title).trim().length > 0) {
    target.title = String(input.title).trim();
  }
  if (input.description != null) {
    target.description = String(input.description).trim();
  }
  if (input.priority != null) {
    target.priority = String(input.priority).trim();
  }
  if (Array.isArray(input.tags)) {
    target.tags = input.tags.map(String);
  }
  const saved = _saveBoard(board);
  return {
    ok: true,
    card: target,
    totalCards: saved.board.cards.length
  };
}

// Agent Tool 5: kanban_delete_card
function kanbanDeleteCard(input) {
  const cardId = String((input && input.card_id) || "").trim();
  if (!cardId) {
    throw new Error("kanban_delete_card 需要提供 card_id。");
  }
  const board = _loadBoard();
  const idx = board.cards.findIndex(function (c) { return c.id === cardId; });
  if (idx < 0) {
    throw new Error("未找到卡片 ID：" + cardId);
  }
  const removed = board.cards.splice(idx, 1)[0];
  _reindexColumn(board.cards, removed.column);
  const saved = _saveBoard(board);
  return {
    ok: true,
    deletedCardId: cardId,
    deletedTitle: removed.title,
    totalCards: saved.board.cards.length
  };
}

// Agent Tool 6: kanban_export_markdown
function kanbanExportMarkdown() {
  const board = _loadBoard();
  const mdText = _renderBoardMarkdown(board);
  amber.workspace.write(KANBAN_MD_PATH, mdText);
  amber.workspace.write(KANBAN_JSON_PATH, JSON.stringify(board, null, 2));
  return {
    ok: true,
    markdownPath: KANBAN_MD_PATH,
    jsonPath: KANBAN_JSON_PATH,
    markdown: mdText
  };
}
