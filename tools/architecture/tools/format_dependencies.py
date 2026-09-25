#!/usr/bin/env python3
"""Reformat a Phronomy dependency SVG while preserving its source evidence.

Python 3.10+, standard library only. This formats an existing analyzed SVG;
it does not rescan Ruby source or infer dependency rules from coordinates.
"""
import argparse
from collections import Counter, defaultdict
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
XLINK = "http://www.w3.org/1999/xlink"
S, X = "{" + SVG + "}", "{" + XLINK + "}"
ET.register_namespace("", SVG)
ET.register_namespace("xlink", XLINK)
COLORS = {'internal': '#76808d', 'external': '#427c98'}


def rounded_path(points, radius):
    """Keep the exact center endpoints; round only the intermediate corners."""
    clean = [points[0]]
    for point in points[1:]:
        if math.dist(clean[-1], point) > 0.01:
            clean.append(point)
    result = [f"M {clean[0][0]:.3f} {clean[0][1]:.3f}"]
    for prev, point, after in zip(clean, clean[1:], clean[2:]):
        a, b = math.dist(prev, point), math.dist(point, after)
        cut = min(radius, a / 3, b / 3)
        p = tuple(point[i] + (prev[i] - point[i]) * cut / a for i in (0, 1))
        q = tuple(point[i] + (after[i] - point[i]) * cut / b for i in (0, 1))
        result.append(f"L {p[0]:.3f} {p[1]:.3f} Q {point[0]:.3f} {point[1]:.3f} {q[0]:.3f} {q[1]:.3f}")
    result.append(f"L {clean[-1][0]:.3f} {clean[-1][1]:.3f}")
    return " ".join(result)


def group_components(ids, cells):
    """Avoid enclosing unrelated boxes when a group spans topical columns."""
    remaining = set(ids)
    result = []
    while remaining:
        seed = min(remaining)
        remaining.remove(seed)
        found, pending = [seed], [seed]
        while pending:
            b, c, row = cells[pending.pop()]
            adjacent = [i for i in sorted(remaining) if cells[i][0] == b and
                        abs(cells[i][1] - c) + abs(cells[i][2] - row) == 1]
            for item in adjacent:
                remaining.remove(item)
                pending.append(item)
                found.append(item)
        result.append(found)
    return result


