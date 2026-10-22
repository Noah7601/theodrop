#!/usr/bin/env python3
"""Prints the files of a macOS payload in signing order, NUL separated.

codesign seals nested code before its container, so the deepest paths go first and the entry
points (passed as extra arguments) are left out: the caller signs those last, then the bundle.

Usage: build/tools/sign-order.py <payload-dir> [entry-point ...]
"""
import os
import sys

payload = sys.argv[1]
entries = {os.path.join(payload, name) for name in sys.argv[2:]}
files = [os.path.join(parent, name) for parent, _, names in os.walk(payload) for name in names]
files = sorted((path for path in files if path not in entries), key=len, reverse=True)
sys.stdout.write("".join(path + "\0" for path in files))
