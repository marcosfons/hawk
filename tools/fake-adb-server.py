"""A minimal adb host server for perf scenarios: answers host:version, and
host:track-devices-l with one made-up device, then stays idle. Anything else
gets FAIL. Listens on 127.0.0.1 only."""
import socket
import sys
import threading


def framed(text):
    data = text.encode()
    return b"%04x" % len(data) + data


def serve(conn):
    try:
        header = conn.recv(4)
        length = int(header, 16)
        service = conn.recv(length).decode(errors="replace")
        if service == "host:version":
            conn.sendall(b"OKAY" + framed("0029"))
        elif service == "host:track-devices-l":
            conn.sendall(b"OKAY" + framed("FAKE0001               device usb:1-1 model:Fake_Phone transport_id:1\n"))
            while conn.recv(1024):
                pass
        else:
            conn.sendall(b"FAIL" + framed("unsupported by fake-adb"))
    except (OSError, ValueError):
        pass
    finally:
        conn.close()


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", int(sys.argv[1])))
    server.listen(8)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


main()
