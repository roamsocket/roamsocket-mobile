/**
 * Skills UX: composer slash chips, hover preview, detail panel, edit modal.
 */
import type { SkillRecord, SkillsStore } from '../client/skills-store.js';
import { skillSlashToken } from '../client/skills-store.js';
import { appConfirm, appPrompt } from './dialogs.js';

type ElFn = <K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs?: Record<string, string>,
  children?: (string | Node)[]
) => HTMLElementTagNameMap[K];

function clearSkillPopovers(): void {
  document
    .querySelectorAll('.skill-hover-preview, .skill-overflow-menu')
    .forEach((n) => n.remove());
}

/**
 * Blue link-style slash chip: /mcp-builder
 * Hover → content preview; click → open skill detail in settings.
 */
export function buildSkillSlashChip(
  skill: SkillRecord,
  el: ElFn,
  opts: {
    onOpen: (skillId: string) => void;
    onRemove?: () => void;
  }
): HTMLElement {
  const chip = el('button', {
    class: 'skill-slash-chip',
    type: 'button',
    'data-skill-id': skill.id,
  });
  chip.append(el('span', { class: 'skill-slash-text' }, [skillSlashToken(skill)]));

  let hideTimer: number | null = null;

  const showPreview = () => {
    clearSkillPopovers();
    const tip = el('div', { class: 'skill-hover-preview', role: 'tooltip' });
    const body = skill.description || skill.instructions;
    const clipped = body.length > 220 ? body.replace(/\s+/g, ' ').trim().slice(0, 217) + '…' : body;
    tip.append(el('div', { class: 'skill-hover-body' }, [clipped]));
    tip.append(el('div', { class: 'skill-hover-label' }, ['Skill']));
    document.body.append(tip);
    const r = chip.getBoundingClientRect();
    const tw = tip.offsetWidth || 260;
    let left = r.right - tw;
    left = Math.max(8, Math.min(left, window.innerWidth - tw - 8));
    let top = r.top - tip.offsetHeight - 10;
    if (top < 8) top = r.bottom + 8;
    tip.style.left = `${left}px`;
    tip.style.top = `${top}px`;
  };

  const scheduleHide = () => {
    if (hideTimer) window.clearTimeout(hideTimer);
    hideTimer = window.setTimeout(() => clearSkillPopovers(), 120);
  };

  chip.addEventListener('mouseenter', () => {
    if (hideTimer) window.clearTimeout(hideTimer);
    showPreview();
  });
  chip.addEventListener('mouseleave', scheduleHide);
  chip.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    clearSkillPopovers();
    opts.onOpen(skill.id);
  });

  if (opts.onRemove) {
    const x = el(
      'span',
      {
        class: 'skill-slash-x',
        role: 'button',
        title: 'Remove',
        'aria-label': 'Remove skill',
      },
      ['×']
    );
    x.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      clearSkillPopovers();
      opts.onRemove!();
    });
    chip.append(x);
  }

  return chip;
}

