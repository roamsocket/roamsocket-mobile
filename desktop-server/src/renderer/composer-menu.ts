/**
 * Chat composer “+” menu — Claude attach-bar parity:
 * files, add to project, GitHub, skills / connectors / plugins flyouts,
 * research + web search toggles.
 */
import type { ProjectItem } from "../client/projects-store.js";
import {
  type ComposerToolsState,
  SKILL_CATALOG,
  CONNECTOR_CATALOG,
  PLUGIN_CATEGORIES,
  connectorsWarningCount,
} from "../client/composer-tools.js";

type ElFn = <K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs?: Record<string, string>,
  children?: (string | Node)[],
) => HTMLElementTagNameMap[K];

export type ComposerMenuCallbacks = {
  tools: ComposerToolsState;
  projects: ProjectItem[];
  /** Installed skills for the flyout (defaults to SKILL_CATALOG) */
  skills?: Array<{ id: string; name: string }>;
  currentProjectId?: string | null;
  onAddFiles: () => void;
  onAddToProject: (projectId: string) => void;
  onAddFromGitHub: () => void;
  onPickSkill: (skillId: string) => void;
  onManageSkills: () => void;
  onBrowseSkills: () => void;
  onToggleConnector: (id: string) => void;
  onManageConnectors: () => void;
  onAddConnector: () => void;
  onToolAccess: () => void;
  onManagePlugins: () => void;
  onBrowsePlugins: () => void;
  onPluginCategory: (id: string) => void;
  onToggleResearch: () => void;
  onToggleWebSearch: () => void;
};

function clearMenus(): void {
  document.querySelectorAll(".composer-plus-menu, .composer-flyout").forEach((n) => n.remove());
}

/**
 * Open the main + menu above the composer attach control.
 */
