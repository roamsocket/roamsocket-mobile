/**
 * Interactive Metal / MLX model browser for the coding agent TUI.
 * Family list → model list; download / use / delete without leaving the app.
 */
import React, { useEffect, useMemo, useState } from "react";
import { Box, Text, useInput } from "ink";
import {
  getMetalBrowserSnapshot,
  type MetalBrowserFamily,
  type MetalBrowserModel,
} from "../metal-cli.js";
import { theme } from "./theme.js";

export interface MetalBrowserProps {
  width: number;
  height: number;
  /** Current agent model id when provider is localMetal. */
  activeHubID: string | null;
  /** Progress / busy line while download or runtime install runs. */
  busyLabel: string | null;
  /** Bump to re-read the store after download/delete. */
  refreshKey: number;
  onClose: () => void;
  onDownload: (hubID: string, displayName: string) => void;
  onCancelDownload: () => void;
  onUse: (hubID: string, displayName: string) => void;
  onDelete: (hubID: string, displayName: string) => void;
  onInstallRuntime: () => void;
}

type RootItem =
  | { kind: "runtime" }
  | { kind: "on_device_header" }
  | { kind: "model"; model: MetalBrowserModel }
  | { kind: "section"; title: string }
  | { kind: "family"; family: MetalBrowserFamily };

type View =
  | { level: "root"; cursor: number }
  | { level: "family"; family: string; cursor: number };

function clamp(i: number, n: number): number {
  if (n <= 0) return 0;
  return Math.max(0, Math.min(n - 1, i));
}

