import unittest
from typing import Literal, get_type_hints

from easl_sdk._generated import RemoteBoardInfo


class RemoteBoardTypeTests(unittest.TestCase):
    def test_remote_board_annotations_resolve_boolean_literals(self):
        hints = get_type_hints(RemoteBoardInfo)
        self.assertEqual(hints["remote"], Literal[True])
        self.assertEqual(hints["open"], Literal[True])
