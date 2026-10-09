"""An HTTPS proxy that loses the network after a byte budget.

It relays CONNECT tunnels until the bytes sent back to clients reach the
budget, then drops every tunnel and refuses new ones, as a link that goes
down mid-download would. It prints its port, then serves until killed.
Usage: python3 -I cut-proxy.py BUDGET_BYTES
"""

import select
import socket
import sys
import threading

budget = int(sys.argv[1])
lock = threading.Lock()
state = {"sent": 0, "down": False}


def relay(client):
    upstream = None
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = client.recv(4096)
            if not chunk:
                return
            request += chunk
        line = request.split(b"\r\n", 1)[0].decode("latin-1").split()
        if state["down"] or len(line) < 2 or line[0] != "CONNECT":
            return
        host, _, port = line[1].rpartition(":")
        upstream = socket.create_connection((host, int(port)), timeout=30)
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        sockets = [client, upstream]
        while not state["down"]:
            readable, _, _ = select.select(sockets, [], [], 1)
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                target = upstream if source is client else client
                if target is client:
                    with lock:
                        state["sent"] += len(data)
                        if state["sent"] >= budget:
                            state["down"] = True
                            return
                target.sendall(data)
    except OSError:
        return
    finally:
        client.close()
        if upstream is not None:
            upstream.close()


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(64)
print(server.getsockname()[1], flush=True)
while True:
    connection, _ = server.accept()
    threading.Thread(target=relay, args=(connection,), daemon=True).start()