export function openSkillDetailModal(
  skillId: string,
  skills: SkillsStore,
  el: ElFn,
  opts: {
    onChanged: () => void;
    onTryInChat?: (skillId: string) => void;
  }
): void {
  document.querySelectorAll('.skill-detail-backdrop').forEach((n) => n.remove());
  const skill = skills.get(skillId);
  if (!skill) return;

  const backdrop = el('div', { class: 'modal-backdrop skill-detail-backdrop' });
  const modal = el('div', { class: 'modal skill-detail-modal' });

  const head = el('div', { class: 'skill-detail-head' });
  const back = el('button', { class: 'skill-back-btn', type: 'button' }, ['← Skills']);
  const closeX = el('button', { class: 'modal-x', type: 'button', 'aria-label': 'Close' }, ['×']);
  head.append(back, closeX);
  modal.append(head);

  const titleRow = el('div', { class: 'skill-title-row' });
  const titleBlock = el('div', { class: 'skill-title-block' });
  const nameRow = el('div', { class: 'skill-name-row' });
  nameRow.append(el('h2', { class: 'skill-detail-name' }, [skill.name]));
  const infoBtn = el(
    'button',
    {
      class: 'skill-info-btn',
      type: 'button',
      title: 'Skill info',
      'aria-label': 'Skill info',
    },
    ['ⓘ']
  );
  nameRow.append(infoBtn);
  titleBlock.append(nameRow);
  titleBlock.append(el('div', { class: 'skill-by' }, [`by ${skill.author}`]));
  titleBlock.append(el('div', { class: 'skill-desc-line' }, [skill.description]));
  titleRow.append(titleBlock);

  const actions = el('div', { class: 'skill-title-actions' });
  const shareLab = el('label', { class: 'skill-share' });
  shareLab.append(document.createTextNode('Share'));
  const share = el('input', {
    type: 'checkbox',
    class: 'skill-share-toggle',
  }) as HTMLInputElement;
  share.checked = skill.share;
  share.addEventListener('change', () => {
    skills.update(skill.id, { share: share.checked });
    opts.onChanged();
  });
  shareLab.append(share);
  const more = el(
    'button',
    {
      class: 'icon-btn skill-more-btn',
      type: 'button',
      'aria-label': 'More',
    },
    ['⋯']
  );
  actions.append(shareLab, more);
  titleRow.append(actions);
  modal.append(titleRow);

  infoBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    clearSkillPopovers();
    const tip = el('div', { class: 'skill-hover-preview skill-info-pop' });
    tip.append(
      el('div', { class: 'skill-info-grid' }, [
        el('div', {}, [
          el('div', { class: 'skill-info-k' }, ['Last updated']),
          el('div', { class: 'skill-info-v' }, [skill.lastUpdated]),
        ]),
        el('div', {}, [
          el('div', { class: 'skill-info-k' }, ['Trigger']),
          el('div', { class: 'skill-info-v' }, [skill.trigger]),
        ]),
      ])
    );
    tip.append(el('div', { class: 'skill-info-k', style: 'margin-top:8px' }, ['Description']));
    tip.append(el('div', { class: 'skill-info-v' }, [skill.description]));
    document.body.append(tip);
    const r = infoBtn.getBoundingClientRect();
    tip.style.left = `${Math.min(r.left, window.innerWidth - 280)}px`;
    tip.style.top = `${r.bottom + 6}px`;
    const dismiss = (ev: MouseEvent) => {
      if (!tip.contains(ev.target as Node)) {
        tip.remove();
        document.removeEventListener('mousedown', dismiss);
      }
    };
    document.addEventListener('mousedown', dismiss);
  });

  more.addEventListener('click', (e) => {
    e.stopPropagation();
    clearSkillPopovers();
    const menu = el('div', { class: 'skill-overflow-menu', role: 'menu' });
    const item = (label: string, action: () => void, danger = false) => {
      const b = el(
        'button',
        {
          class: `skill-overflow-item${danger ? ' danger' : ''}`,
          type: 'button',
          role: 'menuitem',
        },
        [label]
      );
      b.addEventListener('click', () => {
        menu.remove();
        action();
      });
      return b;
    };
    menu.append(
      item('Try in chat', () => {
        close();
        opts.onTryInChat?.(skill.id);
      })
    );
    menu.append(
      item('Edit', () => {
        openEditSkillModal(skill.id, skills, el, {
          onSaved: () => {
            opts.onChanged();
            close();
            openSkillDetailModal(skill.id, skills, el, opts);
          },
        });
      })
    );
    menu.append(
      item('Edit with Claude', () => {
        close();
        opts.onTryInChat?.(skill.id);
      })
    );
    menu.append(
      item('Replace', () => {
        void (async () => {
          const text = await appPrompt({
            title: 'Replace skill content',
            message: 'Paste replacement skill markdown / instructions.',
            multiline: true,
            defaultValue: skill.instructions,
            okLabel: 'Replace',
            required: true,
          });
          if (text == null) return;
          skills.update(skill.id, { instructions: text });
          opts.onChanged();
          close();
          openSkillDetailModal(skill.id, skills, el, opts);
        })();
      })
    );
    menu.append(
      item('Download', () => {
        const blob = new Blob(
          [
            `---\nname: ${skill.name}\ndescription: ${skill.description}\n---\n\n${skill.instructions}\n`,
          ],
          { type: 'text/markdown' }
        );
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = `${skill.name}.md`;
        a.click();
        URL.revokeObjectURL(a.href);
      })
    );
    menu.append(
      item(
        'Uninstall',
        () => {
          void (async () => {
            const ok = await appConfirm({
              title: 'Uninstall skill',
              message: `Uninstall skill “${skill.name}”?`,
              okLabel: 'Uninstall',
              danger: true,
            });
            if (!ok) return;
            skills.uninstall(skill.id);
            opts.onChanged();
            close();
          })();
        },
        true
      )
    );
    document.body.append(menu);
    const r = more.getBoundingClientRect();
    menu.style.top = `${r.bottom + 4}px`;
    menu.style.left = `${Math.min(r.right - 200, window.innerWidth - 210)}px`;
    const dismiss = (ev: MouseEvent) => {
      if (!menu.contains(ev.target as Node) && ev.target !== more) {
        menu.remove();
        document.removeEventListener('mousedown', dismiss);
      }
    };
    document.addEventListener('mousedown', dismiss);
  });

  const body = el('div', { class: 'skill-detail-body' });
  body.append(renderSkillMarkdown(skill.instructions, el));
  modal.append(body);

  const close = () => {
    clearSkillPopovers();
    backdrop.remove();
  };
  back.addEventListener('click', close);
  closeX.addEventListener('click', close);
  backdrop.addEventListener('click', (e) => {
    if (e.target === backdrop) close();
  });

  backdrop.append(modal);
  document.body.append(backdrop);
}

