/**
 * Project instruction + memory modals (Claude project rail UX).
 * Pure DOM helpers used by main.ts renderProjectDetail.
 */

import type { ProjectItem, ProjectsStore } from "../client/projects-store.js";
import {
  memoryPlaceholderAt,
  memoryTextFromEditor,
  MEMORY_EMPTY_STATE_MARKER,
} from "../client/projects-store.js";
import { relativeTime } from "../client/code-sessions-store.js";

type ElFn = <K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs?: Record<string, string>,
  children?: (string | Node)[],
) => HTMLElementTagNameMap[K];

export function openInstructionsModal(
  project: ProjectItem,
  projects: ProjectsStore,
  el: ElFn,
  onSaved: () => void,
): void {
  const backdrop = el("div", { class: "modal-backdrop project-modal-backdrop" });
  const modal = el("div", { class: "modal project-modal" });

  const head = el("div", { class: "project-modal-head" });
  head.append(el("h3", {}, ["Set project instructions"]));
  const closeX = el("button", { class: "modal-x", type: "button", "aria-label": "Close" }, ["×"]);
  head.append(closeX);
  modal.append(head);

  modal.append(
    el("p", { class: "settings-hint" }, [
      `Provide relevant instructions for chats within ${project.name}. This works alongside profile instructions and the selected model style.`,
    ]),
  );

  const ta = el("textarea", {
    class: "project-modal-textarea",
    rows: "8",
    placeholder:
      "Think step by step and show reasoning for complex problems. Use specific examples.",
  }) as HTMLTextAreaElement;
  ta.value = project.instructions || "";
  modal.append(ta);

  const actions = el("div", { class: "project-modal-actions" });
  const cancel = el("button", { class: "ghost-btn", type: "button" }, ["Cancel"]);
  const save = el("button", { class: "primary-btn", type: "button" }, ["Save instructions"]);
  actions.append(cancel, save);
  modal.append(actions);

  const close = () => backdrop.remove();
  closeX.addEventListener("click", close);
  cancel.addEventListener("click", close);
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) close();
  });
  save.addEventListener("click", () => {
    projects.setInstructions(project.id, ta.value);
    // Keep description in sync when empty so cards still have a blurb option
    close();
    onSaved();
  });

  backdrop.append(modal);
  document.body.append(backdrop);
  queueMicrotask(() => ta.focus());
}

