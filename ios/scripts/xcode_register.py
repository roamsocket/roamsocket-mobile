#!/usr/bin/env python3
"""
Auto-register newly created Swift files in ios/ into the Xcode project's
project.pbxproj so Xcode sees them on next open.

Designed to run as a Claude Code PostToolUse hook. Reads the hook payload on
stdin, scans for .swift / .m / .mm / .h / .storyboard / .xib / .xcassets under
ios/App/Sources (or any other ios/** group), and inserts the missing entries
into:

  - PBXBuildFile section
  - PBXFileReference section
  - PBXGroup children (creating intermediate groups if needed)
  - PBXSourcesBuildPhase files (or PBXResourcesBuildPhase for bundle assets)

The script is idempotent: already-registered files are skipped. It refuses to
touch AnyProvCore/ (a SwiftPM package, not part of the Xcode app target) and
refuses to register the project.pbxproj itself.

Run with `--dry-run` to see what would change without writing.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


# ----------------------------- pbxproj model ----------------------------- #

PBXPROJ_FILENAME = "project.pbxproj"

# Buildable file kinds we know how to classify.
SWIFT_EXTS = {".swift"}
OBJC_EXTS = {".m", ".mm", ".c", ".cpp"}
HEADER_EXTS = {".h"}
RESOURCE_EXTS = {".storyboard", ".xib", ".xcassets"}

# Sections we need to mutate, identified by their markers.
SECTION_MARKERS = {
    "PBXBuildFile": ("/* Begin PBXBuildFile section */", "/* End PBXBuildFile section */"),
    "PBXFileReference": ("/* Begin PBXFileReference section */", "/* End PBXFileReference section */"),
    "PBXGroup": ("/* Begin PBXGroup section */", "/* End PBXGroup section */"),
    "PBXSourcesBuildPhase": ("/* Begin PBXSourcesBuildPhase section */", "/* End PBXSourcesBuildPhase section */"),
    "PBXResourcesBuildPhase": ("/* Begin PBXResourcesBuildPhase section */", "/* End PBXResourcesBuildPhase section */"),
}


@dataclass
class PbxGroup:
    gid: str
    name: str | None
    path: str | None
    children: list[str] = field(default_factory=list)  # child gids in order
    # line range of this group's full block (for in-place editing)
    block_start: int = 0
    block_end: int = 0


@dataclass
class BuildPhase:
    gid: str
    isa: str
    files: list[str] = field(default_factory=list)
    block_start: int = 0
    block_end: int = 0


@dataclass
class Project:
    path: Path
    lines: list[str]
    file_refs: dict[str, dict]      # gid -> dict with keys: name|path|lastKnownFileType
    build_files: dict[str, dict]    # gid -> dict with keys: fileRef, comment
    groups: dict[str, PbxGroup]
    sources_phase: BuildPhase
    resources_phase: BuildPhase | None


# ------------------------------- discovery ------------------------------- #


def find_pbxproj(start: Path) -> Path | None:
    """Walk up from start looking for <root>/ios/AnyProvCode.xcodeproj/project.pbxproj."""
    cur = start.resolve()
    for _ in range(8):
        candidate = cur / "ios" / "AnyProvCode.xcodeproj" / PBXPROJ_FILENAME
        if candidate.exists():
            return candidate
        if cur.parent == cur:
            return None
        cur = cur.parent
    return None


def file_kind(path: Path) -> str | None:
    """Return one of: 'source', 'resource', or None (skip)."""
    suffix = path.suffix.lower()
    if suffix in SWIFT_EXTS or suffix in OBJC_EXTS:
        return "source"
    if suffix in RESOURCE_EXTS:
        return "resource"
    return None


def relative_group_segments(ios_root: Path, file_path: Path) -> list[str] | None:
    """
    Given ios_root = <repo>/ios and a file inside <repo>/ios, return the
    sequence of group path segments under which the file lives inside the
    Xcode project.

    For this project, the App target's source groups are rooted under
    "App" / "Sources" / "Features/<X>" (or DesignSystem / App itself).
    Files directly under ios/App/Sources/<Group>/<file> map to <Group>.

    Returns None if the file is not under a recognized source tree.
    """
    rel = file_path.resolve().relative_to(ios_root.resolve())
    parts = rel.parts

    # Skip anything that's part of the SwiftPM package — those don't go in
    # the Xcode app target.
    if parts and parts[0] == "AnyProvCore":
        return None

    if not parts or parts[0] != "App":
        return None

    # Expected: App[/<ignored>]/Sources[/<GroupA>[/<GroupB>...]]/<file>
    try:
        sources_idx = parts.index("Sources")
    except ValueError:
        return None

    groups = parts[sources_idx + 1 : -1]  # path segments between Sources/ and the file
    if not groups:
        # File directly under Sources/ — uncommon but valid; put it in a fallback group.
        return ["Sources"]
    return list(groups)


# ----------------------------- parsing pbxproj ---------------------------- #


def read_project(pbxproj_path: Path) -> Project:
    text = pbxproj_path.read_text(encoding="utf-8")
    # Xcode pbxproj files use \n line endings. Preserve original on write.
    if "\r\n" in text:
        lines = text.split("\r\n")
        newline = "\r\n"
    else:
        lines = text.split("\n")
        newline = "\n"
    # Stash newline style on the lines list via a sentinel? Simpler: store as
    # attribute on the object via a closure factory.
    project = Project(
        path=pbxproj_path,
        lines=lines,
        file_refs={},
        build_files={},
        groups={},
        sources_phase=BuildPhase(gid="", isa="PBXSourcesBuildPhase"),
        resources_phase=None,
    )
    project.newline = newline  # type: ignore[attr-defined]

    # ---- PBXFileReference ----
    file_ref_re = re.compile(
        r"^\s*([0-9A-F]{24})\s*/\*\s*(?P<name>[^*]+?)\s*\*/\s*=\s*\{isa = PBXFileReference;(?P<body>.*?)\};\s*$"
    )
    for i, line in enumerate(lines):
        m = file_ref_re.match(line)
        if not m:
            continue
        gid, name, body = m.group(1), m.group("name"), m.group("body")
        attrs: dict = {"_name": name, "_line": i}
        for k, v in re.findall(r"(\w+)\s*=\s*([^;]+);", body):
            attrs[k] = v.strip().strip('"')
        project.file_refs[gid] = attrs

    # ---- PBXBuildFile ----
    bf_re = re.compile(
        r"^\s*([0-9A-F]{24})\s*/\*\s*(?P<name>[^*]+?)\s+in\s+Sources\s\*/\s*=\s*\{isa = PBXBuildFile;(?P<body>.*?)\};\s*$"
    )
    for i, line in enumerate(lines):
        m = bf_re.match(line)
        if not m:
            continue
        gid, name, body = m.group(1), m.group("name"), m.group("body")
        attrs = {"_name": name, "_line": i}
        for k, v in re.findall(r"(\w+)\s*=\s*([^;]+);", body):
            attrs[k] = v.strip().strip('"')
        project.build_files[gid] = attrs

    # ---- PBXGroup section (multi-line blocks) ----
    start_marker, end_marker = SECTION_MARKERS["PBXGroup"]
    try:
        sec_start = lines.index(start_marker) + 1
        sec_end = lines.index(end_marker)
    except ValueError:
        sec_start, sec_end = 0, 0
    if sec_start and sec_end > sec_start:
        _parse_groups_in_range(project, lines, sec_start, sec_end)

    # ---- PBXSourcesBuildPhase ----
    _parse_build_phases(project, lines, "PBXSourcesBuildPhase")
    sp = _first_build_phase(project, "PBXSourcesBuildPhase")
    if sp is None:
        raise RuntimeError("Could not locate PBXSourcesBuildPhase in project")
    project.sources_phase = sp

    _parse_build_phases(project, lines, "PBXResourcesBuildPhase")
    rp = _first_build_phase(project, "PBXResourcesBuildPhase")
    project.resources_phase = rp

    return project


def _parse_groups_in_range(project: Project, lines: list[str], start: int, end: int) -> None:
    """Each PBXGroup is a multi-line block; find them and parse.

    The block opens with `<gid> /* <name> */ = {` (possibly followed by
    attributes including `isa = PBXGroup;` on the next line) and closes with
    `};`. We match the opening line and walk forward.
    """
    i = start
    open_re = re.compile(r"^\s*([0-9A-F]{24})\s*/\*[^*]*\*/\s*=\s*\{")
    while i < end:
        m = open_re.match(lines[i])
        if not m:
            i += 1
            continue
        gid = m.group(1)
        block_start = i
        depth = lines[i].count("{") - lines[i].count("}")
        j = i + 1
        isa_seen = False
        while depth > 0 and j < end:
            depth += lines[j].count("{") - lines[j].count("}")
            if "isa = PBXGroup;" in lines[j]:
                isa_seen = True
            j += 1
        if not isa_seen:
            i = j
            continue
        block_end = j
        block = "\n".join(lines[block_start:block_end])
        name_m = re.search(r"name\s*=\s*([^;]+);", block)
        path_m = re.search(r"path\s*=\s*([^;]+);", block)
        children_m = re.search(r"children\s*=\s*\((.*?)\);", block, re.DOTALL)
        group = PbxGroup(
            gid=gid,
            name=name_m.group(1).strip().strip('"') if name_m else None,
            path=path_m.group(1).strip().strip('"') if path_m else None,
            block_start=block_start,
            block_end=block_end,
        )
        if children_m:
            inner = children_m.group(1)
            for child_gid in re.findall(r"([0-9A-F]{24})", inner):
                group.children.append(child_gid)
        project.groups[gid] = group
        i = block_end


def _parse_build_phases(project: Project, lines: list[str], isa_name: str) -> None:
    sm, em = SECTION_MARKERS[isa_name]
    try:
        sec_start = lines.index(sm) + 1
        sec_end = lines.index(em)
    except ValueError:
        return
    # A build-phase block can have its gid on a header line (`GID /* Sources */ = {`)
    # followed by `isa = PBXSourcesBuildPhase;` on the next line. Match either.
    open_re = re.compile(r"^\s*([0-9A-F]{24})\s*/\*[^*]*\*/\s*=\s*\{")
    i = sec_start
    while i < sec_end:
        # Try to match an opening line.
        m = open_re.match(lines[i])
        if not m:
            i += 1
            continue
        gid = m.group(1)
        # Confirm the block's isa matches what we're parsing. Walk forward.
        block_start = i
        depth = lines[i].count("{") - lines[i].count("}")
        j = i + 1
        isa_seen = False
        while depth > 0 and j < sec_end:
            depth += lines[j].count("{") - lines[j].count("}")
            if f"isa = {isa_name};" in lines[j]:
                isa_seen = True
            j += 1
        if not isa_seen:
            i = j
            continue
        block_end = j
        block = "\n".join(lines[block_start:block_end])
        files_m = re.search(r"files\s*=\s*\((.*?)\);", block, re.DOTALL)
        bp = BuildPhase(gid=gid, isa=isa_name, block_start=block_start, block_end=block_end)
        if files_m:
            for child_gid in re.findall(r"([0-9A-F]{24})", files_m.group(1)):
                bp.files.append(child_gid)
        project.__dict__.setdefault("_build_phases", []).append(bp)  # type: ignore[attr-defined]
        i = block_end


def _first_build_phase(project: Project, isa_name: str) -> BuildPhase | None:
    for bp in project.__dict__.get("_build_phases", []):  # type: ignore[attr-defined]
        if bp.isa == isa_name:
            return bp
    return None


# ------------------------------- mutation ------------------------------- #


def gen_id() -> str:
    """24-char uppercase hex. Matches Xcode's style for object IDs."""
    return secrets.token_hex(12).upper()


