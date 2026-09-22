"""Focused tests for discovery and broker connection behavior."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / "step-ca-client/rootfs/usr/bin/mqtt-telemetry.py"
spec = importlib.util.spec_from_file_location("mqtt_telemetry", MODULE)
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)


class FakeSocket:
    def __init__(self):
        self.writes = []
        self.closed = False

    def settimeout(self, value):
        pass

    def sendall(self, value):
        self.writes.append(value)

    def recv(self, count):
        return b"\x20\x02\x00\x00"

    def close(self):
        self.closed = True


class TelemetryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.patchers = [
            mock.patch.object(telemetry, "TRACK", str(self.root / "topics.json")),
            mock.patch.object(telemetry, "STATUS", str(self.root / "status")),
        ]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        (self.root / "status").mkdir()
        self.base = {"mqtt": {"enabled": True, "instance_id": "house_1",
                              "host": "broker", "port": 1883},
                     "certfile": "fullchain.pem",
                     "client_certificate": {"enabled": False}}

    def test_discovery_and_expiry(self):
        entities = telemetry.desired_entities("house_1", self.base)
        self.assertEqual(len(entities), 4)
        ids = {payload["unique_id"] for payload in entities.values()}
        self.assertEqual(len(ids), 4)
        self.assertTrue(all(payload["expire_after"] == 900 for payload in entities.values()))
        self.assertEqual(len({tuple(payload["device"]["identifiers"]) for payload in entities.values()}), 1)
        self.base["client_certificate"]["enabled"] = True
        self.assertEqual(len(telemetry.desired_entities("house_1", self.base)), 8)

    def test_plain_publish_and_opt_out_cleanup(self):
        first, second = FakeSocket(), FakeSocket()
        with mock.patch.object(telemetry, "connect", side_effect=[first, second]):
            self.assertTrue(telemetry.cycle(self.base))
            self.assertEqual(len(json.loads(Path(telemetry.TRACK).read_text())), 4)
            self.base["mqtt"]["enabled"] = False
            self.assertFalse(telemetry.cycle(self.base))
        self.assertEqual(json.loads(Path(telemetry.TRACK).read_text()), [])
        self.assertEqual(sum(packet[0] == 0x31 for packet in second.writes), 4)
        self.assertTrue(all(b"config" in packet for packet in second.writes[:-1]))

    def test_credentials_are_in_connect_packet_only(self):
        self.base["mqtt"].update(username="operator", password="secret")
        sock = FakeSocket()
        with mock.patch.object(telemetry.socket, "create_connection", return_value=sock):
            telemetry.connect(self.base["mqtt"])
        self.assertIn(b"secret", sock.writes[0])
        self.assertNotIn(b"secret", json.dumps(telemetry.desired_entities("house_1", self.base)).encode())

    def test_tls_and_mtls(self):
        sock = FakeSocket()
        context = mock.Mock()
        context.wrap_socket.return_value = sock
        self.base["mqtt"].update(tls=True, ca_file="ca.pem",
                                 client_cert_file="client.pem", client_key_file="key.pem")
        with mock.patch.object(telemetry.socket, "create_connection", return_value=sock), \
             mock.patch.object(telemetry.ssl, "create_default_context", return_value=context) as factory:
            telemetry.connect(self.base["mqtt"])
        factory.assert_called_once_with(cafile="/ssl/ca.pem")
        context.load_cert_chain.assert_called_once_with("/ssl/client.pem", "/ssl/key.pem")
        context.wrap_socket.assert_called_once_with(sock, server_hostname="broker")

    def test_bad_tls_paths_and_broker_outage(self):
        self.base["mqtt"].update(tls=True, ca_file="../secret.pem")
        with self.assertRaises(ValueError):
            telemetry.connect(self.base["mqtt"])
        self.base["mqtt"]["ca_file"] = ""
        with mock.patch.object(telemetry.socket, "create_connection", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                telemetry.cycle(self.base)
        self.assertFalse(Path(telemetry.TRACK).exists())


if __name__ == "__main__":
    unittest.main()
