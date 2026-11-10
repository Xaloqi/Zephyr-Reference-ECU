#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Xaloqi
"""Send a file to a shell on a serial console as base64, and check it by sha256.

    console-send.py FILE DEST [--dev /dev/serial/by-id/...] [--log LOGFILE] [--dry-run]

The shell on the other end (the Pi's DomD after Ctrl-A x3 on the Xen console) gets
`cat > DEST.b64`, the base64 lines, Ctrl-D, then `base64 -d`, `sha256sum -c`, `chmod 755`.
It needs only a POSIX shell, base64 and sha256sum (busybox has both). The result is
read from LOGFILE, the log a console logger keeps writing (bench/serial_log.py); this
tool never reads the device, so it does not steal bytes from that logger. Without
--log it only sends. Open the device by its /dev/serial/by-id path, never ttyACMn.

Prints the sha256 of FILE first: compare it with the one in the record.
"""
import argparse, base64, hashlib, os, sys, termios, time

CHUNK = 96          # base64 characters per line: short lines survive a UART
LINE_GAP_S = 0.05   # pause between data lines (115200 baud)
CMD_GAP_S = 1.0     # pause before each shell command: busybox ash's line editor asks the
                    # terminal for the cursor position (ESC[6n) and waits, nobody answers

def lines_for(data, dest):
    """(sha256, [(kind, text)]): data goes to `cat`, not to the shell, so the shell's
    line editor never sees it; Ctrl-D ends the cat, then two shell commands. Every
    typed line stays under 120 characters: the Xen console splits long lines."""
    sha = hashlib.sha256(data).hexdigest()
    b64 = base64.b64encode(data).decode()
    d, f = os.path.split(dest)
    out = [("cmd", "cd %s" % (d or ".")), ("cmd", "cat > %s.b64" % f)]
    for i in range(0, len(b64), CHUNK):
        out.append(("data", b64[i:i + CHUNK]))
    out.append(("eof", ""))
    out.append(("cmd", "base64 -d %s.b64 > %s && rm -f %s.b64" % (f, f, f)))
    out.append(("cmd", "echo '%s  %s' > %s.sha" % (sha, f, f)))
    out.append(("cmd", "sha256sum -c %s.sha && chmod 755 %s && echo SEND-OK %s" % (f, f, f)))
    return sha, out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file"); ap.add_argument("dest")
    ap.add_argument("--dev"); ap.add_argument("--log")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    data = open(a.file, "rb").read()
    sha, lines = lines_for(data, a.dest)
    print("sha256 %s  %s (%d bytes, %d lines)" % (sha, a.file, len(data), len(lines)))
    if a.dry_run:
        print("\n".join(t if k != "eof" else "<Ctrl-D>" for k, t in lines)); return 0
    if not a.dev:
        sys.exit("need --dev (or --dry-run)")
    if not a.dev.startswith("/dev/serial/by-id/") and not a.dev.startswith("/dev/pts/"):
        sys.exit("--dev must be a /dev/serial/by-id path (a ttyACMn number changes on re-plug)")
    start = os.path.getsize(a.log) if a.log else 0
    fd = os.open(a.dev, os.O_WRONLY | os.O_NOCTTY)
    for kind, text in lines:
        if kind == "cmd":
            time.sleep(CMD_GAP_S)
        if kind == "eof":
            time.sleep(0.5); os.write(fd, b"\x04")
        else:
            os.write(fd, (text + "\r").encode())
        time.sleep(LINE_GAP_S)
    termios.tcdrain(fd) if os.isatty(fd) else None
    os.close(fd)
    if not a.log:
        return 0
    want = "SEND-OK %s" % os.path.basename(a.dest)
    for _ in range(100):
        time.sleep(0.2)
        with open(a.log, "rb") as f:
            f.seek(start); tail = f.read().decode("utf-8", "replace")
        # the echoed command line contains the text too: the verdict is a line of its own
        if any(l.strip() == want for l in tail.splitlines()):
            print("OK: %s arrived and matches" % a.dest); return 0
        if "FAILED" in tail:
            print("FAIL: sha256 mismatch on the Pi"); return 1
    print("FAIL: no verdict in %s within 20 s (console not on a shell? check Ctrl-A x3)" % a.log); return 1

if __name__ == "__main__":
    sys.exit(main())