def last_known_file_type(file_path: Path) -> str:
    suffix = file_path.suffix.lower()
    return {
        ".swift": "sourcecode.swift",
        ".m": "sourcecode.c.objc",
        ".mm": "sourcecode.cpp.objcpp",
        ".c": "sourcecode.c.c",
        ".cpp": "sourcecode.cpp.cpp",
        ".h": "sourcecode.c.h",
        ".storyboard": "file.storyboard",
        ".xib": "file.xib",
        ".xcassets": "folder.assetcatalog",
    }.get(suffix, "text")


def source_tree_for(group: PbxGroup | None) -> str:
    if group is None:
        return '"<group>"'
    # Default: relative to the parent group.
    return '"<group>"'


def find_or_create_group_chain(
    project: Project,
    segments: list[str],
    parent_gid: str,
    ios_root: Path,
) -> str:
    """
    Walk down the group tree starting at parent_gid, creating any missing
    intermediate groups. Returns the gid of the leaf group the file should be
    added to.
    """
    current_gid = parent_gid
    for seg in segments:
        # Look for a child group whose name or path == seg.
        current_group = project.groups.get(current_gid)
        if current_group is None:
            raise RuntimeError(f"Parent group {current_gid} not found")
        target_child = None
        for child_gid in current_group.children:
            child = project.groups.get(child_gid)
            if child is None:
                continue
            if (child.name == seg) or (child.path == seg):
                target_child = child
                break
        if target_child is None:
            target_child = _create_group(project, seg, parent_gid=current_gid)
        current_gid = target_child.gid
    return current_gid