def format_svg(input_path, output_path, config_path, validation_path=None):
    old_root = ET.parse(input_path).getroot()
    old = json.loads(old_root.find(S + "metadata").text)
    config = json.loads(config_path.read_text())
    by_id = {n.get("id"): n for n in old_root.iter() if n.get("id")}
    meta = deepcopy(old)
    applied_refactor = meta.get("applied_refactor", 23)
    review_section = meta.get("review_section", 52)
    modules = {m["id"]: m for m in meta["modules"]}
    edges = sorted(meta["edges"], key=lambda e: (e["from"], e["to"]))
    groups = meta["groups"]
    presentation = config.get("presentation", {})
    transparent = presentation.get("transparent_text_panels", False)
    hidden_targets = set(presentation.get("hidden_incoming_targets", []))
    if hidden_targets - modules.keys():
        raise ValueError("Hidden arrow target is not an actual module")
    visible_edges = [edge for edge in edges if edge["to"] not in hidden_targets]
    hidden_count = len(edges) - len(visible_edges)
    theme = config.get("group_theme", {})
    palette = theme.get("palette", {})

    def group_style(gid):
        return palette.get(theme.get("groups", {}).get(gid), {
            "fill": "#f3f7fa", "stroke": "#c4d1db",
            "label_fill": "#e8f0f6", "label_color": "#526e80"
        })

    if any("layer" in m or "rank" in m for m in modules.values()):
        raise ValueError("Keep architecture roles independent of display-layer positions")
    positions, cells, bands = {}, {}, []
    by_group = {g["id"]: g for g in groups}
    if "bands" in config:
        y = config["band_start_y"]
        all_rows = []
        band_ids = [b["id"] for b in config["bands"]]
        if len(band_ids) != len(set(band_ids)):
            raise ValueError("Duplicate display-layer ID")
        for band in config["bands"]:
            if len(band["columns"]) != len(config["column_centers"]):
                raise ValueError("Display-layer column count must match the column centers")
            rows = max(map(len, band["columns"]))
            bottom = y + 90 + config["row_step"] * rows
            info = {"id": band["id"], "title": band["title"], "top": y,
                    "bottom": bottom, "members": []}
            all_rows.extend(y + 180 + config["row_step"] * row for row in range(rows))
            for column, ids in enumerate(band["columns"]):
                for row, mid in enumerate(ids):
                    if mid in positions:
                        raise ValueError(f"Duplicate layout module: {mid}")
                    positions[mid] = (config["column_centers"][column], y + 180 + config["row_step"] * row)
                    cells[mid] = (band["id"], column, row)
                    info["members"].append(mid)
            bands.append(info)
            y = bottom
        if len(config["support"]) > len(all_rows):
            raise ValueError("Support modules exceed the available display rows")
        for row, mid in enumerate(config["support"]):
            if mid in positions:
                raise ValueError(f"Duplicate layout module: {mid}")
            positions[mid] = (config["support_center"], all_rows[row])
            cells[mid] = ("support", len(config["column_centers"]), row)
    else:
        placed = [gid for col in config["group_columns"] for gid in col]
        if set(placed) != set(by_group) or len(placed) != len(set(placed)):
            raise ValueError("Layout must contain each responsibility group exactly once")
        for column, gids in enumerate(config["group_columns"]):
            row = 0
            for gid in gids:
                for mid in by_group[gid]["members"]:
                    if mid in positions:
                        raise ValueError(f"Duplicate layout module: {mid}")
                    positions[mid] = (config["column_centers"][column], config["start_y"] + config["row_step"] * row)
                    cells[mid] = (gid, column, row)
                    row += 1
                row += 1
    if set(positions) != set(modules):
        raise ValueError(f"Update layout for changed module set: {sorted(set(positions) ^ set(modules))}")
    for mid, point in positions.items():
        modules[mid].update(x=point[0], y=point[1], visual_column=cells[mid][1])

    graph_bottom = max(p[1] for p in positions.values()) + 160
    notes_top = graph_bottom + 85
    matrix_heading = notes_top + 310
    # The existing matrix is copied byte-for-element, with only its footer revised.
    # It has its own stable row order, independent of the network's visual layout.
    old_matrix = next(n for n in old_root.iter(S + "text") if n.text == "COMPLETE DEPENDENCY MATRIX")
    original_matrix_heading = float(old_matrix.get("y"))
    matrix_shift = matrix_heading - original_matrix_heading
    width = config["width"]
    height = matrix_shift + float(old_root.get("height"))
    root = ET.Element(S + "svg", {"width": str(width), "height": str(int(height)),
            "viewBox": f"0 0 {width} {int(height)}", "role": "img", "aria-labelledby": "chart-title chart-description"})

    def add(tag, parent=None, text=None, **attrs):
        node = ET.SubElement(root if parent is None else parent, S + tag,
                {k.replace("_", "-"): str(v) for k, v in attrs.items()})
        node.text = text
        return node

    def text(x, y, value, size=20, color="#294353", parent=None, **attrs):
        return add("text", parent, value, x=x, y=y, font_size=size, fill=color,
                   font_family="DejaVu Sans, sans-serif", **attrs)

    def anchor(parent, original):
        node = add("a", parent, target="_blank")
        if original.get(X + "href"):
            node.set(X + "href", original.get(X + "href"))
        node.append(deepcopy(original.find(S + "title")))
        return node

    add("title", text="Phronomy dependencies: layered display and responsibility groups", id="chart-title")
    add("desc", text="Measured Ruby and declared RBS dependencies in the previous horizontal layer layout and topical columns. B1-B6 identify display bands; G IDs identify responsibilities. Boundary checks use responsibilities rather than positions. Individual module boxes and source evidence are preserved.", id="chart-description")
    metadata_node = add("metadata")
    add("rect", x=0, y=0, width=width, height=height, fill="#fff")
    style = add("style")
    style.text = ".edge:hover .edge-line{stroke-opacity:1;stroke-width:3}.edge:hover .arrowhead{fill-opacity:1}.edge{cursor:pointer}"
    text(70, 75, meta.get("project_title", "PHRONOMY 0.26.0"), 42, font_weight=750)
    text(70, 120, meta.get("diagram_subtitle", f"Applied Refactor {applied_refactor} / Topical columns & distributed connections"), 29)
    text(70, 164, f"{len(modules)} modules / {meta['stats']['files']} Ruby files / {meta['stats'].get('rbs_files', 0)} RBS files / {len(edges)} dependency pairs / {len(groups)} responsibility groups / {len(visible_edges)} arrows shown", 23)
    text(70, 205, meta.get("commit_label", "Reviewed commit: ") + meta["commit"], 19)
    text(70, 237, "Source tree: " + meta["source_tree"], 17, "#627988")
    text(70, 281, "Arrows connect box boundaries. Text panels are transparent; solid triangles mark the target." if transparent else
         "Arrows start at hidden box centers; boundary crossings are spread out. Solid triangles mark the target.", 21)
    mixed = any(module.get("mixed", False) for module in modules.values())
    b4_roles = "clients / implementations / pending split" if mixed else "clients / implementations"
    text(70, 316, f"B4: {b4_roles}. B5: Engine / separated Contracts. G IDs identify independent responsibilities.", 19)
    counts = Counter(e["direction"] for e in visible_edges)
    for j, (key, label) in enumerate([("external", "Between groups"), ("internal", "Within group")]):
        x = 72 + j * 440
        add("rect", x=x, y=349, width=18, height=18, rx=4, fill=COLORS[key])
        text(x + 30, 366, f"{label}: {counts[key]} shown", 18)
    background_legend = add("g", id="common-background-legend")
    add("rect", background_legend, x=2300, y=349, width=18, height=18, rx=4, fill=config["background"]["stroke"])
    text(2330, 366, " / ".join(sorted(hidden_targets)) + ": incoming arrows hidden" if hidden_targets else
         "Common targets: light gray / behind", 18, parent=background_legend)
    directory_cycles = " / ".join(map(str, meta["stats"]["module_scc_sizes"]["all"])) or "none"
    file_cycles = " / ".join(map(str, meta["stats"]["file_scc_sizes"])) or "none"
    text(70, 413, f"Directory cycles (union): {directory_cycles}. Ruby file cycles: {file_cycles}. Orange borders mark cycle membership.", 18, "#627988")
    for index, (gid, label) in enumerate([("G14", "Engine"), ("G46", "Async Clients"),
                                        ("G47", "Backend Contracts"), ("G48", "Backend Implementations")]):
        if gid in by_group:
            color = group_style(gid)
            x = 72 + index * 610
            add("rect", x=x, y=431, width=25, height=20, rx=3,
                fill=color["label_fill"], stroke=color["stroke"])
            text(x + 36, 448, gid + "  " + label, 18, color["label_color"])
    text(70, 472, "* MIXED: contract and implementation share a source directory; separation is still pending." if mixed else
         "Backend contracts and implementations occupy separate source directories.", 20, "#7a5737" if mixed else "#526b7a")
    text(70, 509, "Backend Implementations are production code. Testing, Migration and Tracing retain their own groups.", 19, "#526b7a")
    if bands:
        backdrop = add("g", id="display-layers")
        for column, description in enumerate(config["columns"]):
            cx = config["column_centers"][column]
            add("rect", backdrop, x=cx - 245, y=550, width=490, height=68, rx=8, fill="none" if transparent else "#e8f0f6")
            text(cx, 578, description["title"], 18, parent=backdrop, text_anchor="middle", font_weight=750)
            text(cx, 603, description["subtitle"], 14, "#526b7a", backdrop, text_anchor="middle")
        text(config["support_center"], 578, "SUPPORT / CROSS-CUTTING", 19,
             parent=backdrop, text_anchor="middle", font_weight=700)
        for band in bands:
            add("rect", backdrop, id="display_layer_" + band["id"], x=50, y=band["top"], width=2620,
                height=band["bottom"] - band["top"], fill="#f3f7fa" if band["id"] in ["B2", "B4", "B6"] else "#fafcfd",
                stroke="#d9e4eb")
            text(75, band["top"] + 34, band["id"] + "   " + band["title"], 23, parent=backdrop, font_weight=700)
        for x in [590, 1110, 1630, 2150]:
            add("line", backdrop, x1=x, x2=x, y1=bands[0]["top"], y2=bands[-1]["bottom"],
                stroke="#e1e8ee", stroke_dasharray="3 9")
        support_bottom = max(positions[mid][1] for mid in config["support"]) + 120
        add("rect", backdrop, x=2720, y=bands[0]["top"], width=480,
            height=support_bottom - bands[0]["top"], rx=12, fill="#f8f8f4", stroke="#dddccf")

    # Assign distinct ports jointly to incoming and outgoing edges on each face.
    # The actual path endpoints remain the box centers and are covered by nodes.
    sides, route_kinds, incidence = {}, {}, defaultdict(list)
    for edge in edges:
        f, t = edge["from"], edge["to"]
        sx, sy = positions[f]
        tx, ty = positions[t]
        horizontal_clear = sy == ty and abs(tx - sx) <= 1040 and not any(
            p[1] == sy and min(sx, tx) < p[0] < max(sx, tx) for mid, p in positions.items() if mid not in (f, t))
        vertical_clear = sx == tx and abs(ty - sy) <= config["row_step"] * 1.5 and not any(
            p[0] == sx and min(sy, ty) < p[1] < max(sy, ty) for mid, p in positions.items() if mid not in (f, t))
        if horizontal_clear:
            source_side, target_side = ("E", "W") if tx > sx else ("W", "E")
            route_kinds[f, t] = "direct_horizontal"
        elif ty > sy:
            source_side, target_side = "S", "N"
            route_kinds[f, t] = "direct_vertical" if vertical_clear else "routed"
        elif ty < sy:
            source_side, target_side = "N", "S"
            route_kinds[f, t] = "direct_vertical" if vertical_clear else "routed"
        else:
            source_side = target_side = "N" if sx < tx else "S"
            route_kinds[f, t] = "routed"
        sides[f, t] = (source_side, target_side)
        incidence[f, source_side].append((tx, ty, f, t, "source"))
        incidence[t, target_side].append((sx, sy, f, t, "target"))
    port_offsets = {}
    for key, items in incidence.items():
        items.sort()
        for i, item in enumerate(items):
            spread = config["routing"]["port_spread"] if key[1] in ("N", "S") else 39
            offset = 0 if len(items) == 1 else -spread + 2 * spread * i / (len(items) - 1)
            port_offsets[item[2], item[3], item[4]] = offset

    # Between-column gutters are free of boxes. Spread long routes across them
    # and assign an individual lane to each edge instead of reusing five tracks.
    gutters = [74, 590, 1110, 1630, 2150, 2685, 3220]
    assigned, corridor_edges = {}, defaultdict(list)
    for edge in sorted(edges, key=lambda p: (-abs(positions[p["from"]][1] - positions[p["to"]][1]), p["from"], p["to"])):
        f, t = edge["from"], edge["to"]
        if route_kinds[f, t] != "routed":
            continue
        sx, sy = positions[f]
        tx, ty = positions[t]
        candidates = range(6) if max(sx, tx) < 2720 else range(1, 7)
        index = min(candidates, key=lambda i: abs(sx - gutters[i]) + abs(tx - gutters[i]) + 28 * len(corridor_edges[i]))
        assigned[f, t] = index
        corridor_edges[index].append((f, t))
    tracks = {}
    for index, keys in corridor_edges.items():
        keys.sort(key=lambda key: (min(positions[key[0]][1], positions[key[1]][1]), positions[key[1]][0], key))
        spread = 32 if index in (0, 6) else 42
        for i, key in enumerate(keys):
            tracks[key] = gutters[index] + (0 if len(keys) == 1 else -spread + 2 * spread * i / (len(keys) - 1))

    # Incoming and outgoing horizontal runs share one row-gap allocation. Give
    # every run a separate y coordinate instead of accumulating at a few heights.
    row_levels = sorted(set(p[1] for p in positions.values()))
    gap_uses, gap_ranges, row_tracks = defaultdict(list), {}, {}
    for edge in edges:
        f, t = edge["from"], edge["to"]
        if route_kinds[f, t] != "routed":
            continue
        for role, mid, side in [("source", f, sides[f, t][0]), ("target", t, sides[f, t][1])]:
            cx, cy = positions[mid]
            index = row_levels.index(cy)
            gap = index if side == "N" else index + 1
            low = row_levels[gap - 1] + 82 if gap else row_levels[0] - 125
            high = row_levels[gap] - 82 if gap < len(row_levels) else row_levels[-1] + 125
            gap_ranges[gap] = (low, high)
            gap_uses[gap].append((cx, positions[t if role == "source" else f][0], f, t, role))
    for gap, items in gap_uses.items():
        low, high = gap_ranges[gap]
        for i, item in enumerate(sorted(items)):
            row_tracks[item[2], item[3], item[4]] = low + (high - low) * (i + 1) / (len(items) + 1)

    # Group fills belong behind every dependency, including muted common edges.
    # Outlines and captions are added later, without covering paths with a fill.
    group_backgrounds = add("g", id="ownership-backgrounds")
    edge_root = add("g", id="dependency-edges")
    back = add("g", edge_root, id="common-background-edges")
    normal = add("g", edge_root, id="primary-dependency-edges")
    routing_records = []
    half_height = config["box_height"] / 2
    half_width = config["box_width"] / 2

    def outside(center, side, offset, distance):
        x, y = center
        if side in ("N", "S"):
            sign = -1 if side == "N" else 1
            return (x + offset * distance / half_height, y + sign * distance), (x + offset, y + sign * half_height)
        sign = -1 if side == "W" else 1
        return (x + sign * distance, y + offset * distance / half_width), (x + sign * half_width, y + offset)

    for edge in edges:
        f, t = edge["from"], edge["to"]
        sx, sy = positions[f]
        tx, ty = positions[t]
        source_side, target_side = sides[f, t]
        source_offset = port_offsets[f, t, "source"]
        target_offset = port_offsets[f, t, "target"]
        # Adjacent boxes use direct connections; other routes use free gutters.
        kind = route_kinds[f, t]
        if kind == "routed":
            source_distance = abs(row_tracks[f, t, "source"] - sy)
            target_distance = abs(row_tracks[f, t, "target"] - ty)
        elif kind == "direct_horizontal":
            source_distance = target_distance = half_width + 25
        else:
            source_distance = target_distance = half_height + 25
        # A large inter-group row gap must not extend a diagonal fan beyond the
        # canvas or into the next column. Fan out locally, then join the row track.
        source_fan_distance = min(source_distance, (half_width + 50) * half_height / max(abs(source_offset), 1)) if source_side in ("N", "S") else source_distance
        target_fan_distance = min(target_distance, (half_width + 50) * half_height / max(abs(target_offset), 1)) if target_side in ("N", "S") else target_distance
        source_out, source_boundary = outside((sx, sy), source_side, source_offset, source_fan_distance)
        target_out, boundary = outside((tx, ty), target_side, target_offset, target_fan_distance)
        gx = tracks.get((f, t))
        points = [(sx, sy), source_out]
        if kind == "routed":
            source_track_y = row_tracks[f, t, "source"]
            target_track_y = row_tracks[f, t, "target"]
            points.extend([(source_out[0], source_track_y), (gx, source_track_y),
                           (gx, target_track_y), (target_out[0], target_track_y)])
        points.extend([target_out, (tx, ty)])
        muted = modules[t]["group"] in config["background"]["target_groups"] and modules[f]["group"] not in config["background"]["target_groups"]
        color = config["background"]["stroke"] if muted else COLORS[edge["direction"]]
        layer = back if muted else normal
        group = add("g", layer, id=f"edge_{f}_{t}", **{"class": "edge"})
        if t in hidden_targets:
            group.set("display", "none")
            group.set("data-hidden-reason", "incoming-to-common-target")
        if transparent:
            points[0], points[-1] = source_boundary, boundary
        link = anchor(group, by_id[f"edge_{f}_{t}"].find(S + "a"))
        add("path", link, d=rounded_path(points, config["routing"]["corner_radius"]),
            fill="none", stroke=color, stroke_width=min(1.9, 1.05 + edge["c"] * .022),
            stroke_opacity=config["background"]["line_opacity"] if muted else .42,
            stroke_dasharray="4 4" if edge["exception_only"] else "none", **{"class": "edge-line"})
        dx, dy = tx - target_out[0], ty - target_out[1]
        length = math.hypot(dx, dy)
        ux, uy = dx / length, dy / length
        # Keep the filled tip immediately outside the opaque target box border.
        tip = (boundary[0] - ux * 1.8, boundary[1] - uy * 1.8)
        arrow_length, half_arrow = config["routing"]["arrow_length"], config["routing"]["arrow_width"] / 2
        base = (tip[0] - ux * arrow_length, tip[1] - uy * arrow_length)
        triangle = [tip, (base[0] - uy * half_arrow, base[1] + ux * half_arrow), (base[0] + uy * half_arrow, base[1] - ux * half_arrow)]
        add("polygon", link, points=" ".join(f"{x:.3f},{y:.3f}" for x, y in triangle), fill=color,
            fill_opacity=config["background"]["arrowhead_opacity"] if muted else .95, **{"class": "arrowhead"})
        routing_records.append({"from": f, "to": t, "source_center": [sx, sy], "target_center": [tx, ty],
            "source_boundary": list(source_boundary), "target_boundary": list(boundary),
            "source_side": source_side, "target_side": target_side, "background": muted, "gutter": gx,
            "route_kind": kind, "control_points": points})

    # Ownership frames may form multiple connected pieces with the same group ID.
    # Transparent nodes use boundary endpoints; opaque nodes cover center segments.
    frames = add("g", id="ownership-frames")
    for group in groups:
        color = group_style(group["id"])
        for index, part in enumerate(group_components(group["members"], cells)):
            xs, ys = zip(*(positions[mid] for mid in part))
            x, y = min(xs) - 203, min(ys) - 104
            w, h = max(xs) - min(xs) + 406, max(ys) - min(ys) + 184
            frame = add("g", frames, id=f"ownership_{group['id']}_{index}")
            add("rect", group_backgrounds, id=f"ownership_fill_{group['id']}_{index}",
                x=x, y=y, width=w, height=h, rx=10, fill=color["fill"])
            add("rect", frame, x=x, y=y, width=w, height=h, rx=10,
                fill="none", stroke=color["stroke"], stroke_width=1)
            title = config["group_display_titles"].get(group["id"], group["title"])
            add("rect", frame, x=x + 6, y=y + 6, width=w - 12, height=22, rx=3,
                fill="none" if transparent else color["label_fill"])
            text(x + 10, y + 22, group["id"] + "  " + title, 13, color["label_color"], frame, font_weight=600)
    nodes = add("g", id="module-nodes")
    for mid, module in sorted(modules.items()):
        x, y = positions[mid]
        node = add("g", nodes, id="node_" + mid, **{"class": "node"})
        link = anchor(node, by_id["node_" + mid].find(S + "a"))
        add("rect", link, x=x - config["box_width"] / 2, y=y - half_height,
            width=config["box_width"], height=config["box_height"], rx=9, fill="none" if transparent else "#fff", pointer_events="all",
            stroke="#bc7048" if module["scc"] else "#7896aa", stroke_width=1.7)
        cycle = f"  [S{module['scc_group']}]" if module["scc"] else ""
        text(x - 176, y - 41, mid + cycle + (" *" if module.get("mixed") else ""), 18, parent=link, font_weight=750)
        label = module["directory"].removeprefix("lib/phronomy/") if module["directory"] != "lib/phronomy" else "[root loading / version]"
        lines, line = [], ""
        for segment in label.split("/"):
            candidate = line + "/" + segment if line else segment
            if len(candidate) > 29 and line:
                lines.append(line + "/")
                line = segment
            else:
                line = candidate
        if line:
            lines.append(line)
        if len(lines) > 2:
            raise ValueError(f"Directory label needs a larger node: {mid}")
        for i, line in enumerate(lines):
            text(x - 176, y - 15 + i * 23, line, 19, parent=link, font_weight=650)
        text(x - 176, y + 29, module["role"], 13, "#526b7a", link)
        text(x - 176, y + 51, f"{module['file_count']} rb  |  in {module['fan_in']} / out {module['fan_out']}  |  {module['group']}", 14, "#526b7a", link)

    text(70, notes_top, "HOW TO READ THIS REVISION", 25, font_weight=750)
    notes = [
        "B1-B6 restore the previous horizontal layout. G IDs and pastel fills distinguish responsibilities; white boxes show source modules.",
        f"All {len(edges)} measured dependency pairs remain visible and are repeated in the complete matrix below.",
        "Each path starts behind its source box. Distributed boundary crossings and solid triangular arrowheads identify the dependency target.",
        "Dependencies on common definitions / configuration are light gray behind other edges. Hover to emphasize; click for source evidence.",
        "Mixed source directories remain marked until actual separation. Coordinates and line colors do not certify boundary correctness.",
        "Entry lib/phronomy.rb is excluded. Dynamic injection, reflective calls, RBS and external example implementations require separate review."
    ]
    if transparent:
        notes[0] = "B1-B6 retain the horizontal layout. Pastel groups distinguish responsibilities; transparent boxes show source modules."
        notes[2] = "Paths start and end at box boundaries; transparent text panels reveal no center-to-border segments."
    if hidden_targets:
        targets = "/".join(sorted(hidden_targets))
        notes[1] = f"{len(visible_edges)} arrows are shown; {hidden_count} incoming arrows to {targets} are hidden. All {len(edges)} pairs remain in the matrix."
        notes[3] = "Hidden arrows are a display choice. Full source evidence and measured relationships remain in the matrix."
    if meta.get("candidate") and not hidden_targets:
        notes[3] = "Common dependencies are light gray. Hover for source locations; GitHub links are disabled for this unpublished candidate."
    for i, line in enumerate(notes):
        text(70, notes_top + 43 + i * 33, line, 19, "#526b7a")
    matrix_group = add("g", id="dependency-matrix", transform=f"translate({(width - 2800) / 2:g} {matrix_shift:g})")
    # Accept both legacy flat SVGs and this formatter's grouped SVGs.
    old_matrix_group = by_id.get("dependency-matrix")
    if old_matrix_group is not None:
        matrix_elements = list(old_matrix_group)
        # Grouped source retains original local coordinates; use its local heading.
        matrix_group.set("transform", f"translate({(width - 2800) / 2:g} {matrix_heading - original_matrix_heading:g})")
    else:
        children = list(old_root)
        matrix_elements = children[children.index(old_matrix):]
    for original in matrix_elements:
        copied = deepcopy(original)
        for n in copied.iter(S + "text"):
            if n.text and "Diagram revision:" in n.text:
                n.text = meta.get("matrix_footer", f"Source: phronomy-0.26.0-design-review.md, section {review_section}. Diagram revision: {config['diagram_revision']} | APPLIED SOURCE.")
        matrix_group.append(copied)
    # Footer-independent sizing also makes repeated formatting idempotent.
    local_footer_max = max(float(n.get("y")) for n in matrix_group.iter(S + "text") if n.get("y"))
    height = int(matrix_heading - original_matrix_heading + local_footer_max + 68)
    root.set("height", str(height))
    root.set("viewBox", f"0 0 {width} {height}")
    root.find(S + "rect").set("height", str(height))
    meta.update(diagram_revision=config["diagram_revision"],
        view=meta.get("view_label", f"applied Refactor {applied_refactor}; responsibility groups and distributed connections"),
        relocated_node_ids=sorted(modules), new_node_ids=[],
        formatting={"format": config["format"], "configuration": config,
            "display_layers": bands, "layout_is_dependency_policy": False,
            "source_anchor": "boundary" if transparent else "center, covered by opaque source box",
            "target_anchor": "boundary" if transparent else "center, with triangle at the visible boundary",
            "ports": "distinct per node face across incoming and outgoing edges", "arrowhead": "filled triangle",
            "group_fills": "pastel backgrounds behind all edges; same group ID keeps its palette across phases",
            "matrix_order": "preserved", "ownership_frames": "connected pieces; repeated group labels retain the same owner"},
        edge_presentation={"rule": "Common-target dependencies use light gray behind other edges; no coordinate-based rules",
            **config["background"], "edge_count": len(back),
            "hidden_incoming_targets": sorted(hidden_targets), "hidden_edges": hidden_count,
            "visible_edges": len(visible_edges), "transparent_text_panels": transparent, "paint_order": ["common-background-edges", "primary-dependency-edges"], "matrix_unchanged": True})
    meta["notes_ja"] = [
        "B1〜B6 の横帯・分野別の列・右側の補助領域を復元。G 番号は責務を示し、境界検査は配置ではなく責務に基づく。",
        "現状の混在ディレクトリを明示。構想図と実測図を区別し、分離前の依存もすべて残す。",
        "全依存対・行列・根拠リンクを維持。Engine と Backend Contracts は独立した責務。"
    ]
    if hidden_targets:
        meta["notes_ja"].append("共通定義への指定矢印は表示のみ非表示。解析データ・全依存行列・根拠を保持。")
    metadata_node.text = json.dumps(meta, ensure_ascii=False)

    # Verify the presentation change does not silently change the reviewed graph.
    assert meta["commit"] == old["commit"] and meta["source_tree"] == old["source_tree"]
    assert meta["edges"] == old["edges"] and meta["groups"] == old["groups"] and meta["stats"] == old["stats"]
    assert {m["id"]: m["group"] for m in meta["modules"]} == {m["id"]: m["group"] for m in old["modules"]}
    hrefs = lambda r: Counter(n.get(X + "href") for n in r.iter(S + "a"))
    assert hrefs(root) == hrefs(old_root)
    before_cells = {n.get("id"): ET.tostring(n) for n in old_root.iter() if n.get("class") == "matrix-cell"}
    after_cells = {n.get("id"): ET.tostring(n) for n in root.iter() if n.get("class") == "matrix-cell"}
    assert before_cells == after_cells
    node_ids = [n.get("id") for n in root.iter() if n.get("id")]
    assert len(node_ids) == len(set(node_ids))
    assert len(back) == sum(r["background"] for r in routing_records)
    assert len(normal) + len(back) == len(edges)
    assert len(list(root.iter(S + "polygon"))) == len(edges)
    assert list(root).index(edge_root) < list(root).index(nodes)
    assert list(root).index(group_backgrounds) < list(root).index(edge_root)
    assert all(0 < x < width and 430 < y < graph_bottom + 30
               for route in routing_records for x, y in route["control_points"])
    for key, items in incidence.items():
        values = [port_offsets[i[2], i[3], i[4]] for i in items]
        assert len(values) == len(set(values)), key
    rendered = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(rendered)
    validation = {"commit": meta["commit"], "revision": meta["diagram_revision"], "modules": len(modules),
        "edges": len(edges), "filled_triangles": len(edges), "background_edges": len(back), "primary_edges": len(normal),
        "evidence_anchors": sum(hrefs(root).values()), "source_links": sum(1 for n in root.iter(S + "a") if n.get(X + "href")), "matrix_cells_identical": len(before_cells),
        "source_graph_unchanged": True, "source_centers_hidden_by_nodes": not transparent, "paths_end_at_boundaries": transparent,
        "hidden_edges": hidden_count, "visible_edges": len(visible_edges), "visible_filled_triangles": len(visible_edges), "ports_unique_on_each_face": True,
        "width": width, "height": height, "sha256": hashlib.sha256(rendered).hexdigest(), "routes": routing_records}
    validation["route_kinds"] = dict(Counter(r["route_kind"] for r in routing_records))
    if validation_path:
        validation_path.write_text(json.dumps(validation, indent=2) + "\n")
    print(json.dumps({k: v for k, v in validation.items() if k != "routes"}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_svg", type=Path)
    parser.add_argument("output_svg", type=Path)
    parser.add_argument("--layout", type=Path, default=Path(__file__).with_name("layout.json"))
    parser.add_argument("--validation", type=Path)
    args = parser.parse_args()
    format_svg(args.input_svg, args.output_svg, args.layout, args.validation)


if __name__ == "__main__":
    main()