export function openComposerPlusMenu(
  anchor: HTMLElement,
  el: ElFn,
  cb: ComposerMenuCallbacks,
): void {
  clearMenus();

  const menu = el("div", { class: "composer-plus-menu", role: "menu" });
  const rect = anchor.getBoundingClientRect();
  const menuW = 280;
  let left = rect.left;
  left = Math.max(8, Math.min(left, window.innerWidth - menuW - 8));
  // Prefer above the + button (composer is at bottom)
  const estimatedH = 360;
  let top = rect.top - estimatedH - 8;
  if (top < 8) top = rect.bottom + 8;
  menu.style.left = `${left}px`;
  menu.style.top = `${Math.max(8, top)}px`;
  menu.style.width = `${menuW}px`;

  let activeFly: HTMLElement | null = null;
  let activeRow: HTMLElement | null = null;

  const closeAll = () => {
    menu.remove();
    activeFly?.remove();
    activeFly = null;
    document.removeEventListener("mousedown", onDoc);
    document.removeEventListener("keydown", onKey);
  };

  const hideFly = () => {
    activeFly?.remove();
    activeFly = null;
    activeRow?.classList.remove("is-open");
    activeRow = null;
  };

  const positionFly = (row: HTMLElement, fly: HTMLElement) => {
    document.body.append(fly);
    const rowRect = row.getBoundingClientRect();
    const menuRect = menu.getBoundingClientRect();
    const flyW = Math.min(300, Math.max(240, fly.offsetWidth || 260));
    let flyLeft = menuRect.right + 6;
    if (flyLeft + flyW > window.innerWidth - 8) {
      flyLeft = menuRect.left - flyW - 6;
    }
    flyLeft = Math.max(8, flyLeft);
    let flyTop = rowRect.top;
    const maxH = Math.min(380, window.innerHeight - 16);
    fly.style.maxHeight = `${maxH}px`;
    if (flyTop + 120 > window.innerHeight - 12) {
      flyTop = Math.max(8, window.innerHeight - 200);
    }
    fly.style.top = `${flyTop}px`;
    fly.style.left = `${flyLeft}px`;
    fly.style.width = `${flyW}px`;
  };

  const showFly = (row: HTMLElement, builder: () => HTMLElement) => {
    if (activeRow === row && activeFly) return;
    hideFly();
    activeRow = row;
    row.classList.add("is-open");
    activeFly = builder();
    activeFly.classList.add("composer-flyout");
    activeFly.addEventListener("mousedown", (e) => e.stopPropagation());
    activeFly.addEventListener("click", (e) => e.stopPropagation());
    positionFly(row, activeFly);
  };

  const actionRow = (
    icon: string,
    label: string,
    opts?: {
      shortcut?: string;
      chevron?: boolean;
      check?: boolean;
      badge?: string;
      action?: () => void;
      fly?: () => HTMLElement;
    },
  ) => {
    const row = el("button", {
      class: `composer-menu-item${opts?.fly ? " has-sub" : ""}`,
      type: "button",
      role: "menuitem",
    });
    row.append(el("span", { class: "cmi-ico" }, [icon]));
    row.append(el("span", { class: "cmi-label" }, [label]));
    if (opts?.shortcut) {
      row.append(el("span", { class: "cmi-shortcut" }, [opts.shortcut]));
    }
    if (opts?.badge) {
      row.append(el("span", { class: "cmi-badge" }, [opts.badge]));
    }
    if (opts?.check) {
      row.append(el("span", { class: "cmi-check" }, ["✓"]));
    }
    if (opts?.chevron) {
      row.append(el("span", { class: "cmi-chev" }, ["›"]));
    }
    if (opts?.fly) {
      row.addEventListener("mouseenter", () => showFly(row, opts.fly!));
      row.addEventListener("click", (e) => {
        e.stopPropagation();
        showFly(row, opts.fly!);
      });
    } else {
      row.addEventListener("mouseenter", () => hideFly());
      row.addEventListener("click", (e) => {
        e.stopPropagation();
        closeAll();
        opts?.action?.();
      });
    }
    return row;
  };

  // --- Flyouts ---
  const projectsFly = () => {
    const fly = el("div", { role: "menu" });
    const list = cb.projects;
    if (list.length === 0) {
      fly.append(el("div", { class: "composer-fly-empty" }, ["No projects yet"]));
    }
    for (const p of list) {
      const row = el("button", { class: "composer-fly-item", type: "button" });
      row.append(el("span", { class: "cmi-ico" }, ["📁"]));
      const mid = el("span", { class: "cmi-fly-copy" });
      mid.append(el("span", { class: "cmi-fly-title" }, [p.name]));
      mid.append(el("span", { class: "cmi-fly-sub" }, ["You"]));
      row.append(mid);
      if (cb.currentProjectId === p.id) {
        row.append(el("span", { class: "cmi-check" }, ["✓"]));
      }
      row.addEventListener("click", () => {
        closeAll();
        cb.onAddToProject(p.id);
      });
      fly.append(row);
    }
    return fly;
  };

  const skillsFly = () => {
    const fly = el("div", { role: "menu" });
    const skillList = cb.skills?.length
      ? cb.skills
      : SKILL_CATALOG.map((s) => ({ id: s.id, name: s.name }));
    for (const s of skillList) {
      const row = el("button", { class: "composer-fly-item", type: "button" });
      row.append(el("span", { class: "cmi-ico" }, ["📋"]));
      row.append(el("span", { class: "cmi-label" }, [s.name]));
      if (cb.tools.activeSkillIds.includes(s.id)) {
        row.append(el("span", { class: "cmi-check" }, ["✓"]));
      }
      row.addEventListener("click", () => {
        closeAll();
        cb.onPickSkill(s.id);
      });
      fly.append(row);
    }
    fly.append(el("div", { class: "composer-menu-sep" }));
    const manage = el("button", { class: "composer-fly-item", type: "button" });
    manage.append(el("span", { class: "cmi-ico" }, ["🧰"]));
    manage.append(el("span", { class: "cmi-label" }, ["Manage skills"]));
    manage.addEventListener("click", () => {
      closeAll();
      cb.onManageSkills();
    });
    fly.append(manage);
    const browse = el("button", { class: "composer-fly-item", type: "button" });
    browse.append(el("span", { class: "cmi-ico" }, ["＋"]));
    browse.append(el("span", { class: "cmi-label" }, ["Browse skills"]));
    browse.addEventListener("click", () => {
      closeAll();
      cb.onBrowseSkills();
    });
    fly.append(browse);
    return fly;
  };

  const connectorsFly = () => {
    const fly = el("div", { role: "menu" });
    const add = el("button", { class: "composer-fly-item", type: "button" });
    add.append(el("span", { class: "cmi-ico" }, ["＋"]));
    add.append(el("span", { class: "cmi-label" }, ["Add connector"]));
    add.append(el("span", { class: "cmi-chev" }, ["›"]));
    add.addEventListener("click", () => {
      closeAll();
      cb.onAddConnector();
    });
    fly.append(add);

    const manage = el("button", { class: "composer-fly-item", type: "button" });
    manage.append(el("span", { class: "cmi-ico" }, ["🧰"]));
    manage.append(el("span", { class: "cmi-label" }, ["Manage connectors"]));
    manage.addEventListener("click", () => {
      closeAll();
      cb.onManageConnectors();
    });
    fly.append(manage);
    fly.append(el("div", { class: "composer-menu-sep" }));

    for (const c of CONNECTOR_CATALOG) {
      const disabled = c.available === false;
      let on = !!cb.tools.connectors[c.id] && !disabled;
      const row = el("div", {
        class: `composer-fly-toggle-row${disabled ? " is-disabled" : ""}`,
      });
      row.append(el("span", { class: "cmi-ico" }, [connectorIcon(c.id)]));
      row.append(el("span", { class: "cmi-label" }, [c.name]));
      const tog = el("button", {
        class: `cmi-switch${on ? " on" : ""}`,
        type: "button",
        "aria-pressed": on ? "true" : "false",
        "aria-label": `Toggle ${c.name}`,
      });
      if (!disabled) {
        tog.addEventListener("click", (e) => {
          e.stopPropagation();
          cb.onToggleConnector(c.id);
          on = !on;
          cb.tools.connectors[c.id] = on;
          tog.classList.toggle("on", on);
          tog.setAttribute("aria-pressed", on ? "true" : "false");
          // Refresh warning badge on Connectors row
          const badge = menu.querySelector(".cmi-badge");
          const n = connectorsWarningCount(cb.tools);
          if (badge) {
            if (n > 0) badge.textContent = `⚠ ${n}`;
            else badge.remove();
          } else if (n > 0) {
            const connectorsRow = Array.from(menu.querySelectorAll(".composer-menu-item")).find(
              (r) => r.textContent?.includes("Connectors"),
            );
            connectorsRow
              ?.querySelector(".cmi-chev")
              ?.before(el("span", { class: "cmi-badge" }, [`⚠ ${n}`]));
          }
        });
      } else {
        tog.disabled = true;
      }
      row.append(tog);
      fly.append(row);
    }

    fly.append(el("div", { class: "composer-menu-sep" }));
    const tools = el("button", { class: "composer-fly-item", type: "button" });
    tools.append(el("span", { class: "cmi-ico" }, ["🔍"]));
    tools.append(el("span", { class: "cmi-label" }, ["Tool access"]));
    tools.append(el("span", { class: "cmi-chev" }, ["›"]));
    tools.addEventListener("click", () => {
      closeAll();
      cb.onToolAccess();
    });
    fly.append(tools);
    return fly;
  };

  const pluginsFly = () => {
    const fly = el("div", { role: "menu" });
    for (const cat of PLUGIN_CATEGORIES) {
      const row = el("button", { class: "composer-fly-item", type: "button" });
      row.append(el("span", { class: "cmi-label" }, [cat.label]));
      row.append(el("span", { class: "cmi-chev" }, ["›"]));
      row.addEventListener("click", () => {
        closeAll();
        cb.onPluginCategory(cat.id);
      });
      fly.append(row);
    }
    fly.append(el("div", { class: "composer-menu-sep" }));
    const manage = el("button", { class: "composer-fly-item", type: "button" });
    manage.append(el("span", { class: "cmi-ico" }, ["🧰"]));
    manage.append(el("span", { class: "cmi-label" }, ["Manage plugins"]));
    manage.addEventListener("click", () => {
      closeAll();
      cb.onManagePlugins();
    });
    fly.append(manage);
    const browse = el("button", { class: "composer-fly-item", type: "button" });
    browse.append(el("span", { class: "cmi-ico" }, ["＋"]));
    browse.append(el("span", { class: "cmi-label" }, ["Browse plugins"]));
    browse.addEventListener("click", () => {
      closeAll();
      cb.onBrowsePlugins();
    });
    fly.append(browse);
    return fly;
  };

  // --- Main rows ---
  menu.append(
    actionRow("📎", "Add files or photos", {
      shortcut: "⌘U",
      action: () => cb.onAddFiles(),
    }),
  );
  menu.append(
    actionRow("📁", "Add to project", {
      chevron: true,
      fly: projectsFly,
    }),
  );
  menu.append(
    actionRow("⌥", "Add from GitHub", {
      action: () => cb.onAddFromGitHub(),
    }),
  );
  menu.append(el("div", { class: "composer-menu-sep" }));

  menu.append(
    actionRow("📋", "Skills", {
      chevron: true,
      fly: skillsFly,
    }),
  );
  const warn = connectorsWarningCount(cb.tools);
  menu.append(
    actionRow("▦", "Connectors", {
      chevron: true,
      badge: warn > 0 ? `⚠ ${warn}` : undefined,
      fly: connectorsFly,
    }),
  );
  menu.append(
    actionRow("✧", "Plugins", {
      chevron: true,
      fly: pluginsFly,
    }),
  );
  menu.append(el("div", { class: "composer-menu-sep" }));

  // Toggle rows stay open and flip the ✓ in place (Claude attach-bar parity)
  const makeToggle = (
    icon: string,
    label: string,
    getOn: () => boolean,
    toggle: () => void,
  ) => {
    const row = el("button", {
      class: "composer-menu-item",
      type: "button",
      role: "menuitemcheckbox",
      "aria-checked": getOn() ? "true" : "false",
    });
    row.append(el("span", { class: "cmi-ico" }, [icon]));
    row.append(el("span", { class: "cmi-label" }, [label]));
    const check = el("span", { class: "cmi-check" }, [getOn() ? "✓" : ""]);
    if (!getOn()) check.style.visibility = "hidden";
    row.append(check);
    row.addEventListener("mouseenter", () => hideFly());
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      toggle();
      const on = getOn();
      check.textContent = on ? "✓" : "";
      check.style.visibility = on ? "visible" : "hidden";
      row.setAttribute("aria-checked", on ? "true" : "false");
    });
    menu.append(row);
  };

  makeToggle(
    "🔎",
    "Research",
    () => cb.tools.research,
    () => {
      cb.onToggleResearch();
      // Parent mutates storage; keep local mirror for getOn
      cb.tools.research = !cb.tools.research;
    },
  );
  makeToggle(
    "🌐",
    "Web search",
    () => cb.tools.webSearch,
    () => {
      cb.onToggleWebSearch();
      cb.tools.webSearch = !cb.tools.webSearch;
    },
  );

  const onDoc = (e: MouseEvent) => {
    const t = e.target as Node;
    if (menu.contains(t) || activeFly?.contains(t) || t === anchor) return;
    closeAll();
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") closeAll();
  };
  document.addEventListener("mousedown", onDoc);
  document.addEventListener("keydown", onKey);
  document.body.append(menu);

  // After layout, re-position above if we used estimate
  requestAnimationFrame(() => {
    const h = menu.offsetHeight;
    let t = rect.top - h - 8;
    if (t < 8) t = Math.min(rect.bottom + 8, window.innerHeight - h - 8);
    menu.style.top = `${Math.max(8, t)}px`;
  });
}

function connectorIcon(id: string): string {
  switch (id) {
    case "cashapp":
      return "$";
    case "figma":
      return "◇";
    case "gmail":
      return "M";
    case "godaddy":
      return "G";
    case "gcal":
      return "31";
    case "gdrive":
      return "△";
    case "granola":
      return "◎";
    case "github":
      return "⌘";
    default:
      return "•";
  }
}
