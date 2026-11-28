#!/usr/bin/env python3
"""Render the two exact DOT views with globally distinct SVG element IDs."""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    receipt = args.receipt.resolve()
    if receipt == root or root in receipt.parents:
        parser.error("--receipt must be outside the model source directory")
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
    version = subprocess.run(["dot", "-V"], capture_output=True, text=True, check=True)
    results = []
    for name, prefix in (("terminal-routing", "htf-routing-"), ("terminal-client", "htf-client-")):
        source = root / (name + ".dot")
        command = ["dot", "-Tsvg", str(source)]
        raw = subprocess.run(command, capture_output=True, check=True).stdout
        svg = ET.fromstring(raw)
        ids = [node.attrib["id"] for node in svg.iter() if "id" in node.attrib]
        if len(ids) != len(set(ids)):
            raise ValueError("Graphviz emitted duplicate element IDs")
        replacements = {value: prefix + value for value in ids}
        for node in svg.iter():
            for key, value in list(node.attrib.items()):
                if key == "id":
                    value = replacements[value]
                else:
                    value = re.sub(r"url\(#([^)]+)\)", lambda m: "url(#" + replacements[m[1]] + ")", value)
                    if key.rsplit("}", 1)[-1] == "href" and value.startswith("#"):
                        value = "#" + replacements[value[1:]]
                node.set(key, value)
        rendered = ET.tostring(svg, encoding="utf-8", xml_declaration=True) + b"\n"
        output = root / (name + ".svg")
        output.write_bytes(rendered)
        results.append({"source": str(source), "source_sha256": digest(source.read_bytes()),
                        "command": command, "raw_svg_sha256": digest(raw),
                        "output": str(output), "output_sha256": digest(rendered),
                        "id_prefix": prefix, "id_count": len(ids)})
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({"graphviz_version": (version.stdout + version.stderr).strip(),
                                   "rewrite_script": str(pathlib.Path(__file__).resolve()),
                                   "rewrite_script_sha256": digest(pathlib.Path(__file__).read_bytes()),
                                   "diagrams": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()
