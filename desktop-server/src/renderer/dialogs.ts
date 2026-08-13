/**
 * Electron-safe dialogs.
 *
 * Chromium/Electron does not implement window.prompt() (and confirm/alert
 * are unreliable in some builds). These helpers use the existing modal
 * chrome so settings, keys, code, and context menus work in the shell.
 */

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: (string | Node)[] = []
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else node.setAttribute(k, v);
  }
  for (const c of children) {
    node.append(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
}

type Shell = {
  body: HTMLElement;
  actions: HTMLElement;
  /** Call once with the settle function (removes DOM + resolves). */
  onCancel: (fn: () => void) => void;
  remove: () => void;
};

function openShell(title: string, opts?: { wide?: boolean; className?: string }): Shell {
  const backdrop = el('div', {
    class: 'modal-backdrop project-modal-backdrop dialog-backdrop',
  });
  const modal = el('div', {
    class: `modal project-modal dialog-modal${opts?.wide ? ' dialog-modal-wide' : ''}${
      opts?.className ? ` ${opts.className}` : ''
    }`,
    role: 'dialog',
    'aria-modal': 'true',
  });
  const head = el('div', { class: 'project-modal-head' });
  head.append(el('h3', {}, [title]));
  const closeX = el('button', { class: 'modal-x', type: 'button', 'aria-label': 'Close' }, ['×']);
  head.append(closeX);
  modal.append(head);

  const body = el('div', { class: 'dialog-body' });
  modal.append(body);

  const actions = el('div', { class: 'project-modal-actions' });
  modal.append(actions);

  backdrop.append(modal);
  document.body.append(backdrop);

  let cancelFn: (() => void) | null = null;
  let removed = false;

  const remove = () => {
    if (removed) return;
    removed = true;
    document.removeEventListener('keydown', onKey, true);
    backdrop.remove();
  };

  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      cancelFn?.();
    }
  };
  document.addEventListener('keydown', onKey, true);

  closeX.addEventListener('click', () => cancelFn?.());
  backdrop.addEventListener('click', (e) => {
    if (e.target === backdrop) cancelFn?.();
  });

  return {
    body,
    actions,
    onCancel: (fn) => {
      cancelFn = fn;
    },
    remove,
  };
}

// ---------------------------------------------------------------------------
// Prompt (text / password / multiline)
// ---------------------------------------------------------------------------

export type AppPromptOptions = {
  title: string;
  message?: string;
  defaultValue?: string;
  placeholder?: string;
  /** Mask input (API keys, tokens). */
  password?: boolean;
  multiline?: boolean;
  okLabel?: string;
  cancelLabel?: string;
  /** If true, OK stays disabled until non-empty. */
  required?: boolean;
};

