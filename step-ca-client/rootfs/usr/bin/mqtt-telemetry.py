#!/usr/bin/env python3
"""Publish certificate status through MQTT Discovery without exposing credentials."""
import datetime
import json
import os
import re
import socket
import ssl
import sys
import time

OPTIONS = "/data/options.json"
TRACK = "/data/step-ca-mqtt-topics.json"
STATUS = "/run/step-ca-telemetry"
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def encoded_length(size):
    out = bytearray()
    while True:
        part = size % 128
        size //= 128
        out.append(part | (128 if size else 0))
        if not size:
            return bytes(out)


def field(value):
    raw = value.encode("utf-8")
    return len(raw).to_bytes(2, "big") + raw


def packet(kind, body):
    return bytes([kind]) + encoded_length(len(body)) + body


def ssl_file(name):
    if not FILENAME.fullmatch(name or "") or name in (".", ".."):
        raise ValueError("MQTT TLS files must be filenames below /ssl")
    return "/ssl/" + name


def connect(config):
    host = config.get("host", "")
    port = config.get("port", 1883)
    if not isinstance(host, str) or not host or any(c.isspace() for c in host):
        raise ValueError("MQTT host is required")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("MQTT port must be between 1 and 65535")
    tls = config.get("tls", False)
    cert = config.get("client_cert_file")
    key = config.get("client_key_file")
    if bool(cert) != bool(key):
        raise ValueError("MQTT client certificate and key must be configured together")
    tls_files = [config.get(name) for name in ("ca_file", "client_cert_file", "client_key_file")]
    if not tls and any(tls_files):
        raise ValueError("MQTT TLS files require TLS to be enabled")
    for name in tls_files:
        if name:
            ssl_file(name)
    username = config.get("username") or ""
    password = config.get("password") or ""
    if password and not username:
        raise ValueError("MQTT username is required when a password is set")
    raw = socket.create_connection((host, port), timeout=10)
    raw.settimeout(10)
    if tls:
        context = ssl.create_default_context(cafile=ssl_file(config["ca_file"]) if config.get("ca_file") else None)
        if cert:
            context.load_cert_chain(ssl_file(cert), ssl_file(key))
        raw = context.wrap_socket(raw, server_hostname=host)
    flags = 2 | (128 if username else 0) | (64 if password else 0)
    client_id = "step-ca-" + str(os.getpid())
    body = field("MQTT") + bytes([4, flags]) + (30).to_bytes(2, "big") + field(client_id)
    if username:
        body += field(username)
    if password:
        body += field(password)
    raw.sendall(packet(0x10, body))
    answer = raw.recv(4)
    if len(answer) != 4 or answer[:3] != b"\x20\x02\x00" or answer[3] != 0:
        raw.close()
        raise OSError("MQTT broker rejected the connection")
    return raw


def publish(connection, topic, value, retain=False):
    payload = value.encode("utf-8")
    connection.sendall(packet(0x31 if retain else 0x30, field(topic) + payload))


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as source:
            return json.load(source)
    except (FileNotFoundError, ValueError):
        return fallback


def save_topics(topics):
    temporary = TRACK + ".tmp"
    with open(temporary, "w", encoding="utf-8") as output:
        json.dump(topics, output)
    os.replace(temporary, TRACK)


def certificate_expiry(path):
    try:
        decoded = ssl._ssl._test_decode_cert(path)  # stdlib PEM decoder
        stamp = ssl.cert_time_to_seconds(decoded["notAfter"])
        return datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat()
    except (OSError, ValueError, KeyError):
        return None


def profile_values(profile, options):
    settings = options if profile == "server" else options.get("client_certificate", {})
    filename = settings.get("certfile", "")
    values = {}
    if FILENAME.fullmatch(filename) and filename not in (".", ".."):
        values["expiration"] = certificate_expiry("/ssl/" + filename)
    try:
        with open(f"{STATUS}/{profile}.state", encoding="utf-8") as source:
            lines = source.read().splitlines()
        values["due"], values["failure"] = lines[:2]
    except (FileNotFoundError, ValueError):
        pass
    try:
        with open(f"/data/step-ca-{profile}-last-renewal", encoding="utf-8") as source:
            values["last_renewal"] = source.read().strip()
    except FileNotFoundError:
        pass
    return values


def desired_entities(instance, options):
    device = {"identifiers": [f"step_ca_{instance}"], "name": f"step-ca certificates ({instance})",
              "manufacturer": "Smallstep"}
    prefix = f"step_ca/{instance}"
    entities = {}
    profiles = ["server"]
    if options.get("client_certificate", {}).get("enabled", False):
        profiles.append("client")
    for profile in profiles:
        for suffix, component, label in (
            ("expiration", "sensor", "Expiration"),
            ("due", "binary_sensor", "Renewal due"),
            ("failure", "binary_sensor", "Renewal failure"),
            ("last_renewal", "sensor", "Last successful renewal"),
        ):
            unique = f"step_ca_{instance}_{profile}_{suffix}"
            topic = f"homeassistant/{component}/{unique}/config"
            payload = {"name": f"{profile.title()} {label}", "unique_id": unique,
                       "state_topic": f"{prefix}/{profile}/{suffix}", "device": device,
                       "expire_after": 900}
            if component == "binary_sensor":
                payload.update({"payload_on": "on", "payload_off": "off",
                                "entity_category": "diagnostic"})
                if suffix == "failure":
                    payload["device_class"] = "problem"
            else:
                payload.update({"device_class": "timestamp", "entity_category": "diagnostic"})
            entities[topic] = payload
    return entities


def cycle(options):
    config = options.get("mqtt", {})
    previous = read_json(TRACK, [])
    if not isinstance(previous, list):
        previous = []
    enabled = config.get("enabled", False)
    instance = config.get("instance_id", "")
    if enabled and not IDENTIFIER.fullmatch(instance):
        raise ValueError("MQTT instance_id must contain letters, digits, underscores or hyphens")
    entities = desired_entities(instance, options) if enabled else {}
    if not entities and not previous:
        return False
    connection = connect(config)
    try:
        for topic in previous:
            if topic not in entities and re.fullmatch(r"homeassistant/(sensor|binary_sensor)/step_ca_[A-Za-z0-9_-]+/config", topic):
                publish(connection, topic, "", True)
        for topic, payload in entities.items():
            publish(connection, topic, json.dumps(payload, separators=(",", ":")), True)
        if enabled:
            for profile in ("server", "client"):
                if profile == "client" and not options.get("client_certificate", {}).get("enabled", False):
                    continue
                for suffix, value in profile_values(profile, options).items():
                    if value:
                        publish(connection, f"step_ca/{instance}/{profile}/{suffix}", value)
        connection.sendall(b"\xe0\x00")
    finally:
        connection.close()
    save_topics(list(entities))
    return enabled


def main():
    while True:
        try:
            options = read_json(OPTIONS, {})
            active = cycle(options)
        except (OSError, ValueError, TypeError, KeyError) as error:
            # Connection and TLS exceptions can include hostnames; never print options.
            print(f"MQTT telemetry publish failed ({type(error).__name__})", file=sys.stderr, flush=True)
            active = bool(read_json(OPTIONS, {}).get("mqtt", {}).get("enabled", False))
        time.sleep(300 if active or read_json(TRACK, []) else 3600)


if __name__ == "__main__":
    main()