def _create_group(project: Project, name: str, parent_gid: str) -> PbxGroup:
    gid = gen_id()
    new_group = PbxGroup(gid=gid, name=None, path=name, block_start=-1, block_end=-1)
    project.groups[gid] = new_group

    # Insert a new PBXGroup block at the end of the PBXGroup section.
    sm, em = SECTION_MARKERS["PBXGroup"]
    try:
        sec_start = lines_index(project.lines, sm) + 1
        sec_end = lines_index(project.lines, em)
    except ValueError:
        raise RuntimeError("PBXGroup section markers not found")

    # Find the indent style used by other groups in this section.
    sample = next((l for l in project.lines[sec_start:sec_end] if "isa = PBXGroup;" in l), None)
    indent = ""
    if sample:
        m = re.match(r"^(\s*)\S", sample)
        if m:
            indent = m.group(1)
    inner_indent = indent + "\t"
    child_indent = inner_indent + "\t"

    block_lines = [
        f"{indent}{gid} /* {name} */ = {{",
        f"{inner_indent}isa = PBXGroup;",
        f"{inner_indent}children = (",
        f"{child_indent}",
        f"{inner_indent});",
        f"{inner_indent}path = {name};",
        f"{inner_indent}sourceTree = \"<group>\";",
        f"{indent}}};",
    ]
    # Insert before the end marker line.
    project.lines[sec_end:sec_end] = block_lines
    # After insertion, the end marker line shifted by len(block_lines).
    # Re-resolve indices for subsequent edits in this run.
    new_group.block_start = sec_end
    new_group.block_end = sec_end + len(block_lines)

    # Wire the new group into its parent's children = (...) block in the file.
    parent = project.groups.get(parent_gid)
    if parent is not None:
        parent.children.append(gid)
        _append_child_to_group(project, parent, gid, name)

    return new_group


