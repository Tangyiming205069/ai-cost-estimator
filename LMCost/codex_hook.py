"""Opt-in PostModelRequest stdin sink. No network, transcript reads or config edits."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
from engine import Ledger, codex_event

def receive(data, stream):
    # Default closed. Do not read stdin until native UI consent lease is valid.
    try:
        lease=json.loads((data/'codex-consent.json').read_text())
        expiry=lease.get('expires')
        if not isinstance(expiry,(int,float)) or not time.time() < expiry <= time.time()+15:
            return 'disabled'
    except (OSError,ValueError,TypeError):
        return 'disabled'
    ledger=Ledger(data/'usage.sqlite3')
    try:
        raw=stream.read(262145)
        if len(raw)>262144:
            ledger.reject('oversize');return 'rejected'
        try:
            payload=json.loads(raw)
            e=codex_event(payload)
        except (ValueError,TypeError,RecursionError) as ex:
            reason=str(ex) if str(ex) in ('missing_attempt_identity','unsupported_event') else 'invalid_payload'
            ledger.reject(reason);return 'rejected'
        del payload, raw
        return 'added' if ledger.add(e) else 'duplicate'
    finally:
        ledger.close()

def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser()
    parser.add_argument('--data',required=True,type=Path)
    args=parser.parse_args()
    try:
        receive(args.data,sys.stdin.buffer)
    except Exception:
        # Never print provider payload/error text, never interrupt the user's turn.
        pass
    print('{}')

if __name__=='__main__':main()
