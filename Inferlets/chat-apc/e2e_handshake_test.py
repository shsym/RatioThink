#!/usr/bin/env python3
"""Unit tests for the chat-apc E2E pie handshake parser."""
from __future__ import annotations

import unittest

import e2e_test


class HandshakeLineParsingTests(unittest.TestCase):
    def test_extracts_old_serving_line(self):
        state = e2e_test.HandshakeState()

        e2e_test._parse_handshake_line(
            state,
            "pie-server serving on 127.0.0.1:59165 (1 model(s))\n",
        )
        e2e_test._parse_handshake_line(state, "internal token: abc123\n")

        self.assertEqual(state.url, "127.0.0.1:59165")
        self.assertEqual(state.token, "abc123")

    def test_extracts_new_server_ready_ws_line(self):
        state = e2e_test.HandshakeState()

        e2e_test._parse_handshake_line(
            state,
            "✓ Server ready at ws://127.0.0.1:64307\n",
        )
        e2e_test._parse_handshake_line(state, "internal token: token-value\n")

        self.assertEqual(state.url, "127.0.0.1:64307")
        self.assertEqual(state.token, "token-value")


if __name__ == "__main__":
    unittest.main()