def lines_index(lines: list[str], needle: str) -> int:
    for i, line in enumerate(lines):
        if needle in line:
            return i
    raise ValueError(needle)


def file_already_registered(project: Project, file_basename: str) -> bool:
    """Check if any existing PBXFileReference path matches the basename."""
    for attrs in project.file_refs.values():
        if attrs.get("path") == file_basename or attrs.get("_name") == file_basename:
            return True
    return False


def add_file_to_project(
    project: Project,
    ios_root: Path,
    file_path: Path,
    parent_group_gid: str,
) -> str:
    """Insert a single file into the project. Returns the new buildFile gid."""
    basename = file_path.name
    if file_already_registered(project, basename):
        return ""

    # Find or create the group chain for this file.
    segments = relative_group_segments(ios_root, file_path)
    if segments is None:
        return ""
    leaf_gid = find_or_create_group_chain(project, segments, parent_group_gid, ios_root)

    file_ref_gid = gen_id()
    build_file_gid = gen_id()
    kind = file_kind(file_path)
    ftype = last_known_file_type(file_path)

    # --- Insert PBXFileReference entry ---
    sm, em = SECTION_MARKERS["PBXFileReference"]
    fr_start = lines_index(project.lines, sm) + 1
    fr_end = lines_index(project.lines, em)
    sample_fr = next((l for l in project.lines[fr_start:fr_end] if "isa = PBXFileReference;" in l), None)
    fr_indent = ""
    if sample_fr:
        m = re.match(r"^(\s*)\S", sample_fr)
        if m:
            fr_indent = m.group(1)
    fr_line = (
        f"{fr_indent}{file_ref_gid} /* {basename} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = {ftype}; "
        f"path = {basename}; sourceTree = \"<group>\"; }};"
    )
    project.lines[fr_end:fr_end] = [fr_line]
    project.file_refs[file_ref_gid] = {
        "_name": basename, "lastKnownFileType": ftype,
        "path": basename, "sourceTree": '"<group>"',
    }

    # --- Insert PBXBuildFile entry (always under Sources section) ---
    sm, em = SECTION_MARKERS["PBXBuildFile"]
    bf_start = lines_index(project.lines, sm) + 1
    bf_end = lines_index(project.lines, em)
    sample_bf = next((l for l in project.lines[bf_start:bf_end] if "isa = PBXBuildFile;" in l), None)
    bf_indent = ""
    if sample_bf:
        m = re.match(r"^(\s*)\S", sample_bf)
        if m:
            bf_indent = m.group(1)
    bf_line = (
        f"{bf_indent}{build_file_gid} /* {basename} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ref_gid} /* {basename} */; }};"
    )
    project.lines[bf_end:bf_end] = [bf_line]
    project.build_files[build_file_gid] = {"_name": basename, "fileRef": file_ref_gid}

    # --- Insert buildFile into Sources (or Resources) build phase ---
    phase = project.sources_phase if kind == "source" else project.resources_phase or project.sources_phase
    _append_to_build_phase(project, phase, build_file_gid, basename)

    # --- Add fileRef to the leaf group's children = (...) ---
    leaf_group = project.groups[leaf_gid]
    _append_child_to_group(project, leaf_group, file_ref_gid, basename)

    return build_file_gid