export function MetalBrowser({
  width,
  height,
  activeHubID,
  busyLabel,
  refreshKey,
  onClose,
  onDownload,
  onCancelDownload,
  onUse,
  onDelete,
  onInstallRuntime,
}: MetalBrowserProps) {
  const [view, setView] = useState<View>({ level: "root", cursor: 0 });

  const snap = useMemo(() => getMetalBrowserSnapshot(), [refreshKey]);

  const rootItems = useMemo((): RootItem[] => {
    const items: RootItem[] = [{ kind: "runtime" }];
    if (snap.onDevice.length > 0) {
      items.push({ kind: "on_device_header" });
      for (const m of snap.onDevice) {
        items.push({ kind: "model", model: m });
      }
    }
    const featured = snap.families.filter((f) => f.group === "featured");
    const more = snap.families.filter((f) => f.group === "more");
    const experimental = snap.families.filter((f) => f.group === "experimental");
    const legacy = snap.families.filter((f) => f.group === "legacy");

    if (featured.length) {
      items.push({ kind: "section", title: "Featured" });
      for (const f of featured) items.push({ kind: "family", family: f });
    }
    if (more.length) {
      items.push({ kind: "section", title: "More models" });
      for (const f of more) items.push({ kind: "family", family: f });
    }
    if (experimental.length) {
      items.push({ kind: "section", title: "Experimental" });
      for (const f of experimental) items.push({ kind: "family", family: f });
    }
    if (legacy.length) {
      items.push({ kind: "section", title: "Legacy" });
      for (const f of legacy) items.push({ kind: "family", family: f });
    }
    return items;
  }, [snap]);

  const familyModels = useMemo((): MetalBrowserModel[] => {
    if (view.level !== "family") return [];
    const fam = snap.families.find((f) => f.name === view.family);
    return fam?.models ?? [];
  }, [snap, view]);

  const selectableRoot = useMemo(
    () =>
      rootItems
        .map((item, index) => ({ item, index }))
        .filter(
          ({ item }) =>
            item.kind === "runtime" || item.kind === "family" || item.kind === "model",
        ),
    [rootItems],
  );

  // Keep cursor valid when the list refreshes after download/delete.
  useEffect(() => {
    if (view.level === "root") {
      const max = Math.max(0, selectableRoot.length - 1);
      if (view.cursor > max) setView({ level: "root", cursor: max });
    } else {
      const max = Math.max(0, familyModels.length - 1);
      if (view.cursor > max) {
        setView({ level: "family", family: view.family, cursor: max });
      }
    }
  }, [view, selectableRoot.length, familyModels.length]);

  const selectedRoot = selectableRoot[view.level === "root" ? view.cursor : -1];
  const selectedModel =
    view.level === "family"
      ? familyModels[view.cursor] ?? null
      : selectedRoot?.item.kind === "model"
        ? selectedRoot.item.model
        : null;

  useInput((input, key) => {
    // Ctrl+C is handled by App (quit). Ignore here so both hooks don't fight.
    if (key.ctrl && input === "c") return;

    if (input === "q" || (key.escape && view.level === "root")) {
      onClose();
      return;
    }

    if (key.escape || key.leftArrow || input === "h") {
      if (view.level === "family") {
        // Restore cursor near this family on root
        const famIdx = selectableRoot.findIndex(
          (r) => r.item.kind === "family" && r.item.family.name === view.family,
        );
        setView({ level: "root", cursor: famIdx >= 0 ? famIdx : 0 });
      } else {
        onClose();
      }
      return;
    }

    if (key.upArrow || input === "k") {
      if (view.level === "root") {
        setView({
          level: "root",
          cursor: clamp(view.cursor - 1, selectableRoot.length),
        });
      } else {
        setView({
          level: "family",
          family: view.family,
          cursor: clamp(view.cursor - 1, familyModels.length),
        });
      }
      return;
    }

    if (key.downArrow || input === "j") {
      if (view.level === "root") {
        setView({
          level: "root",
          cursor: clamp(view.cursor + 1, selectableRoot.length),
        });
      } else {
        setView({
          level: "family",
          family: view.family,
          cursor: clamp(view.cursor + 1, familyModels.length),
        });
      }
      return;
    }

    if (input === "i") {
      onInstallRuntime();
      return;
    }

    if (input === "d" && selectedModel) {
      if (!selectedModel.downloaded) {
        onDownload(selectedModel.hubID, selectedModel.displayName);
      }
      return;
    }

    if (input === "c" && busyLabel) {
      onCancelDownload();
      return;
    }

    if (input === "u" && selectedModel) {
      if (selectedModel.downloaded) {
        onUse(selectedModel.hubID, selectedModel.displayName);
      }
      return;
    }

    if ((input === "x" || input === "X") && selectedModel) {
      if (selectedModel.downloaded) {
        onDelete(selectedModel.hubID, selectedModel.displayName);
      }
      return;
    }

    if (key.return || key.rightArrow || input === "l") {
      if (view.level === "root" && selectedRoot) {
        const it = selectedRoot.item;
        if (it.kind === "runtime") {
          onInstallRuntime();
          return;
        }
        if (it.kind === "family") {
          setView({ level: "family", family: it.family.name, cursor: 0 });
          return;
        }
        if (it.kind === "model") {
          activateModel(it.model);
          return;
        }
      }
      if (view.level === "family" && selectedModel) {
        activateModel(selectedModel);
      }
    }
  });

  function activateModel(m: MetalBrowserModel) {
    if (m.downloaded) onUse(m.hubID, m.displayName);
    else onDownload(m.hubID, m.displayName);
  }

  // Visible window for long lists
  const headerLines = 5;
  const footerLines = 3;
  const bodyH = Math.max(4, height - headerLines - footerLines);

  let body: React.ReactNode;
  if (view.level === "root") {
    body = (
      <RootList
        items={rootItems}
        selectable={selectableRoot}
        cursor={view.cursor}
        activeHubID={activeHubID}
        bodyH={bodyH}
        width={width}
      />
    );
  } else {
    body = (
      <ModelList
        family={view.family}
        models={familyModels}
        cursor={view.cursor}
        activeHubID={activeHubID}
        bodyH={bodyH}
        width={width}
        blurb={snap.families.find((f) => f.name === view.family)?.blurb ?? ""}
      />
    );
  }

  const title =
    view.level === "root"
      ? "Metal models"
      : `Metal · ${view.family}`;

  return (
    <Box flexDirection="column" width={width} height={height} overflow="hidden">
      <Box
        borderStyle="single"
        borderColor={theme.border}
        paddingX={1}
        flexShrink={0}
        width="100%"
      >
        <Text>
          <Text color={theme.accent} bold>
            {title}
          </Text>
          <Text color={theme.muted}>
            {" "}
            · {snap.onDevice.length} on device · {snap.storageLabel}
          </Text>
        </Text>
      </Box>
      {busyLabel ? (
        <Box paddingX={1} flexShrink={0}>
          <Text color={theme.warning}>{busyLabel} · press c to cancel</Text>
        </Box>
      ) : (
        <Box paddingX={1} flexShrink={0}>
          <Text color={theme.muted}>
            Store {shortPath(snap.storeRoot)} · ↑↓ move · Enter open/use · d download · u use · x
            delete · i runtime · Esc back
          </Text>
        </Box>
      )}
      <Box flexDirection="column" flexGrow={1} minHeight={0} overflow="hidden" paddingX={1}>
        {body}
      </Box>
      <Box paddingX={1} flexShrink={0}>
        <Text color={theme.muted}>
          {selectedModel
            ? detailLine(selectedModel, activeHubID)
            : view.level === "root" && selectedRoot?.item.kind === "runtime"
              ? "Enter / i — install or reinstall managed Python + mlx-lm"
              : view.level === "root" && selectedRoot?.item.kind === "family"
                ? `Enter — browse ${selectedRoot.item.family.name} (${selectedRoot.item.family.models.length} models)`
                : "Select a family or model"}
        </Text>
      </Box>
    </Box>
  );
}

function detailLine(m: MetalBrowserModel, activeHubID: string | null): string {
  const bits = [
    m.downloaded ? "✓ downloaded" : "not downloaded",
    m.approxSize,
    activeHubID === m.hubID ? "active" : "",
    m.hubID,
  ].filter(Boolean);
  return bits.join(" · ");
}

