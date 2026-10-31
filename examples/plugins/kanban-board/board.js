// Amber Kanban Board WebView Client (amber.plugin.v3)
(function () {
  "use strict";

  const COLUMNS = [
    { id: "todo", title: "待办 (To Do)" },
    { id: "in_progress", title: "进行中 (In Progress)" },
    { id: "done", title: "已完成 (Done)" }
  ];

  const PRIORITY_LABELS = {
    high: "高优",
    medium: "普通",
    low: "低优"
  };

  let boardState = {
    title: "Amber 研发任务看板",
    updatedAt: new Date().toISOString(),
    columns: COLUMNS,
    cards: []
  };

  let draggedCardId = null;

  const els = {
    boardTitle: document.getElementById("board-title"),
    boardStats: document.getElementById("board-stats"),
    columnsContainer: document.getElementById("columns-container"),
    btnNewCard: document.getElementById("btn-new-card"),
    btnExportMd: document.getElementById("btn-export-md"),
    btnAskAgent: document.getElementById("btn-ask-agent"),
    dialogBackdrop: document.getElementById("card-dialog-backdrop"),
    dialogTitle: document.getElementById("dialog-title"),
    btnDialogClose: document.getElementById("btn-dialog-close"),
    cardForm: document.getElementById("card-form"),
    fieldCardId: document.getElementById("field-card-id"),
    fieldTitle: document.getElementById("field-title"),
    fieldDescription: document.getElementById("field-description"),
    fieldColumn: document.getElementById("field-column"),
    fieldPriority: document.getElementById("field-priority"),
    fieldTags: document.getElementById("field-tags"),
    btnDeleteCard: document.getElementById("btn-delete-card"),
    btnCancelCard: document.getElementById("btn-cancel-card")
  };

  async function resolvePaths() {
    const boardPath = (await window.amber.settings.get("board_file_path")) || "kanban/board.json";
    const markdownPath = (await window.amber.settings.get("markdown_export_path")) || "kanban/BOARD.md";
    const autoExport = await window.amber.settings.get("auto_export_markdown");
    return {
      boardPath: String(boardPath),
      markdownPath: String(markdownPath),
      autoSyncMarkdown: autoExport !== "false" && autoExport !== false
    };
  }

  function renderMarkdown(board) {
    const lines = [
      `# ${board.title || "Amber 研发任务看板"}`,
      "",
      `> 最近同步时间：${board.updatedAt || new Date().toISOString()}`,
      ""
    ];
    for (const col of COLUMNS) {
      const colCards = (board.cards || []).filter((c) => c.column === col.id);
      lines.push(`## ${col.title} (${colCards.length})`);
      lines.push("");
      if (colCards.length === 0) {
        lines.push("_暂无卡片_");
        lines.push("");
        continue;
      }
      for (const card of colCards) {
        const check = col.id === "done" ? "[x]" : "[ ]";
        const prio = card.priority ? ` \`[${String(card.priority).toUpperCase()}]\`` : "";
        const tags =
          Array.isArray(card.tags) && card.tags.length > 0
            ? " " + card.tags.map((t) => `#${t}`).join(" ")
            : "";
        lines.push(`- ${check} **${card.title}** (\`${card.id}\`)${prio}${tags}`);
        if (card.description) {
          lines.push(`  - ${card.description}`);
        }
      }
      lines.push("");
    }
    return lines.join("\n");
  }

  async function loadBoard() {
    try {
      const { boardPath } = await resolvePaths();
      try {
        const raw = await window.amber.workspace.read(boardPath);
        if (raw && typeof raw === "string") {
          const parsed = JSON.parse(raw);
          if (parsed && Array.isArray(parsed.cards)) {
            boardState = {
              title: parsed.title || "Amber 研发任务看板",
              updatedAt: parsed.updatedAt || new Date().toISOString(),
              columns: COLUMNS,
              cards: parsed.cards
            };
            renderBoard();
            return;
          }
        }
      } catch (_) {
        // Fallback to plugin KV storage if workspace file doesn't exist yet
      }

      const cached = await window.amber.storage.get("board");
      if (cached && Array.isArray(cached.cards)) {
        boardState = {
          title: cached.title || "Amber 研发任务看板",
          updatedAt: cached.updatedAt || new Date().toISOString(),
          columns: COLUMNS,
          cards: cached.cards
        };
      }
    } catch (err) {
      console.error("[kanban-board] loadBoard error:", err);
    }
    renderBoard();
  }

  async function persistBoard(toastMessage) {
    boardState.updatedAt = new Date().toISOString();
    renderBoard();
    try {
      const { boardPath, markdownPath, autoSyncMarkdown } = await resolvePaths();
      await window.amber.storage.set("board", boardState);
      await window.amber.workspace.write(boardPath, JSON.stringify(boardState, null, 2));
      if (autoSyncMarkdown) {
        await window.amber.workspace.write(markdownPath, renderMarkdown(boardState));
      }
      await window.amber.events.emit("kanban:board_updated", boardState);
      await window.amber.events.emit("kanban:updated", {
        totalCards: (boardState.cards || []).length,
        updatedAt: boardState.updatedAt
      });
      if (toastMessage) {
        await window.amber.ui.notice(toastMessage, "info");
      }
    } catch (err) {
      await window.amber.ui.notice("保存看板失败: " + (err.message || String(err)), "error");
    }
  }

  function renderBoard() {
    els.boardTitle.textContent = boardState.title || "Amber 研发任务看板";
    const cards = Array.isArray(boardState.cards) ? boardState.cards : [];
    els.boardStats.textContent = `${cards.length} 张卡片`;

    els.columnsContainer.innerHTML = "";

    for (const col of COLUMNS) {
      const colCards = cards.filter((c) => c.column === col.id);

      const section = document.createElement("section");
      section.className = "kanban-column";
      section.dataset.columnId = col.id;

      const header = document.createElement("div");
      header.className = "kanban-column-header";
      header.innerHTML = `
        <span class="kanban-column-title">${escapeHTML(col.title)}</span>
        <span class="kanban-column-count">${colCards.length}</span>
      `;

      const list = document.createElement("div");
      list.className = "kanban-card-list";
      list.dataset.columnId = col.id;

      // Drag and drop events on column list
      list.addEventListener("dragover", (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        section.classList.add("drag-over");
      });

      list.addEventListener("dragleave", () => {
        section.classList.remove("drag-over");
      });

      list.addEventListener("drop", async (e) => {
        e.preventDefault();
        section.classList.remove("drag-over");
        const cardId = e.dataTransfer.getData("text/plain") || draggedCardId;
        if (!cardId) return;
        await moveCardToColumn(cardId, col.id);
      });

      if (colCards.length === 0) {
        const empty = document.createElement("div");
        empty.className = "empty-column-hint";
        empty.textContent = "拖拽卡片到此列，或点击上方 + 新建卡片";
        list.appendChild(empty);
      } else {
        for (const card of colCards) {
          const cardEl = createCardElement(card);
          list.appendChild(cardEl);
        }
      }

      section.appendChild(header);
      section.appendChild(list);
      els.columnsContainer.appendChild(section);
    }
  }

  function createCardElement(card) {
    const el = document.createElement("article");
    el.className = "kanban-card";
    el.draggable = true;
    el.dataset.cardId = card.id;

    const prio = card.priority || "medium";
    const prioLabel = PRIORITY_LABELS[prio] || "普通";
    const tags = Array.isArray(card.tags) ? card.tags : [];

    el.innerHTML = `
      <div class="kanban-card-top">
        <h3 class="kanban-card-title">${escapeHTML(card.title)}</h3>
        <span class="priority-pill priority-${escapeHTML(prio)}">${escapeHTML(prioLabel)}</span>
      </div>
      ${
        card.description
          ? `<p class="kanban-card-desc">${escapeHTML(card.description)}</p>`
          : ""
      }
      <div class="kanban-card-footer">
        <div class="kanban-tags">
          ${tags.map((t) => `<span class="tag-chip">#${escapeHTML(t)}</span>`).join("")}
        </div>
        <span class="card-id-label">${escapeHTML(card.id)}</span>
      </div>
    `;

    el.addEventListener("dragstart", (e) => {
      draggedCardId = card.id;
      el.classList.add("dragging");
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", card.id);
    });

    el.addEventListener("dragend", () => {
      draggedCardId = null;
      el.classList.remove("dragging");
    });

    el.addEventListener("click", () => {
      openCardDialog(card);
    });

    return el;
  }

  async function moveCardToColumn(cardId, targetColumnId) {
    const idx = boardState.cards.findIndex((c) => c.id === cardId);
    if (idx < 0) return;
    const card = boardState.cards[idx];
    if (card.column === targetColumnId) return;

    card.column = targetColumnId;
    card.updatedAt = new Date().toISOString();
    // Move to end of column
    boardState.cards.splice(idx, 1);
    boardState.cards.push(card);

    const targetCol = COLUMNS.find((c) => c.id === targetColumnId);
    await persistBoard(`已将「${card.title}」移至 ${targetCol ? targetCol.title : targetColumnId}`);
  }

  function openCardDialog(card) {
    if (card) {
      els.dialogTitle.textContent = "编辑任务卡片";
      els.fieldCardId.value = card.id;
      els.fieldTitle.value = card.title || "";
      els.fieldDescription.value = card.description || "";
      els.fieldColumn.value = card.column || "todo";
      els.fieldPriority.value = card.priority || "medium";
      els.fieldTags.value = Array.isArray(card.tags) ? card.tags.join(", ") : "";
      els.btnDeleteCard.classList.remove("hidden");
    } else {
      els.dialogTitle.textContent = "新建任务卡片";
      els.fieldCardId.value = "";
      els.fieldTitle.value = "";
      els.fieldDescription.value = "";
      els.fieldColumn.value = "todo";
      els.fieldPriority.value = "medium";
      els.fieldTags.value = "";
      els.btnDeleteCard.classList.add("hidden");
    }
    els.dialogBackdrop.classList.remove("hidden");
    els.fieldTitle.focus();
  }

  function closeCardDialog() {
    els.dialogBackdrop.classList.add("hidden");
  }

  function nextCardId() {
    const nums = (boardState.cards || []).map((c) => {
      const m = /^card-(\d+)$/.exec(c.id || "");
      return m ? parseInt(m[1], 10) : 0;
    });
    const max = nums.reduce((a, b) => Math.max(a, b), 0);
    return `card-${max + 1}`;
  }

  function escapeHTML(str) {
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // Event listeners
  els.btnNewCard.addEventListener("click", () => openCardDialog(null));
  els.btnDialogClose.addEventListener("click", closeCardDialog);
  els.btnCancelCard.addEventListener("click", closeCardDialog);

  els.cardForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const id = els.fieldCardId.value.trim();
    const title = els.fieldTitle.value.trim();
    if (!title) return;

    const description = els.fieldDescription.value.trim();
    const column = els.fieldColumn.value || "todo";
    const priority = els.fieldPriority.value || "medium";
    const tags = els.fieldTags.value
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);

    if (id) {
      const existing = boardState.cards.find((c) => c.id === id);
      if (existing) {
        existing.title = title;
        existing.description = description;
        existing.column = column;
        existing.priority = priority;
        existing.tags = tags;
        existing.updatedAt = new Date().toISOString();
      }
      closeCardDialog();
      await persistBoard(`已更新卡片「${title}」`);
    } else {
      const newCard = {
        id: nextCardId(),
        title,
        description,
        column,
        priority,
        tags,
        updatedAt: new Date().toISOString()
      };
      boardState.cards.push(newCard);
      closeCardDialog();
      await persistBoard(`已创建卡片「${title}」`);
    }
  });

  els.btnDeleteCard.addEventListener("click", async () => {
    const id = els.fieldCardId.value.trim();
    if (!id) return;
    const target = boardState.cards.find((c) => c.id === id);
    if (!target) return;

    const confirmed = await window.amber.ui.confirm({
      title: "删除任务卡片",
      message: `确定要删除卡片「${target.title}」吗？该操作将同步写入工作区文件。`
    });
    if (!confirmed) return;

    boardState.cards = boardState.cards.filter((c) => c.id !== id);
    closeCardDialog();
    await persistBoard(`已删除卡片「${target.title}」`);
  });

  els.btnExportMd.addEventListener("click", async () => {
    try {
      const { markdownPath } = await resolvePaths();
      const md = renderMarkdown(boardState);
      await window.amber.workspace.write(markdownPath, md);
      await window.amber.ui.notice(`已导出 Markdown 看板至 ${markdownPath}`, "info");
    } catch (err) {
      await window.amber.ui.notice("导出 Markdown 失败: " + (err.message || String(err)), "error");
    }
  });

  els.btnAskAgent.addEventListener("click", async () => {
    try {
      await window.amber.agent.insertToComposer(
        "请调用 kanban_list_cards 查看当前任务看板，帮我梳理待办与进行中任务的优先级建议。"
      );
      await window.amber.ui.notice("已将指令填入对话输入框", "info");
    } catch (err) {
      await window.amber.ui.notice("填入输入框失败: " + (err.message || String(err)), "error");
    }
  });

  // Subscribe to background plugin events & workspace updates
  if (window.amber && window.amber.events) {
    window.amber.events.on("kanban:board_updated", (updatedBoard) => {
      if (updatedBoard && Array.isArray(updatedBoard.cards)) {
        boardState = updatedBoard;
        renderBoard();
      }
    });

    window.amber.events.on("kanban:open_new_card_dialog", () => {
      openCardDialog(null);
    });

    window.amber.events.on("workspace:changed", () => {
      loadBoard();
    });

    window.amber.events.on("workspace:file_changed", (payload) => {
      if (!payload || !payload.path || String(payload.path).endsWith("board.json")) {
        loadBoard();
      }
    });
  }

  // Initial load
  loadBoard();
})();
