"""The catalog service: gRPC only, in memory.

It knows nothing about HTTP routes or JSON. Everything REST about it is added by
Envoy in front - which is the point of the module.

catalog_pb2 / catalog_pb2_grpc are generated from proto/catalog.proto (the
catalog-proto ConfigMap) when the pod starts - see manifests/20-catalog.yaml. A
running pod keeps the contract it started with until it is restarted.
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


def _snapshot(item):
    """A copy of a stored Item to reply with, or None.

    gRPC serialises a reply after the method has returned - after the lock is
    released - so replying with the stored Item itself would let a concurrent
    ReserveStock change what this caller is told.
    """
    if item is None:
        return None
    reply = catalog_pb2.Item()
    reply.CopyFrom(item)
    return reply


class Catalog(catalog_pb2_grpc.CatalogServicer):
    def __init__(self):
        self._lock = threading.Lock()
        self._items = {
            "widget": catalog_pb2.Item(sku="widget", name="Widget", on_hand=10),
            "gadget": catalog_pb2.Item(sku="gadget", name="Gadget", on_hand=3),
        }

    def ListItems(self, request, context):
        print("%s ListItems" % POD, flush=True)
        with self._lock:
            # The constructor copies every Item, so this reply is a snapshot too.
            return catalog_pb2.ListItemsResponse(items=list(self._items.values()))

    def GetItem(self, request, context):
        print("%s GetItem sku=%s" % (POD, request.sku), flush=True)
        with self._lock:
            item = _snapshot(self._items.get(request.sku))
        if item is None:
            context.abort(grpc.StatusCode.NOT_FOUND, "no item with sku %r" % request.sku)
        return item

    def ReserveStock(self, request, context):
        print("%s ReserveStock sku=%s quantity=%d" % (POD, request.sku, request.quantity), flush=True)
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
            return _snapshot(item)


def main():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    catalog_pb2_grpc.add_CatalogServicer_to_server(Catalog(), server)
    # Reflection lets a client such as grpcurl ask the server what it offers,
    # without a copy of the .proto.
    reflection.enable_server_reflection(
        (catalog_pb2.DESCRIPTOR.services_by_name["Catalog"].full_name, reflection.SERVICE_NAME),
        server)
    server.add_insecure_port("0.0.0.0:%d" % PORT)
    server.start()
    print("catalog (gRPC only) listening on :%d as %s" % (PORT, POD), flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
