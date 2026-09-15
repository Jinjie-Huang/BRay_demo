#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import argparse
import collections
import json
import pathlib
import struct
import subprocess
import sys


def parse_args():
    parser = argparse.ArgumentParser(
        description="Symbolize a BRay raw trace and write Chrome Trace JSON."
    )
    parser.add_argument("--raw", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--symbolizer", required=True, type=pathlib.Path)
    return parser.parse_args()


def fallback_name(pc):
    return f"0x{pc:x}"


def is_position_independent(module):
    if not module or not pathlib.Path(module).is_file():
        return True
    with pathlib.Path(module).open("rb") as stream:
        header = stream.read(18)
    if len(header) < 18 or header[:4] != b"\x7fELF":
        return True
    byte_order = "<" if header[5] == 1 else ">"
    elf_type = struct.unpack(f"{byte_order}H", header[16:18])[0]
    return elf_type != 2


def symbolize_module(symbolizer, module, offsets):
    if not module or not pathlib.Path(module).is_file():
        return {offset: fallback_name(offset) for offset in offsets}

    command = [
        str(symbolizer),
        f"--obj={module}",
        "--functions=linkage",
        "--demangle",
        "--inlining=false",
        "--output-style=JSON",
    ]
    input_data = "".join(f"0x{offset:x}\n" for offset in offsets)
    try:
        result = subprocess.run(
            command,
            input=input_data,
            text=True,
            capture_output=True,
            check=True,
        )
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            f"llvm-symbolizer failed for {module}: {error.stderr.strip()}"
        ) from error
    lines = [line for line in result.stdout.splitlines() if line]
    if len(lines) != len(offsets):
        raise RuntimeError(
            f"llvm-symbolizer returned {len(lines)} results for "
            f"{len(offsets)} addresses in {module}"
        )

    names = {}
    for offset, line in zip(offsets, lines):
        record = json.loads(line)
        symbols = record.get("Symbol", [])
        name = symbols[0].get("FunctionName", "") if symbols else ""
        names[offset] = name if name and name != "??" else fallback_name(offset)
    return names


def symbolize_events(events, symbolizer):
    offsets_by_module = collections.defaultdict(set)
    position_independent = {}
    for event in events:
        pc = int(event["pc"], 16)
        base = int(event["module_base"], 16)
        module = event["module"]
        if module not in position_independent:
            position_independent[module] = is_position_independent(module)
        event["offset"] = pc - base if position_independent[module] else pc
        offsets_by_module[event["module"]].add(event["offset"])

    names = {}
    for module, offsets in offsets_by_module.items():
        ordered_offsets = sorted(offsets)
        for offset, name in symbolize_module(
            symbolizer, module, ordered_offsets
        ).items():
            names[(module, offset)] = name

    for event in events:
        event["name"] = names.get(
            (event["module"], event["offset"]), fallback_name(int(event["pc"], 16))
        )


def write_chrome_trace(raw_trace, output):
    events = raw_trace["events"]
    pid = raw_trace["pid"]
    roots = list(aggregate_call_tree(events))

    trace_events = [
        {
            "name": "process_name",
            "ph": "M",
            "pid": pid,
            "tid": 0,
            "args": {"name": "BRay aggregated call tree"},
        },
        {
            "name": "thread_name",
            "ph": "M",
            "pid": pid,
            "tid": 0,
            "args": {"name": "aggregated calls"},
        },
    ]

    def append_node(node, start_ns):
        duration_ns = node["duration_ns"]
        trace_events.append(
            {
                "name": node["name"],
                "cat": "BRay",
                "ph": "X",
                "pid": pid,
                "tid": 0,
                "ts": start_ns // 1000,
                "dur": duration_ns // 1000,
                "args": {
                    "calls": node["calls"],
                    "total_inclusive_us": duration_ns // 1000,
                    "total_exclusive_us": node["exclusive_ns"] // 1000,
                    "average_inclusive_us": duration_ns // node["calls"] // 1000,
                    "function_pc": node["pc"],
                    "module": node["module"],
                    "module_offset": f"0x{node['offset']:x}",
                },
            }
        )

        child_start_ns = start_ns
        children_duration_ns = 0
        for child in node["children"].values():
            append_node(child, child_start_ns)
            child_start_ns += child["duration_ns"]
            children_duration_ns += child["duration_ns"]
        if children_duration_ns > duration_ns:
            raise RuntimeError(
                f"children exceed parent duration for {node['name']}"
            )

    root_start_ns = 0
    for root in roots:
        append_node(root, root_start_ns)
        root_start_ns += root["duration_ns"]

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as stream:
        json.dump(
            {"displayTimeUnit": "ms", "traceEvents": trace_events},
            stream,
            indent=2,
        )
        stream.write("\n")
    return len(trace_events) - 2


def aggregate_call_tree(events):
    roots = {}
    stacks = collections.defaultdict(list)
    ordered_events = sorted(
        events,
        key=lambda event: (
            event["tid"],
            event["start_ns"],
            -event["duration_ns"],
        ),
    )

    for event in ordered_events:
        depth = event["depth"]
        stack = stacks[event["tid"]]
        if depth > len(stack):
            raise RuntimeError(
                f"invalid call depth {depth} for thread {event['tid']}"
            )
        del stack[depth:]

        siblings = roots if depth == 0 else stack[-1]["children"]
        key = (event["module"], event["offset"])
        node = siblings.get(key)
        if node is None:
            node = {
                "name": event["name"],
                "pc": event["pc"],
                "module": event["module"],
                "offset": event["offset"],
                "calls": 0,
                "duration_ns": 0,
                "exclusive_ns": 0,
                "children": {},
            }
            siblings[key] = node

        node["calls"] += 1
        node["duration_ns"] += event["duration_ns"]
        node["exclusive_ns"] += event["exclusive_ns"]
        stack.append(node)

    return roots.values()


def print_call_tree(events):
    print(
        "[BRay] aggregated call tree "
        "(total inclusive / self, average inclusive, calls):",
        file=sys.stderr,
    )

    def print_node(node, depth):
        duration_ms = node["duration_ns"] / 1_000_000
        exclusive_ms = node["exclusive_ns"] / 1_000_000
        average_ms = duration_ms / node["calls"]
        indentation = " " * (depth * 2)
        print(
            f"[BRay] {indentation}{node['name']} "
            f"{duration_ms:.3f} ms / {exclusive_ms:.3f} ms, "
            f"avg {average_ms:.3f} ms, calls={node['calls']}",
            file=sys.stderr,
        )
        for child in node["children"].values():
            print_node(child, depth + 1)

    for root in aggregate_call_tree(events):
        print_node(root, 0)


def main():
    args = parse_args()
    with args.raw.open() as stream:
        raw_trace = json.load(stream)

    events = raw_trace["events"]
    symbolize_events(events, args.symbolizer)
    trace_nodes = write_chrome_trace(raw_trace, args.output)
    print_call_tree(events)
    print(
        f"[BRay] aggregated {len(events)} raw function events into "
        f"{trace_nodes} trace nodes in {args.output}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
