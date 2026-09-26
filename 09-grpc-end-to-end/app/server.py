"""The catalog service again - now over TLS, and refusing callers without a
client certificate signed by the enterprise CA (mutual TLS).

Each call logs WHO called: the identity in the caller's certificate. The only
caller that has one is Envoy.
"""
import os
import threading
from concurrent import futures

import grpc
from grpc_reflection.v1alpha import reflection

import catalog_pb2
import catalog_pb2_grpc

POD = os.environ.get("POD_NAME", "catalog")
PORT = int(os.environ.get("PORT", "50051"))
TLS = "/etc/tls"


def caller(context):
    """The identity from the caller's certificate: its URI SAN (SPIFFE ID)."""
    auth = context.auth_context()
    for key in ("peer_spiffe_id", "x509_subject_alternative_name", "x509_common_name"):
        if auth.get(key):
            return b",".join(auth[key]).decode()
    return "unknown"


class Catalog(catalog_pb2_grpc.CatalogServicer):
    def __init__(self):
        self._lock = threading.Lock()
        self._items = {
            "widget": catalog_pb2.Item(sku="widget", name="Widget", on_hand=10),
            "gadget": catalog_pb2.Item(sku="gadget", name="Gadget", on_hand=3),
        }

    def ListItems(self, request, context):
        print("%s ListItems caller=%s" % (POD, caller(context)), flush=True)
        with self._lock:
            return catalog_pb2.ListItemsResponse(items=list(self._items.values()))

    def GetItem(self, request, context):
        print("%s GetItem sku=%s caller=%s" % (POD, request.sku, caller(context)), flush=True)
        with self._lock:
            item = self._items.get(request.sku)
        if item is None:
            context.abort(grpc.StatusCode.NOT_FOUND, "no item with sku %r" % request.sku)
        return item

    def ReserveStock(self, request, context):
        print("%s ReserveStock sku=%s quantity=%d caller=%s"
              % (POD, request.sku, request.quantity, caller(context)), flush=True)
        if request.quantity <= 0:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "quantity must be positive")
        with self._lock:
            item = self._items.get(request.sku)
            if item is None:
                context.abort(grpc.StatusCode.NOT_FOUND, "no item with sku %r" % request.sku)
            if item.on_hand < request.quantity:
                context.abort(grpc.StatusCode.FAILED_PRECONDITION,
                              "only %d %s left" % (item.on_hand, request.sku))
            item.on_hand -= request.quantity
            return item


def read(name):
    with open(os.path.join(TLS, name), "rb") as f:
        return f.read()


def main():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    catalog_pb2_grpc.add_CatalogServicer_to_server(Catalog(), server)
    reflection.enable_server_reflection(
        (catalog_pb2.DESCRIPTOR.services_by_name["Catalog"].full_name, reflection.SERVICE_NAME),
        server)
    # The server's own certificate, and the CA it trusts for CLIENT
    # certificates. require_client_auth=True is what makes this mutual TLS: a
    # caller without a certificate signed by that CA cannot even connect.
    credentials = grpc.ssl_server_credentials(
        [(read("tls.key"), read("tls.crt"))],
        root_certificates=read("ca.crt"),
        require_client_auth=True)
    server.add_secure_port("0.0.0.0:%d" % PORT, credentials)
    server.start()
    print("catalog (gRPC over mutual TLS) listening on :%d as %s" % (PORT, POD), flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