export function openMemoryModal(
  project: ProjectItem,
  projects: ProjectsStore,
  el: ElFn,
  onSaved: () => void,
): void {
  const backdrop = el("div", { class: "modal-backdrop project-modal-backdrop" });
  const modal = el("div", { class: "modal project-modal project-memory-modal" });

  const head = el("div", { class: "project-modal-head" });
  head.append(el("h3", {}, ["Manage project memory"]));
  const closeX = el("button", { class: "modal-x", type: "button", "aria-label": "Close" }, ["×"]);
  head.append(closeX);
  modal.append(head);

  modal.append(
    el("p", { class: "settings-hint" }, [
      "Project memory is private to you on this device. It is used as context for chats in this project. Only you can see it.",
    ]),
  );

  const body = el("div", { class: "project-memory-body" });
  const content = el("div", { class: "project-memory-content" });
  content.contentEditable = "true";
  content.spellcheck = true;
  const startedEmpty = !project.memory.trim();
  let userEditedBody = false;
  if (!startedEmpty) {
    content.innerText = project.memory;
  } else {
    content.dataset.emptyChrome = "1";
    content.innerHTML =
      `<p><strong>Purpose &amp; context</strong></p><p class="muted">${MEMORY_EMPTY_STATE_MARKER}. Use the box below to add facts, or chat in this project and generate memory later.</p>`;
  }
  body.append(content);
  modal.append(body);

  const markEdited = () => {
    userEditedBody = true;
    delete content.dataset.emptyChrome;
  };
  content.addEventListener("input", markEdited);
  content.addEventListener("focus", () => {
    // Clear chrome on first focus so typing does not append to placeholder
    if (content.dataset.emptyChrome === "1" && !userEditedBody) {
      content.innerHTML = "";
      delete content.dataset.emptyChrome;
    }
  });

  const readPersistableBody = (): string =>
    memoryTextFromEditor(content.innerText, {
      startedEmpty,
      userEdited: userEditedBody,
    });

  // Adjust field with cycling placeholders
  const adjustRow = el("div", { class: "memory-adjust-row" });
  const input = el("input", {
    class: "memory-adjust-input",
    type: "text",
    autocomplete: "off",
  }) as HTMLInputElement;
  let phIndex = 0;
  let cycling = true;
  const applyPh = () => {
    if (!cycling || document.activeElement === input) return;
    input.placeholder = memoryPlaceholderAt(phIndex);
    phIndex += 1;
  };
  applyPh();
  const timer = window.setInterval(applyPh, 3200);

  const send = el("button", {
    class: "memory-adjust-send",
    type: "button",
    title: "Apply",
    "aria-label": "Apply memory adjustment",
  }, ["→"]);

  const applyCmd = () => {
    const cmd = input.value.trim();
    if (!cmd) return;
    // Save freeform body edits first — never persist empty-state chrome
    const bodyText = readPersistableBody();
    const current = projects.get(project.id)?.memory.trim() ?? "";
    if (bodyText !== current) {
      projects.setMemory(project.id, bodyText);
    }
    const next = projects.applyMemoryCommand(project.id, cmd);
    content.innerText = next;
    userEditedBody = true;
    delete content.dataset.emptyChrome;
    input.value = "";
    onSaved();
  };

  input.addEventListener("focus", () => {
    cycling = false;
  });
  input.addEventListener("blur", () => {
    if (!input.value.trim()) {
      cycling = true;
      applyPh();
    }
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      applyCmd();
    }
  });
  send.addEventListener("click", applyCmd);
  adjustRow.append(input, send);
  modal.append(adjustRow);

  const actions = el("div", { class: "project-modal-actions" });
  const done = el("button", { class: "primary-btn", type: "button" }, ["Done"]);
  actions.append(done);
  modal.append(actions);

  const close = () => {
    window.clearInterval(timer);
    // Persist contenteditable on close — never empty-state chrome
    const bodyText = readPersistableBody();
    const p = projects.get(project.id);
    if (p && bodyText !== p.memory.trim()) {
      projects.setMemory(project.id, bodyText);
    }
    backdrop.remove();
    onSaved();
  };
  closeX.addEventListener("click", close);
  done.addEventListener("click", close);
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) close();
  });

  backdrop.append(modal);
  document.body.append(backdrop);
  queueMicrotask(() => input.focus());
}

export function memoryPreview(project: ProjectItem): string {
  const m = memoryTextFromEditor(project.memory, { startedEmpty: true, userEdited: true });
  if (!m) return "Project memory will show here after a few chats.";
  return m.length > 140 ? m.slice(0, 137) + "…" : m;
}

export function memoryMeta(project: ProjectItem): string {
  if (!project.memoryUpdatedAt) return "Only you";
  return `Only you · Updated ${relativeTime(project.memoryUpdatedAt)}`;
}

// ---------------------------------------------------------------------------
// Context + dropdown (Upload, text, connectors, search resources)
// ---------------------------------------------------------------------------

export type ContextMenuCallbacks = {
  onUploadFile: () => void;
  onAddText: () => void;
  onPickArtifact: (title: string, content: string) => void;
  onPasteUrl: (url: string) => void;
  onConnector: (id: string) => void;
  artifactSuggestions: Array<{ title: string; content: string }>;
};

const CONNECTORS: Array<{
  id: string;
  label: string;
  iconClass: string;
  icon: string;
}> = [
  { id: "github", label: "GitHub", iconClass: "ctx-brand-github", icon: "⌘" },
  { id: "figma", label: "Figma", iconClass: "ctx-brand-figma", icon: "◇" },
  { id: "godaddy", label: "GoDaddy", iconClass: "ctx-brand-godaddy", icon: "G" },
  { id: "drive", label: "Drive", iconClass: "ctx-brand-drive", icon: "△" },
];

/**
 * Claude-style context menu under the project-rail + control.
 * Connector rows open a flyout (left when near the right edge) with
 * "Search resources or paste URL" + document list.
 */
