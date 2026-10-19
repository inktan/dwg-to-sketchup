# coding: utf-8
# IronPython 2.7 bridge inside the already-open Rhino. Listens on 127.0.0.1:2000.
import json
import socket
import struct
import threading
import traceback
import System
import Eto.Forms as EtoForms
import Rhino
import scriptcontext as sc

HOST = "127.0.0.1"
PORT = 2000
LOG = r"C:\Users\wang.tan\AppData\Local\Temp\rhinomcp_bridge.log"


def log(msg):
    handle = open(LOG, "a")
    try:
        handle.write(str(msg) + "\n")
        handle.flush()
    finally:
        handle.close()


def ui(fn):
    holder = {}

    def wrapped():
        try:
            holder["value"] = fn()
        except Exception as exc:
            holder["error"] = traceback.format_exc()
            holder["message"] = str(exc)

    EtoForms.Application.Instance.Invoke(System.Action(wrapped))
    if "error" in holder:
        raise Exception(holder.get("message") or holder["error"])
    return holder.get("value")


def handle(cmd):
    ctype = cmd.get("type")
    params = cmd.get("params") or {}
    if ctype == "get_document_summary":
        def read():
            doc = sc.doc
            return {
                "object_count": sum(1 for _obj in doc.Objects),
                "unit_system": str(doc.ModelUnitSystem),
                "name": doc.Name or "",
                "path": doc.Path or "",
            }
        return {"status": "success", "result": ui(read)}
    if ctype == "describe_capabilities":
        return {
            "status": "success",
            "result": {"commands": ["get_document_summary", "describe_capabilities", "run_command"]},
        }
    if ctype == "run_command":
        command = params.get("command") or ""

        def run():
            ok = Rhino.RhinoApp.RunScript(command, False)
            return {"success": bool(ok), "command": command}

        return {"status": "success", "result": ui(run)}
    return {"status": "error", "message": "Unknown command type: %s" % ctype}


def recv_exact(conn, count):
    buf = ""
    while len(buf) < count:
        chunk = conn.recv(count - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def serve(conn):
    try:
        while True:
            header = recv_exact(conn, 4)
            if not header:
                break
            length = struct.unpack(">I", header)[0]
            if length <= 0 or length > 8000000:
                break
            body = recv_exact(conn, length)
            if body is None:
                break
            try:
                cmd = json.loads(body.decode("utf-8"))
                log("command " + str(cmd.get("type")))
                reply = handle(cmd)
            except Exception as exc:
                log(traceback.format_exc())
                reply = {"status": "error", "message": str(exc)}
            payload = json.dumps(reply).encode("utf-8")
            conn.sendall(struct.pack(">I", len(payload)) + payload)
    except Exception:
        log(traceback.format_exc())
    finally:
        try:
            conn.close()
        except Exception:
            pass


def loop():
    log("bridge v2 thread started on %s:%s" % (HOST, PORT))
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((HOST, PORT))
    sock.listen(5)
    log("listening on %s:%s" % (HOST, PORT))
    while True:
        conn, addr = sock.accept()
        log("client connected %s" % (addr,))
        try:
            serve(conn)
        finally:
            log("client disconnected")


log("bridge script started, python restart")
thread = threading.Thread(target=loop)
thread.daemon = False
thread.start()