function shortPath(p: string): string {
  const home = process.env.HOME;
  if (home && p.startsWith(home)) return `~${p.slice(home.length)}`;
  return p;
}

function RootList({
  items,
  selectable,
  cursor,
  activeHubID,
  bodyH,
  width,
}: {
  items: RootItem[];
  selectable: Array<{ item: RootItem; index: number }>;
  cursor: number;
  activeHubID: string | null;
  bodyH: number;
  width: number;
}) {
  const selectedAbs = selectable[cursor]?.index ?? 0;
  // Window around the absolute row index
  const start = Math.max(0, Math.min(selectedAbs - Math.floor(bodyH / 2), items.length - bodyH));
  const slice = items.slice(start, start + bodyH);

  return (
    <Box flexDirection="column">
      {slice.map((item, i) => {
        const abs = start + i;
        const selIdx = selectable.findIndex((s) => s.index === abs);
        const active = selIdx === cursor;
        return (
          <RootRow
            key={rowKey(item, abs)}
            item={item}
            active={active}
            activeHubID={activeHubID}
            width={width}
          />
        );
      })}
    </Box>
  );
}

function rowKey(item: RootItem, abs: number): string {
  switch (item.kind) {
    case "runtime":
      return "runtime";
    case "on_device_header":
      return "on_device";
    case "section":
      return `sec-${item.title}`;
    case "family":
      return `fam-${item.family.name}`;
    case "model":
      return `mod-${item.model.hubID}`;
    default:
      return String(abs);
  }
}

function RootRow({
  item,
  active,
  activeHubID,
  width,
}: {
  item: RootItem;
  active: boolean;
  activeHubID: string | null;
  width: number;
}) {
  const marker = active ? "› " : "  ";
  const color = active ? theme.accent : theme.text;

  if (item.kind === "runtime") {
    return (
      <Text color={active ? theme.accent : theme.warning} bold={active} wrap="truncate">
        {marker}Runtime — install / reinstall Python + mlx-lm
      </Text>
    );
  }
  if (item.kind === "on_device_header") {
    return (
      <Text color={theme.muted} bold>
        On this device
      </Text>
    );
  }
  if (item.kind === "section") {
    return (
      <Text color={theme.muted} bold>
        {item.title}
      </Text>
    );
  }
  if (item.kind === "family") {
    const f = item.family;
    const mark =
      f.downloadedCount === f.models.length && f.models.length > 0
        ? "✓"
        : f.downloadedCount > 0
          ? "◑"
          : "·";
    return (
      <Text color={color} bold={active} wrap="truncate">
        {marker}
        {mark} {f.name}
        <Text color={theme.muted}>
          {" "}
          · {f.models.length} model{f.models.length === 1 ? "" : "s"}
          {f.downloadedCount > 0 ? ` · ${f.downloadedCount}↓` : ""}
        </Text>
      </Text>
    );
  }
  // model (on-device section)
  return (
    <ModelRow
      model={item.model}
      active={active}
      activeHubID={activeHubID}
      indent
      width={width}
    />
  );
}

function ModelList({
  family,
  models,
  cursor,
  activeHubID,
  bodyH,
  width,
  blurb,
}: {
  family: string;
  models: MetalBrowserModel[];
  cursor: number;
  activeHubID: string | null;
  bodyH: number;
  width: number;
  blurb: string;
}) {
  if (models.length === 0) {
    return <Text color={theme.muted}>No models in {family}.</Text>;
  }
  const start = Math.max(0, Math.min(cursor - Math.floor(bodyH / 2), models.length - bodyH));
  const slice = models.slice(start, start + bodyH);
  return (
    <Box flexDirection="column">
      {blurb ? (
        <Text color={theme.muted} wrap="truncate">
          {blurb}
        </Text>
      ) : null}
      {slice.map((m, i) => {
        const abs = start + i;
        return (
          <ModelRow
            key={m.hubID}
            model={m}
            active={abs === cursor}
            activeHubID={activeHubID}
            width={width}
          />
        );
      })}
    </Box>
  );
}

function ModelRow({
  model,
  active,
  activeHubID,
  indent,
  width,
}: {
  model: MetalBrowserModel;
  active: boolean;
  activeHubID: string | null;
  indent?: boolean;
  width: number;
}) {
  void width;
  const marker = active ? "› " : "  ";
  const pad = indent ? "  " : "";
  const dl = model.downloaded ? "✓" : "·";
  const isActive = activeHubID === model.hubID;
  return (
    <Text
      color={active ? theme.accent : isActive ? theme.success : theme.text}
      bold={active || isActive}
      wrap="truncate"
    >
      {pad}
      {marker}
      {dl} {model.displayName}
      <Text color={theme.muted}>
        {model.approxSize ? ` · ${model.approxSize}` : ""}
        {isActive ? " · active" : ""}
        {model.tags.includes("thinking") ? " · thinking" : ""}
        {model.tags.includes("best") ? " · best" : ""}
      </Text>
    </Text>
  );
}