def _append_to_build_phase(project: Project, phase: BuildPhase, gid: str, name: str) -> None:
    """Insert `gid /* name */,` as the last child of files = (...)."""
    # Find the `files = (` line inside the phase block, then walk to its `);`.
    block = project.lines[phase.block_start:phase.block_end]
    files_idx = None
    for i, line in enumerate(block):
        if "files = (" in line:
            files_idx = i
            break
    if files_idx is None:
        return
    # Walk forward to find the closing `);` for files.
    depth = block[files_idx].count("(") - block[files_idx].count(")")
    j = files_idx + 1
    while j < len(block) and depth > 0:
        depth += block[j].count("(") - block[j].count(")")
        j += 1
    # Insert before the line containing `);` that closes files.
    insert_at = phase.block_start + j - 1
    sample = next((l for l in block if l.strip().startswith(gid[:8]) or "in Sources" in l), None)
    indent = "\t\t\t"
    if sample:
        m = re.match(r"^(\s*)\S", sample)
        if m:
            indent = m.group(1)
    new_line = f"{indent}{gid} /* {name} in Sources */,"
    project.lines[insert_at:insert_at] = [new_line]
    # Update cached indices for subsequent inserts in this run.
    shift = 1
    phase.block_end += shift
    for g in project.groups.values():
        if g and g.block_start >= insert_at:
            g.block_start += shift
            g.block_end += shift


def _append_child_to_group(project: Project, group: PbxGroup, gid: str, name: str) -> None:
    block = project.lines[group.block_start:group.block_end]
    children_idx = None
    for i, line in enumerate(block):
        if "children = (" in line:
            children_idx = i
            break
    if children_idx is None:
        return
    depth = block[children_idx].count("(") - block[children_idx].count(")")
    j = children_idx + 1
    while j < len(block) and depth > 0:
        depth += block[j].count("(") - block[j].count(")")
        j += 1
    insert_at = group.block_start + j - 1
    sample = next((l for l in block if re.match(r"^\s*[0-9A-F]{24}", l)), None)
    indent = "\t\t\t"
    if sample:
        m = re.match(r"^(\s*)\S", sample)
        if m:
            indent = m.group(1)
    new_line = f"{indent}{gid} /* {name} */,"
    project.lines[insert_at:insert_at] = [new_line]
    shift = 1
    group.block_end += shift
    for g in project.groups.values():
        if g and g.block_start >= insert_at:
            g.block_start += shift
            g.block_end += shift