export function openContextAddMenu(
  anchor: HTMLElement,
  el: ElFn,
  cb: ContextMenuCallbacks,
): void {
  document.querySelectorAll(".context-add-menu, .context-submenu").forEach((n) => n.remove());

  const menu = el("div", { class: "context-add-menu", role: "menu" });
  const rect = anchor.getBoundingClientRect();
  const menuW = 228;
  // Align under +; keep on-screen (menu lives on the right rail)
  let left = rect.right - menuW;
  left = Math.max(8, Math.min(left, window.innerWidth - menuW - 8));
  menu.style.top = `${rect.bottom + 6}px`;
  menu.style.left = `${left}px`;

  let activeSub: HTMLElement | null = null;
  let activeRow: HTMLElement | null = null;

  const closeAll = () => {
    menu.remove();
    activeSub?.remove();
    activeSub = null;
    document.removeEventListener("mousedown", onDoc);
    document.removeEventListener("keydown", onKey);
  };

  const hideSub = () => {
    activeSub?.remove();
    activeSub = null;
    activeRow?.classList.remove("is-open");
    activeRow = null;
  };

  const makeResourceFlyout = (connectorId: string): HTMLElement => {
    const sub = el("div", {
      class: "context-submenu",
      "data-connector": connectorId,
      role: "menu",
    });
    const search = el("input", {
      class: "context-sub-search",
      type: "search",
      placeholder: "Search resources or paste URL",
      autocomplete: "off",
    }) as HTMLInputElement;
    const list = el("div", { class: "context-sub-list" });

    const paint = (q: string) => {
      list.innerHTML = "";
      const raw = q.trim();
      const query = raw.toLowerCase();
      if (/^https?:\/\//i.test(raw)) {
        const row = el("button", { class: "context-sub-item", type: "button" });
        row.append(el("span", { class: "ctx-doc-ico" }, ["🔗"]));
        row.append(
          el("span", { class: "ctx-sub-title" }, [
            raw.length > 48 ? `Paste URL: ${raw.slice(0, 45)}…` : `Paste URL: ${raw}`,
          ]),
        );
        row.addEventListener("click", () => {
          closeAll();
          cb.onPasteUrl(raw);
        });
        list.append(row);
      }
      const hits = cb.artifactSuggestions.filter(
        (s) => !query || s.title.toLowerCase().includes(query),
      );
      if (hits.length === 0 && !/^https?:\/\//i.test(raw)) {
        list.append(
          el("div", { class: "context-sub-empty" }, [
            query
              ? "No matches"
              : "No saved resources yet — upload a file or add text content.",
          ]),
        );
      }
      for (const s of hits.slice(0, 14)) {
        const row = el("button", { class: "context-sub-item", type: "button" });
        row.append(el("span", { class: "ctx-doc-ico" }, ["📄"]));
        row.append(el("span", { class: "ctx-sub-title" }, [s.title]));
        row.addEventListener("click", () => {
          closeAll();
          cb.onPickArtifact(s.title, s.content);
        });
        list.append(row);
      }
    };

    search.addEventListener("input", () => paint(search.value));
    search.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && /^https?:\/\//i.test(search.value.trim())) {
        closeAll();
        cb.onPasteUrl(search.value.trim());
      }
      e.stopPropagation();
    });
    sub.addEventListener("mousedown", (e) => e.stopPropagation());
    sub.addEventListener("click", (e) => e.stopPropagation());
    sub.append(search, list);
    paint("");
    queueMicrotask(() => search.focus());
    return sub;
  };

  const positionFlyout = (row: HTMLElement, sub: HTMLElement) => {
    document.body.append(sub);
    const rowRect = row.getBoundingClientRect();
    const subW = Math.min(300, Math.max(260, sub.offsetWidth || 280));
    const gap = 6;
    // Prefer left of main menu (right-rail UX); fall back to right if needed
    let subLeft = left - subW - gap;
    if (subLeft < 8) {
      subLeft = left + menuW + gap;
    }
    subLeft = Math.max(8, Math.min(subLeft, window.innerWidth - subW - 8));
    let subTop = rowRect.top;
    const maxH = Math.min(340, window.innerHeight - 24);
    sub.style.maxHeight = `${maxH}px`;
    if (subTop + 200 > window.innerHeight - 12) {
      subTop = Math.max(8, window.innerHeight - 220);
    }
    sub.style.top = `${subTop}px`;
    sub.style.left = `${subLeft}px`;
    sub.style.width = `${subW}px`;
  };

  const showConnector = (row: HTMLElement, connectorId: string) => {
    if (activeRow === row && activeSub) return;
    hideSub();
    activeRow = row;
    row.classList.add("is-open");
    activeSub = makeResourceFlyout(connectorId);
    positionFlyout(row, activeSub);
  };

  const addActionItem = (icon: string, label: string, action: () => void, iconClass?: string) => {
    const row = el("button", { class: "context-menu-item", type: "button", role: "menuitem" });
    const ico = el("span", { class: `ctx-ico${iconClass ? ` ${iconClass}` : ""}` }, [icon]);
    row.append(ico);
    row.append(el("span", { class: "ctx-label" }, [label]));
    row.addEventListener("mouseenter", () => hideSub());
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      closeAll();
      action();
    });
    menu.append(row);
  };

  addActionItem("📎", "Upload from device", () => cb.onUploadFile());
  addActionItem("⎘", "Add text content", () => cb.onAddText(), "ctx-ico-text");
  menu.append(el("div", { class: "context-menu-sep" }));

  for (const c of CONNECTORS) {
    const row = el("button", {
      class: "context-menu-item has-sub",
      type: "button",
      role: "menuitem",
      "aria-haspopup": "true",
    });
    row.append(el("span", { class: `ctx-ico ${c.iconClass}` }, [c.icon]));
    row.append(el("span", { class: "ctx-label" }, [c.label]));
    row.append(el("span", { class: "ctx-chev" }, ["›"]));
    row.addEventListener("mouseenter", () => showConnector(row, c.id));
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      showConnector(row, c.id);
    });
    menu.append(row);
  }

  const onDoc = (e: MouseEvent) => {
    const t = e.target as Node;
    if (menu.contains(t) || activeSub?.contains(t) || t === anchor) return;
    closeAll();
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") closeAll();
  };
  document.addEventListener("mousedown", onDoc);
  document.addEventListener("keydown", onKey);
  document.body.append(menu);
}

