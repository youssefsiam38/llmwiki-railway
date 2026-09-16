"""Run an ASGI app with uvicorn on one dual-stack socket (IPv6 and IPv4 on the same port).

Railway's private network is IPv6 and its public edge connects over IPv4. `uvicorn --host ::` is IPv6 only,
because asyncio marks IPv6 listening sockets IPV6_V6ONLY, and uvicorn takes a single host. So the socket is
made here, with IPV6_V6ONLY off, and handed to uvicorn.

    python serve.py main:app [--proxy-headers] [--timeout-graceful-shutdown N]

The port comes from PORT; FORWARDED_ALLOW_IPS is read by uvicorn itself.
"""

import argparse
import asyncio
import os
import socket
import sys

import uvicorn

# Import the app from the working directory, as `uvicorn main:app` would, not from this script's directory.
sys.path.insert(0, os.getcwd())

parser = argparse.ArgumentParser()
parser.add_argument("app")
parser.add_argument("--proxy-headers", action="store_true")
parser.add_argument("--timeout-graceful-shutdown", type=int, default=None)
args = parser.parse_args()

port = int(os.environ.get("PORT", "8000"))
sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
sock.bind(("::", port))
sock.set_inheritable(True)

config = uvicorn.Config(
    args.app,
    proxy_headers=args.proxy_headers,
    timeout_graceful_shutdown=args.timeout_graceful_shutdown,
)
server = uvicorn.Server(config)
asyncio.run(server.serve(sockets=[sock]))