# ----------------------------- serialization ----------------------------- #


def write_project(project: Project) -> None:
    newline = project.__dict__.get("newline", "\n")  # type: ignore[attr-defined]
    text = newline.join(project.lines)
    bak = project.path.with_suffix(project.path.suffix + ".bak")
    if not bak.exists():
        shutil.copy2(project.path, bak)
    tmp = project.path.with_suffix(project.path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="")
    os.replace(tmp, project.path)


# ------------------------------- entrypoint ------------------------------ #


def iter_files_from_payload(payload: dict) -> Iterable[Path]:
    """Read a Claude PostToolUse payload and yield every created/modified file path."""
    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    tool_response = payload.get("tool_response") or {}

    candidates: list[str] = []

    if tool_name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        fp = tool_input.get("file_path") or tool_input.get("notebook_path")
        if fp:
            candidates.append(fp)
    elif tool_name == "Bash":
        # Best-effort: scan command for `touch foo.swift` / `cp .../X.swift ios/...`
        cmd = tool_input.get("command", "") or ""
        candidates.extend(re.findall(r"[\w./-]+\.swift\b", cmd))
        candidates.extend(re.findall(r"[\w./-]+\.xcassets\b", cmd))
        candidates.extend(re.findall(r"[\w./-]+\.storyboard\b", cmd))

    for c in candidates:
        if not c:
            continue
        p = Path(c)
        if not p.is_absolute():
            # Resolve relative paths against the cwd Claude reported.
            cwd = payload.get("cwd") or os.getcwd()
            p = Path(cwd) / p
        yield p


def find_root_app_group(project: Project) -> str:
    """Return the gid of the `Sources` group (the parent of all source files
    in this project). The Sources group is the child of the top-level `App`
    group."""
    for g in project.groups.values():
        if g.path == "App" and g.children:
            for c in g.children:
                child = project.groups.get(c)
                if child and child.path == "Sources":
                    return child.gid
    raise RuntimeError("Could not locate Sources group in project")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--file", help="Register a single file (bypass payload). Useful for tests.")
    args = ap.parse_args()

    raw = sys.stdin.read()
    payload: dict = {}
    if raw.strip():
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}

    # Build list of files to consider.
    files: list[Path] = []
    if args.file:
        files.append(Path(args.file).resolve())
    else:
        files.extend(iter_files_from_payload(payload))

    if not files:
        return 0

    # Group by project so multiple pbxproj files (e.g. workspace) can coexist.
    by_pbx: dict[Path, list[Path]] = {}
    for f in files:
        pbx = find_pbxproj(f if f.is_dir() else f.parent)
        if pbx is None:
            continue
        by_pbx.setdefault(pbx, []).append(f)

    if not by_pbx:
        return 0

    changed_any = False
    for pbx, pbx_files in by_pbx.items():
        ios_root = pbx.parent.parent  # ios/AnyProvCode.xcodeproj -> ios
        project = read_project(pbx)
        parent_gid = find_root_app_group(project)

        for f in pbx_files:
            try:
                f = f.resolve()
                if file_kind(f) is None:
                    continue
                # Skip if outside ios/
                try:
                    f.relative_to(ios_root)
                except ValueError:
                    continue
                # Skip files inside the SwiftPM package.
                rel = f.relative_to(ios_root)
                if rel.parts and rel.parts[0] == "AnyProvCore":
                    continue
                # Skip pbxproj itself.
                if f.name == PBXPROJ_FILENAME:
                    continue
                gid = add_file_to_project(project, ios_root, f, parent_gid)
                if gid:
                    changed_any = True
                    print(f"[xcode-register] + {f.relative_to(ios_root.parent)}", file=sys.stderr)
            except Exception as e:  # don't kill the agent over a hook error
                print(f"[xcode-register] error: {e} ({f})", file=sys.stderr)
                continue

        if changed_any and not args.dry_run:
            try:
                write_project(project)
                print(f"[xcode-register] updated {pbx}", file=sys.stderr)
            except Exception as e:
                print(f"[xcode-register] write failed: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())