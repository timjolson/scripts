#!/usr/bin/env python3
"""Check shell script balancing, non-printable bytes and per-`case`-arm syntax.

Usage: check_sh_syntax.py <script-path>

Produces a summary of control-token counts, any control/non-printable bytes,
unmatched block stack (if/for/case), and runs `bash -n` against each `case`
arm to find localized parse errors.
"""
import argparse
import hashlib
import os
import re
import shlex
import subprocess
import sys
from tempfile import NamedTemporaryFile


HEREDOC_RE = re.compile(r'<<-?\s*(?:"([^"]+)"|\'([^\']+)\'|([A-Za-z_][A-Za-z0-9_]*))')
KW_TOKENS = ['if','then','elif','fi','for','while','until','do','done','case','esac']


def hexdigest(path):
    h = hashlib.md5()
    with open(path,'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            h.update(chunk)
    return h.hexdigest()


def find_control_bytes(path):
    data = open(path,'rb').read()
    bad = []
    for i, b in enumerate(data):
        if (b < 32 and b not in (9,10,13)) or b == 127:
            bad.append((i, b))
    return {'size': len(data), 'nuls': data.count(b'\x00'), 'crs': data.count(b'\r'), 'bad': bad}


def mask_quotes_and_comments(line):
    out = []
    i = 0
    in_s = False
    in_d = False
    while i < len(line):
        c = line[i]
        if c == "'" and not in_d:
            in_s = not in_s
            out.append(' ')
        elif c == '"' and not in_s:
            in_d = not in_d
            out.append(' ')
        elif c == '#' and not in_s and not in_d:
            break
        else:
            out.append(' ' if (in_s or in_d) else c)
        i += 1
    return ''.join(out)


def scan_tokens(path, upto_line=None):
    stack = []
    counts = {k:0 for k in KW_TOKENS}
    with open(path) as f:
        in_heredoc = None
        heredoc_delim = ''
        for lineno, raw in enumerate(f, start=1):
            if upto_line and lineno > upto_line:
                break
            line = raw.rstrip('\n')
            if in_heredoc:
                if line.strip() == heredoc_delim:
                    in_heredoc = None
                    heredoc_delim = ''
                continue
            # don't treat here-strings (<<<) as heredoc
            if '<<<' not in line:
                m = HEREDOC_RE.search(line)
                if m:
                    delim = m.group(1) or m.group(2) or m.group(3)
                    in_heredoc = True
                    heredoc_delim = delim
                    line = line[:m.start()]
            s = mask_quotes_and_comments(line)
            # token find
            for tok in KW_TOKENS:
                for _ in re.finditer(r'(?<![A-Za-z0-9_-])' + re.escape(tok) + r'(?![A-Za-z0-9_-])', s):
                    counts[tok] += 1
                    # maintain stack for matching checks
                    if tok == 'if':
                        stack.append(('if', lineno))
                    elif tok in ('for','while','until'):
                        stack.append((tok, lineno))
                    elif tok == 'case':
                        stack.append(('case', lineno))
                    elif tok == 'fi':
                        if stack and stack[-1][0] == 'if':
                            stack.pop()
                        else:
                            stack.append(('UNMATCHED_fi', lineno))
                    elif tok == 'done':
                        if stack and stack[-1][0] in ('for','while','until'):
                            stack.pop()
                        else:
                            stack.append(('UNMATCHED_done', lineno))
                    elif tok == 'esac':
                        if stack and stack[-1][0] == 'case':
                            stack.pop()
                        else:
                            stack.append(('UNMATCHED_esac', lineno))
    return counts, stack


def extract_case_arms(path):
    lines = open(path).read().splitlines()
    case_start = None
    for i, line in enumerate(lines):
        if re.match(r'^\s*case\b.*\bin\b', line):
            case_start = i
            break
    if case_start is None:
        return None
    # find matching esac
    depth = 0
    esac_idx = None
    for i in range(case_start, len(lines)):
        t = re.sub(r"(['\"]).*?\1", ' ', lines[i])
        t = re.sub(r"#.*$", ' ', t)
        if re.search(r'\bcase\b', t): depth += 1
        if re.search(r'\besac\b', t):
            depth -= 1
            if depth == 0:
                esac_idx = i
                break
    if esac_idx is None:
        return None
    # collect labels
    labels = []
    for i in range(case_start+1, esac_idx):
        stripped = lines[i].strip()
        if not stripped or stripped.startswith('#'):
            continue
        if stripped.endswith(')') and ('=' not in lines[i]):
            labels.append((i, stripped))
    if not labels:
        return []
    indices = [idx for idx, _ in labels] + [esac_idx]
    arms = []
    for n, (idx, label) in enumerate(labels):
        next_idx = indices[n+1]
        block = lines[idx:next_idx]
        arms.append((label, idx+1, block))
    return arms


def test_case_arm(block_lines):
    # build minimal case wrapper and run bash -n
    with NamedTemporaryFile('w', delete=False, prefix='case_arm_', suffix='.sh') as tf:
        tf.write('#!/bin/bash\nset -n\n')
        tf.write('case X in\n')
        for L in block_lines:
            tf.write(L + '\n')
        tf.write('esac\n')
        tf.flush()
        path = tf.name
    try:
        p = subprocess.run(['bash','-n',path], capture_output=True, text=True)
        return p.returncode == 0, p.stderr
    finally:
        try:
            os.unlink(path)
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description='Check shell script balancing and per-case-arm syntax')
    ap.add_argument('path')
    args = ap.parse_args()
    path = args.path
    if not os.path.isfile(path):
        print('Not a file:', path, file=sys.stderr); return 2

    print('File:', path)
    print('Size:', os.path.getsize(path), 'bytes    md5:', hexdigest(path))

    cb = find_control_bytes(path)
    print('\nControl bytes: size={size} nuls={nuls} CRs={crs} bad_count={bad}'.format(**cb))
    if cb['bad']:
        for pos, b in cb['bad'][:40]:
            print(' bad byte at pos', pos, '0x%02x' % b)

    counts, stack = scan_tokens(path)
    print('\nToken counts:')
    for k in KW_TOKENS:
        print(f'  {k}: {counts.get(k,0)}')

    if stack:
        print('\nRemaining/open/unmatched stack (top last):')
        for t, ln in stack:
            print(' ', t, 'at line', ln)
    else:
        print('\nNo unmatched control blocks detected by the scanner.')

    arms = extract_case_arms(path)
    if arms is None:
        print('\nNo `case ... in` block found.')
    elif not arms:
        print('\n`case` block found but no arms detected.')
    else:
        print('\nTesting', len(arms), 'case arms with `bash -n`')
        for label, start_line, block in arms:
            ok, err = test_case_arm(block)
            print(f' ARM starting line {start_line}: {label} ->', 'OK' if ok else 'ERROR')
            if err:
                print(err.strip())

    return 0


if __name__ == '__main__':
    sys.exit(main())
