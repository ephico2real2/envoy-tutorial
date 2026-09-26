"""Tests for server.py's Catalog, called directly: no network, no gRPC server.

They need the generated stubs, so they run inside the catalog pod, where its
init container put them:

    ./run.sh test
"""
import unittest

import grpc

import catalog_pb2
from server import Catalog


class Aborted(Exception):
    """What grpc's ServicerContext.abort does: raise, so the method stops there."""


class Context:
    def abort(self, code, details):
        raise Aborted(code, details)


def reserve(catalog, sku, quantity):
    return catalog.ReserveStock(
        catalog_pb2.ReserveStockRequest(sku=sku, quantity=quantity), Context())


class RepliesAreSnapshots(unittest.TestCase):
    # gRPC serialises a reply after the method returns, outside the lock, so a
    # reply that is the stored Item itself shows whatever a later call did to it.

    def test_reserve_reply_keeps_its_own_result(self):
        catalog = Catalog()
        first = reserve(catalog, "widget", 1)
        reserve(catalog, "widget", 1)
        self.assertEqual(first.on_hand, 9)

    def test_get_reply_is_not_changed_by_a_later_reserve(self):
        catalog = Catalog()
        got = catalog.GetItem(catalog_pb2.GetItemRequest(sku="widget"), Context())
        reserve(catalog, "widget", 2)
        self.assertEqual(got.on_hand, 10)

    def test_list_reply_is_not_changed_by_a_later_reserve(self):
        catalog = Catalog()
        listed = catalog.ListItems(catalog_pb2.ListItemsRequest(), Context())
        reserve(catalog, "widget", 2)
        self.assertEqual([item.on_hand for item in listed.items], [10, 3])


class RefusedReservations(unittest.TestCase):
    def test_each_error_aborts_and_changes_nothing(self):
        catalog = Catalog()
        for sku, quantity, code in (("widget", 0, grpc.StatusCode.INVALID_ARGUMENT),
                                    ("gadget", 4, grpc.StatusCode.FAILED_PRECONDITION),
                                    ("nope", 1, grpc.StatusCode.NOT_FOUND)):
            with self.assertRaises(Aborted) as raised:
                reserve(catalog, sku, quantity)
            self.assertEqual(raised.exception.args[0], code)
            # an abort inside `with self._lock` must still release the lock
            self.assertFalse(catalog._lock.locked())
        self.assertEqual(reserve(catalog, "gadget", 3).on_hand, 0)
        self.assertEqual(
            catalog.GetItem(catalog_pb2.GetItemRequest(sku="widget"), Context()).on_hand, 10)


if __name__ == "__main__":
    unittest.main()
