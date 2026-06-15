from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("e2e_test.py")
SPEC = importlib.util.spec_from_file_location("chat_apc_e2e_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
E = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = E
SPEC.loader.exec_module(E)


class HandshakeParser(unittest.TestCase):
    def test_parses_legacy_pie_server_line(self) -> None:
        state = E._HandshakeState()
        E._parse_handshake_line("pie-server serving on 127.0.0.1:47474", state)
        E._parse_handshake_line("internal token: test-token", state)
        self.assertEqual(state.url, "127.0.0.1:47474")
        self.assertEqual(state.token, "test-token")

    def test_parses_new_server_ready_ws_line(self) -> None:
        state = E._HandshakeState()
        E._parse_handshake_line("✓ Server ready at ws://127.0.0.1:47474", state)
        E._parse_handshake_line("internal token: test-token", state)
        self.assertEqual(state.url, "127.0.0.1:47474")
        self.assertEqual(state.token, "test-token")


if __name__ == "__main__":
    unittest.main(verbosity=2)