/** Returns the field value (may be empty), or null if cancelled. */
export function appPrompt(opts: AppPromptOptions): Promise<string | null> {
  return new Promise((resolve) => {
    const shell = openShell(opts.title);
    let settled = false;
    const finish = (value: string | null) => {
      if (settled) return;
      settled = true;
      shell.remove();
      resolve(value);
    };
    shell.onCancel(() => finish(null));

    if (opts.message) {
      shell.body.append(el('p', { class: 'settings-hint dialog-message' }, [opts.message]));
    }

    let field: HTMLInputElement | HTMLTextAreaElement;
    if (opts.multiline) {
      field = el('textarea', {
        class: 'project-modal-textarea',
        rows: '8',
        placeholder: opts.placeholder ?? '',
      }) as HTMLTextAreaElement;
    } else {
      field = el('input', {
        class: 'project-modal-input',
        type: opts.password ? 'password' : 'text',
        placeholder: opts.placeholder ?? '',
        autocomplete: 'off',
        spellcheck: 'false',
      }) as HTMLInputElement;
    }
    field.value = opts.defaultValue ?? '';
    shell.body.append(field);

    const cancel = el('button', { class: 'ghost-btn', type: 'button' }, [
      opts.cancelLabel ?? 'Cancel',
    ]);
    const ok = el('button', { class: 'primary-btn', type: 'button' }, [
      opts.okLabel ?? 'OK',
    ]) as HTMLButtonElement;

    const submit = () => {
      if (opts.required && !field.value.trim()) return;
      finish(field.value);
    };

    const syncOk = () => {
      if (opts.required) ok.disabled = !field.value.trim();
    };
    field.addEventListener('input', syncOk);
    syncOk();

    cancel.addEventListener('click', () => finish(null));
    ok.addEventListener('click', submit);
    field.addEventListener('keydown', (ev) => {
      const e = ev as KeyboardEvent;
      if (e.key === 'Enter' && !opts.multiline) {
        e.preventDefault();
        submit();
      }
      if (e.key === 'Enter' && opts.multiline && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        submit();
      }
    });

    shell.actions.append(cancel, ok);
    queueMicrotask(() => {
      field.focus();
      if (!opts.multiline && 'select' in field) {
        try {
          field.select();
        } catch {
          /* ignore */
        }
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Confirm
// ---------------------------------------------------------------------------

export type AppConfirmOptions = {
  title: string;
  message: string;
  okLabel?: string;
  cancelLabel?: string;
  /** Styles OK as destructive. */
  danger?: boolean;
};

export function appConfirm(opts: AppConfirmOptions): Promise<boolean> {
  return new Promise((resolve) => {
    const shell = openShell(opts.title);
    let settled = false;
    const finish = (value: boolean) => {
      if (settled) return;
      settled = true;
      shell.remove();
      resolve(value);
    };
    shell.onCancel(() => finish(false));

    shell.body.append(el('p', { class: 'settings-hint dialog-message' }, [opts.message]));

    const cancel = el('button', { class: 'ghost-btn', type: 'button' }, [
      opts.cancelLabel ?? 'Cancel',
    ]);
    const ok = el(
      'button',
      {
        class: opts.danger ? 'danger-btn' : 'primary-btn',
        type: 'button',
      },
      [opts.okLabel ?? 'OK']
    );

    cancel.addEventListener('click', () => finish(false));
    ok.addEventListener('click', () => finish(true));
    shell.actions.append(cancel, ok);
    queueMicrotask(() => ok.focus());
  });
}

// ---------------------------------------------------------------------------
// Alert
// ---------------------------------------------------------------------------

export type AppAlertOptions = {
  title?: string;
  message: string;
  okLabel?: string;
};

export function appAlert(opts: AppAlertOptions): Promise<void> {
  return new Promise((resolve) => {
    const shell = openShell(opts.title ?? 'Notice');
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      shell.remove();
      resolve();
    };
    shell.onCancel(finish);

    shell.body.append(el('p', { class: 'settings-hint dialog-message' }, [opts.message]));
    const ok = el('button', { class: 'primary-btn', type: 'button' }, [opts.okLabel ?? 'OK']);
    ok.addEventListener('click', finish);
    shell.actions.append(ok);
    queueMicrotask(() => ok.focus());
  });
}

// ---------------------------------------------------------------------------
// Choice list (context actions)
// ---------------------------------------------------------------------------

export type AppChoiceOption = {
  id: string;
  label: string;
  sub?: string;
  danger?: boolean;
};

export type AppChoiceOptions = {
  title: string;
  message?: string;
  choices: AppChoiceOption[];
};

/** Returns selected choice id, or null if cancelled. */
export function appChoice(opts: AppChoiceOptions): Promise<string | null> {
  return new Promise((resolve) => {
    const shell = openShell(opts.title);
    let settled = false;
    const finish = (id: string | null) => {
      if (settled) return;
      settled = true;
      shell.remove();
      resolve(id);
    };
    shell.onCancel(() => finish(null));

    if (opts.message) {
      shell.body.append(el('p', { class: 'settings-hint dialog-message' }, [opts.message]));
    }
    const list = el('div', { class: 'dialog-choice-list' });
    for (const c of opts.choices) {
      const btn = el('button', {
        class: `modal-option dialog-choice${c.danger ? ' dialog-choice-danger' : ''}`,
        type: 'button',
      });
      const left = el('div', {});
      left.append(el('div', {}, [c.label]));
      if (c.sub) left.append(el('div', { class: 'sub' }, [c.sub]));
      btn.append(left);
      btn.addEventListener('click', () => finish(c.id));
      list.append(btn);
    }
    shell.body.append(list);

    const cancel = el('button', { class: 'ghost-btn', type: 'button' }, ['Cancel']);
    cancel.addEventListener('click', () => finish(null));
    shell.actions.append(cancel);
    queueMicrotask(() => {
      const first = list.querySelector('button') as HTMLButtonElement | null;
      first?.focus();
    });
  });
}

// ---------------------------------------------------------------------------
// Multi-field form
// ---------------------------------------------------------------------------

export type AppFormField = {
  name: string;
  label: string;
  defaultValue?: string;
  placeholder?: string;
  password?: boolean;
  required?: boolean;
  type?: 'text' | 'password' | 'textarea' | 'select';
  options?: Array<{ value: string; label: string }>;
  hint?: string;
};

export type AppFormOptions = {
  title: string;
  message?: string;
  fields: AppFormField[];
  okLabel?: string;
  cancelLabel?: string;
};

/** Returns field name → value map, or null if cancelled. */
export function appForm(opts: AppFormOptions): Promise<Record<string, string> | null> {
  return new Promise((resolve) => {
    const shell = openShell(opts.title, { wide: opts.fields.length > 3 });
    let settled = false;
    const finish = (value: Record<string, string> | null) => {
      if (settled) return;
      settled = true;
      shell.remove();
      resolve(value);
    };
    shell.onCancel(() => finish(null));

    if (opts.message) {
      shell.body.append(el('p', { class: 'settings-hint dialog-message' }, [opts.message]));
    }

    const controls = new Map<string, HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>();

    for (const f of opts.fields) {
      const wrap = el('div', { class: 'dialog-field' });
      wrap.append(el('label', { class: 'dialog-field-label' }, [f.label]));
      let control: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement;
      if (f.type === 'select' && f.options) {
        control = el('select', { class: 'dialog-select' }) as HTMLSelectElement;
        for (const o of f.options) {
          const opt = el('option', { value: o.value }, [o.label]) as HTMLOptionElement;
          if (o.value === (f.defaultValue ?? f.options[0]?.value)) opt.selected = true;
          control.append(opt);
        }
      } else if (f.type === 'textarea') {
        control = el('textarea', {
          class: 'project-modal-textarea',
          rows: '5',
          placeholder: f.placeholder ?? '',
        }) as HTMLTextAreaElement;
        control.value = f.defaultValue ?? '';
      } else {
        control = el('input', {
          class: 'project-modal-input',
          type: f.password || f.type === 'password' ? 'password' : 'text',
          placeholder: f.placeholder ?? '',
          autocomplete: 'off',
          spellcheck: 'false',
        }) as HTMLInputElement;
        control.value = f.defaultValue ?? '';
      }
      wrap.append(control);
      if (f.hint) wrap.append(el('p', { class: 'settings-hint dialog-field-hint' }, [f.hint]));
      shell.body.append(wrap);
      controls.set(f.name, control);
    }

    const cancel = el('button', { class: 'ghost-btn', type: 'button' }, [
      opts.cancelLabel ?? 'Cancel',
    ]);
    const ok = el('button', { class: 'primary-btn', type: 'button' }, [opts.okLabel ?? 'Save']);

    const read = (): Record<string, string> | null => {
      const out: Record<string, string> = {};
      for (const f of opts.fields) {
        const c = controls.get(f.name)!;
        const v = c.value;
        if (f.required && !v.trim()) {
          c.focus();
          return null;
        }
        out[f.name] = v;
      }
      return out;
    };

    cancel.addEventListener('click', () => finish(null));
    ok.addEventListener('click', () => {
      const v = read();
      if (v) finish(v);
    });

    for (const c of controls.values()) {
      if (c instanceof HTMLTextAreaElement) continue;
      c.addEventListener('keydown', (ev) => {
        const e = ev as KeyboardEvent;
        if (e.key === 'Enter') {
          e.preventDefault();
          const v = read();
          if (v) finish(v);
        }
      });
    }

    shell.actions.append(cancel, ok);
    queueMicrotask(() => {
      const first = opts.fields[0] && controls.get(opts.fields[0].name);
      first?.focus();
    });
  });
}