export function openAddTextContextModal(
  projectId: string,
  projects: ProjectsStore,
  el: ElFn,
  onSaved: () => void,
): void {
  const backdrop = el("div", { class: "modal-backdrop project-modal-backdrop" });
  const modal = el("div", { class: "modal project-modal" });
  const head = el("div", { class: "project-modal-head" });
  head.append(el("h3", {}, ["Add text content"]));
  const closeX = el("button", { class: "modal-x", type: "button" }, ["×"]);
  head.append(closeX);
  modal.append(head);
  modal.append(
    el("p", { class: "settings-hint" }, [
      "Paste notes, briefs, or excerpts to use as project context.",
    ]),
  );
  const title = el("input", {
    class: "project-modal-input",
    type: "text",
    placeholder: "Title",
  }) as HTMLInputElement;
  const ta = el("textarea", {
    class: "project-modal-textarea",
    rows: "8",
    placeholder: "Paste or type content…",
  }) as HTMLTextAreaElement;
  modal.append(title, ta);
  const actions = el("div", { class: "project-modal-actions" });
  const cancel = el("button", { class: "ghost-btn", type: "button" }, ["Cancel"]);
  const save = el("button", { class: "primary-btn", type: "button" }, ["Add to project"]);
  actions.append(cancel, save);
  modal.append(actions);
  const close = () => backdrop.remove();
  closeX.addEventListener("click", close);
  cancel.addEventListener("click", close);
  save.addEventListener("click", () => {
    const body = ta.value.trim();
    if (!body) return;
    projects.addContextItem(projectId, {
      kind: "text",
      title: title.value.trim() || body.slice(0, 48),
      content: body,
    });
    close();
    onSaved();
  });
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) close();
  });
  backdrop.append(modal);
  document.body.append(backdrop);
  queueMicrotask(() => title.focus());
}
