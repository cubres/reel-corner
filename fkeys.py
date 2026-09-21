#!/usr/bin/env python3
"""Set up the bare function keys Reel Corner needs, without disturbing your other keys.

On a Mac with "Use F1, F2 etc. as standard function keys" switched OFF, pressing F9
does not send F9 - the keyboard driver sends a media action instead, so a shortcut
bound to F9 would simply never fire. Turning that setting on is the obvious fix and
is usually the wrong one: it costs you brightness and volume on a bare press.

Instead this remaps only the specific keys you have bound, using the driver's own
table of what each function key emits. Everything else keeps working. The mapping is
merged into whatever `hidutil` setup already exists, because `hidutil --set` replaces
the entire table - writing ours blindly would silently break other remapped keys.
"""
import json, os, plistlib, re, subprocess, sys

HOME = os.path.expanduser("~")
CONFIG = f"{HOME}/Library/Application Support/ReelCorner/config.json"
STATE = f"{HOME}/Library/Application Support/ReelCorner/managed-fkeys.json"
AGENTS = f"{HOME}/Library/LaunchAgents"
OUR_AGENT = f"{AGENTS}/com.reelcorner.fkeys.plist"
EXISTING_AGENT = f"{AGENTS}/com.user.fkey-remap.plist"

FKEY_USAGE = {n: 0x39 + n for n in range(1, 13)}          # F1 = 0x3A ... F12 = 0x45


def fn_state_on():
    try:
        out = subprocess.run(["defaults", "read", "-g", "com.apple.keyboard.fnState"],
                             capture_output=True, text=True).stdout.strip()
        return out == "1"
    except Exception:
        return False


def driver_map():
    """{F-key number: full HID usage it actually emits} from the driver's own table."""
    out = subprocess.run(["ioreg", "-c", "AppleHIDKeyboardEventDriverV2", "-r", "-d", "1", "-l"],
                         capture_output=True, text=True).stdout
    m = re.search(r'"FnFunctionUsageMap" = "([^"]*)"', out)
    if not m:
        return {}
    vals = [v.strip() for v in m.group(1).split(",")]
    table = {}
    for i in range(0, len(vals) - 1, 2):
        try:
            fkey, emitted = int(vals[i], 16), int(vals[i + 1], 16)
        except ValueError:
            continue
        usage = fkey & 0xFFFF
        for n, u in FKEY_USAGE.items():
            if usage == u:
                page, code = emitted >> 16, emitted & 0xFFFF
                table[n] = (page << 32) | code
    return table


def wanted_fkeys():
    """F-key numbers bound WITHOUT modifiers in config.json."""
    try:
        raw = re.sub(r'^\s*//.*$', '', open(CONFIG).read(), flags=re.M)
        keys = json.loads(raw).get("keys", {})
    except Exception:
        keys = {"next": "F9", "like": "F7", "save": "F8"}
    out = set()
    for combo in keys.values():
        parts = [p.strip().lower() for p in str(combo).split("+") if p.strip()]
        if len(parts) == 1 and re.fullmatch(r"f([1-9]|1[0-2])", parts[0]):
            out.add(int(parts[0][1:]))
    return sorted(out)


def live_mappings():
    out = subprocess.run(["hidutil", "property", "--get", "UserKeyMapping"],
                         capture_output=True, text=True).stdout
    src = [int(x) for x in re.findall(r"HIDKeyboardModifierMappingSrc\s*=\s*(\d+)", out)]
    dst = [int(x) for x in re.findall(r"HIDKeyboardModifierMappingDst\s*=\s*(\d+)", out)]
    return dict(zip(src, dst))


def agent_path():
    return EXISTING_AGENT if os.path.exists(EXISTING_AGENT) else OUR_AGENT


def write_agent(mapping):
    payload = json.dumps({"UserKeyMapping": [
        {"HIDKeyboardModifierMappingSrc": s, "HIDKeyboardModifierMappingDst": d}
        for s, d in sorted(mapping.items())
    ]})
    args = ["/usr/bin/hidutil", "property", "--set", payload]
    path = agent_path()
    label = os.path.basename(path)[:-6]
    data = {"Label": label, "ProgramArguments": args, "RunAtLoad": True}
    if os.path.exists(path):
        try:
            data = {**plistlib.load(open(path, "rb")), "ProgramArguments": args}
        except Exception:
            pass
    with open(path, "wb") as f:
        plistlib.dump(data, f)
    subprocess.run(["hidutil", "property", "--set", payload],
                   capture_output=True, text=True)
    return path


def install():
    keys = wanted_fkeys()
    if not keys:
        print("    No bare F-keys bound - nothing to remap.")
        return
    if fn_state_on():
        print("    Function keys are already standard on this Mac - nothing to remap.")
        return
    table = driver_map()
    ours = {}
    for n in keys:
        if n not in table:
            print(f"    F{n} already sends a real F{n} - no remap needed.")
            continue
        ours[table[n]] = 0x700000000 | FKEY_USAGE[n]

    merged = live_mappings()
    merged.update(ours)
    path = write_agent(merged)

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump({"srcs": sorted(ours)}, open(STATE, "w"))

    names = ", ".join(f"F{n}" for n in keys)
    print(f"    Remapped {names} to send real function keys ({len(merged)} total mappings kept).")
    print(f"    Persisted in {path}")
    print(f"    Those keys no longer send their media action; ./uninstall.sh gives it back.")


def uninstall():
    try:
        ours = set(json.load(open(STATE)).get("srcs", []))
    except Exception:
        print("    Nothing recorded - leaving key mappings alone.")
        return
    merged = {s: d for s, d in live_mappings().items() if s not in ours}
    if merged:
        write_agent(merged)
        print(f"    Removed our key mappings, kept {len(merged)} others.")
    else:
        subprocess.run(["hidutil", "property", "--set", '{"UserKeyMapping":[]}'],
                       capture_output=True)
        for p in (OUR_AGENT,):
            if os.path.exists(p):
                os.remove(p)
        print("    Removed our key mappings.")
    os.remove(STATE)


if __name__ == "__main__":
    {"install": install, "uninstall": uninstall}[sys.argv[1] if len(sys.argv) > 1 else "install"]()
