#!/usr/bin/env python3
"""
tcp_check.py -- a TCP transfer checked end to end (used by demo/run_demo.sh)

    tcp_check.py server <ip>     accept one connection, read until EOF, reply with SHA-256
    tcp_check.py client <ip>     send 256 KB of random data, compare the reply

The client prints the throughput, which measures the simulation's speed, not
the switch's (see docs/linux_demo.md).
"""
import hashlib
import os
import socket
import sys
import time

PORT = 5001
SIZE = 256 * 1024


def server(ip):
    with socket.create_server((ip, PORT)) as s:
        s.settimeout(120)
        conn, _ = s.accept()
        with conn:
            h = hashlib.sha256()
            while chunk := conn.recv(65536):
                h.update(chunk)
            conn.sendall(h.hexdigest().encode())


def client(ip):
    data = os.urandom(SIZE)
    t0 = time.time()
    with socket.create_connection((ip, PORT), timeout=60) as s:
        s.sendall(data)
        s.shutdown(socket.SHUT_WR)
        reply = s.recv(64).decode()
    dt = time.time() - t0
    ok = reply == hashlib.sha256(data).hexdigest()
    print(f"{SIZE // 1024} KB in {dt:.1f} s ({SIZE * 8 / dt / 1e3:.0f} kb/s), SHA-256 {'matches' if ok else 'DIFFERS'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    {"server": server, "client": client}[sys.argv[1]](sys.argv[2])