export function openEditSkillModal(
  skillId: string,
  skills: SkillsStore,
  el: ElFn,
  opts: { onSaved: () => void }
): void {
  const skill = skills.get(skillId);
  if (!skill) return;

  const backdrop = el('div', { class: 'modal-backdrop project-modal-backdrop' });
  const modal = el('div', { class: 'modal project-modal skill-edit-modal' });
  const head = el('div', { class: 'project-modal-head' });
  head.append(el('h3', {}, ['Edit skill instructions']));
  const closeX = el('button', { class: 'modal-x', type: 'button' }, ['×']);
  head.append(closeX);
  modal.append(head);

  modal.append(el('label', { class: 'skill-field-label' }, ['Skill name']));
  const nameIn = el('input', {
    class: 'project-modal-input',
    type: 'text',
    value: skill.name,
  }) as HTMLInputElement;
  nameIn.value = skill.name;
  modal.append(nameIn);

  modal.append(el('label', { class: 'skill-field-label' }, ['Description']));
  const descIn = el('textarea', {
    class: 'project-modal-textarea',
    rows: '2',
  }) as HTMLTextAreaElement;
  descIn.value = skill.description;
  modal.append(descIn);

  modal.append(el('label', { class: 'skill-field-label' }, ['Instructions']));
  const instIn = el('textarea', {
    class: 'project-modal-textarea skill-instructions-ta',
    rows: '14',
  }) as HTMLTextAreaElement;
  instIn.value = skill.instructions;
  modal.append(instIn);

  const actions = el('div', { class: 'project-modal-actions' });
  const cancel = el('button', { class: 'ghost-btn', type: 'button' }, ['Cancel']);
  const save = el('button', { class: 'primary-btn', type: 'button' }, ['Save']);
  actions.append(cancel, save);
  modal.append(actions);

  const close = () => backdrop.remove();
  closeX.addEventListener('click', close);
  cancel.addEventListener('click', close);
  save.addEventListener('click', () => {
    skills.update(skill.id, {
      name: nameIn.value.trim() || skill.name,
      description: descIn.value.trim(),
      instructions: instIn.value,
    });
    close();
    opts.onSaved();
  });
  backdrop.addEventListener('click', (e) => {
    if (e.target === backdrop) close();
  });
  backdrop.append(modal);
  document.body.append(backdrop);
  queueMicrotask(() => nameIn.focus());
}

/** Minimal markdown-ish render for skill body (headings, lists, code spans). */
function renderSkillMarkdown(md: string, el: ElFn): HTMLElement {
  const wrap = el('div', { class: 'skill-md' });
  const lines = md.split(/\n/);
  let list: HTMLElement | null = null;

  const flushList = () => {
    list = null;
  };

  for (const raw of lines) {
    const line = raw;
    if (/^#\s+/.test(line)) {
      flushList();
      wrap.append(el('h3', {}, [line.replace(/^#\s+/, '')]));
      continue;
    }
    if (/^##\s+/.test(line)) {
      flushList();
      wrap.append(el('h4', {}, [line.replace(/^##\s+/, '')]));
      continue;
    }
    if (/^[-*]\s+/.test(line)) {
      if (!list) {
        list = el('ul', {});
        wrap.append(list);
      }
      list.append(el('li', {}, [line.replace(/^[-*]\s+/, '')]));
      continue;
    }
    if (!line.trim()) {
      flushList();
      continue;
    }
    flushList();
    // Blockquote
    if (line.startsWith('>')) {
      wrap.append(el('blockquote', {}, [line.replace(/^>\s?/, '')]));
      continue;
    }
    wrap.append(el('p', {}, [line]));
  }
  return wrap;
}
