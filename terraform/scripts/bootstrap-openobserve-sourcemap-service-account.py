#!/usr/bin/env python3
"""Create an OpenObserve service account for source-map uploads.

This script is intentionally safe to run during platform bootstrap:

* It uses the OpenObserve root/admin credential only to create or rotate the
  dedicated source-map upload service account.
* It never prints the generated service-account token.
* It can persist the derived Authorization header into Vault KV v2 so app
  deployment Terraform can read it later.

OpenObserve OSS does not expose scoped RBAC permissions, so service accounts
have broad API access there. In Enterprise/OpenFGA deployments, grant this
service account an Editor/Admin role that includes sourcemaps upload/list
permissions before relying on it for source-map upload.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_EMAIL = "openobserve-sourcemap-uploader@suncoast.systems"
DEFAULT_FIRST_NAME = "Source Map"
DEFAULT_LAST_NAME = "Uploader"
DEFAULT_ORG = "default"
DEFAULT_OO_URL = "http://openobserve-router.openobserve.svc.cluster.local:5080"
DEFAULT_VAULT_MOUNT = "secret"
DEFAULT_VAULT_PATH = "openobserve-sourcemap-upload-auth-token"
DEFAULT_VAULT_FIELD = "value"
DEFAULT_WAIT_TIMEOUT_SECONDS = 300
TOKEN_KEYS = {"token", "api_token", "auth_token", "access_token"}


class BootstrapError(RuntimeError):
    pass


@dataclass
class HttpResponse:
    status: int
    body: bytes

    def json(self) -> Any:
        if not self.body:
            return {}
        return json.loads(self.body.decode("utf-8"))

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def basic_auth(username: str, password: str) -> str:
    raw = f"{username}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def basic_auth_username(auth_header: str) -> str:
    prefix, _, encoded = auth_header.strip().partition(" ")
    if prefix.lower() != "basic" or not encoded:
        return ""
    try:
        decoded = base64.b64decode(encoded).decode("utf-8")
    except Exception:
        return ""
    username, _, _password = decoded.partition(":")
    return username


def normalize_auth_header(value: str) -> str:
    value = value.strip()
    if value.lower().startswith(("basic ", "bearer ")):
        return value
    return "Basic " + value


def http_request(
    method: str,
    url: str,
    *,
    auth_header: str | None = None,
    json_payload: Any | None = None,
    extra_headers: dict[str, str] | None = None,
    expected: set[int] | None = None,
) -> HttpResponse:
    headers = dict(extra_headers or {})
    data = None
    if auth_header:
        headers["Authorization"] = auth_header
    if json_payload is not None:
        data = json.dumps(json_payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = HttpResponse(resp.status, resp.read())
    except urllib.error.HTTPError as exc:
        result = HttpResponse(exc.code, exc.read())
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", exc)
        raise BootstrapError(f"{method} {url} failed: {reason}") from exc
    except TimeoutError as exc:
        raise BootstrapError(f"{method} {url} timed out") from exc

    if expected is not None and result.status not in expected:
        body = result.text()[:1000]
        raise BootstrapError(f"{method} {url} returned HTTP {result.status}: {body}")
    return result


def k8s_secret(namespace: str, name: str) -> dict[str, str]:
    output = subprocess.check_output(
        ["kubectl", "-n", namespace, "get", "secret", name, "-o", "json"],
        text=True,
    )
    payload = json.loads(output)
    data = payload.get("data") or {}
    decoded = {}
    for key, value in data.items():
        decoded[key] = base64.b64decode(value).decode("utf-8")
    return decoded


def resolve_admin_auth(args: argparse.Namespace) -> str:
    if args.admin_auth_header:
        return normalize_auth_header(args.admin_auth_header)

    if args.admin_username and args.admin_password:
        return basic_auth(args.admin_username, args.admin_password)

    if args.read_admin_from_kubernetes:
        secret = k8s_secret(args.k8s_root_secret_namespace, args.k8s_root_secret_name)
        username = secret.get("username", "")
        password = secret.get("password", "")
        if username and password:
            return basic_auth(username, password)

    raise BootstrapError(
        "missing OpenObserve admin auth; set OO_ADMIN_AUTH_HEADER or "
        "OO_ADMIN_USERNAME/OO_ADMIN_PASSWORD, or enable --read-admin-from-kubernetes"
    )


def collect_tokens(value: Any) -> list[str]:
    tokens: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            normalized_key = str(key).lower()
            if (
                normalized_key in TOKEN_KEYS
                and isinstance(item, str)
                and item
                and "*" not in item
            ):
                tokens.append(item)
            tokens.extend(collect_tokens(item))
    elif isinstance(value, list):
        for item in value:
            tokens.extend(collect_tokens(item))
    return tokens


def shape_summary(value: Any, depth: int = 0) -> Any:
    if depth > 3:
        return "..."
    if isinstance(value, dict):
        return {str(key): shape_summary(item, depth + 1) for key, item in value.items()}
    if isinstance(value, list):
        return [shape_summary(value[0], depth + 1)] if value else []
    return type(value).__name__


def extract_created_token(response_json: Any) -> str:
    candidates = [token.strip() for token in collect_tokens(response_json) if token.strip()]
    if not candidates:
        pretty = json.dumps(shape_summary(response_json), sort_keys=True)[:1000]
        raise BootstrapError(
            "OpenObserve did not return a clear service-account token. "
            f"Response shape: {pretty}"
        )
    return candidates[0]


def openobserve_api_url(base_url: str, org: str, path: str) -> str:
    return f"{base_url.rstrip('/')}/api/{urllib.parse.quote(org)}/{path.lstrip('/')}"


def service_account_exists(base_url: str, org: str, auth_header: str, email: str) -> bool:
    url = openobserve_api_url(base_url, org, "service_accounts")
    response = http_request("GET", url, auth_header=auth_header, expected={200})
    body = response.json()
    encoded = json.dumps(body).lower()
    return email.lower() in encoded


def wait_for_openobserve_api(
    base_url: str,
    org: str,
    auth_header: str,
    timeout_seconds: int,
) -> None:
    url = openobserve_api_url(base_url, org, "service_accounts")
    deadline = time.monotonic() + timeout_seconds
    last_error = ""

    while True:
        try:
            http_request("GET", url, auth_header=auth_header, expected={200})
            return
        except BootstrapError as exc:
            last_error = str(exc)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BootstrapError(
                    f"OpenObserve API was not ready after {timeout_seconds}s: {last_error}"
                ) from exc
            print("waiting for OpenObserve API to become ready...", flush=True)
            time.sleep(min(5, max(1, remaining)))


def create_service_account(
    base_url: str,
    org: str,
    admin_auth_header: str,
    email: str,
    first_name: str,
    last_name: str,
) -> str:
    payload = {"email": email, "first_name": first_name, "last_name": last_name}
    url = openobserve_api_url(base_url, org, "service_accounts")
    response = http_request(
        "POST",
        url,
        auth_header=admin_auth_header,
        json_payload=payload,
        expected={200, 201, 409},
    )
    if response.status == 409:
        raise BootstrapError(f"service account already exists: {email}")
    return extract_created_token(response.json())


def rotate_service_account_token(
    base_url: str,
    org: str,
    admin_auth_header: str,
    email: str,
    first_name: str,
    last_name: str,
) -> str:
    payload = {"first_name": first_name, "last_name": last_name}
    email_id = urllib.parse.quote(email, safe="")
    url = openobserve_api_url(base_url, org, f"service_accounts/{email_id}")
    url = f"{url}?rotateToken=true"
    response = http_request(
        "PUT",
        url,
        auth_header=admin_auth_header,
        json_payload=payload,
        expected={200, 201},
    )
    return extract_created_token(response.json())


def vault_api_url(vault_addr: str, mount: str, path: str) -> str:
    mount = mount.strip("/")
    path = path.strip("/")
    return f"{vault_addr.rstrip('/')}/v1/{mount}/data/{path}"


def read_vault_kv2(
    vault_addr: str,
    vault_token: str,
    mount: str,
    path: str,
) -> dict[str, Any]:
    url = vault_api_url(vault_addr, mount, path)
    response = http_request(
        "GET",
        url,
        extra_headers={"X-Vault-Token": vault_token},
        expected={200, 404},
    )
    if response.status == 404:
        return {}
    body = response.json()
    data = body.get("data", {}).get("data", {})
    if not isinstance(data, dict):
        return {}
    return data


def write_vault_kv2(
    vault_addr: str,
    vault_token: str,
    mount: str,
    path: str,
    field: str,
    value: str,
) -> None:
    existing = read_vault_kv2(vault_addr, vault_token, mount, path)
    existing[field] = value
    url = vault_api_url(vault_addr, mount, path)
    http_request(
        "POST",
        url,
        extra_headers={"X-Vault-Token": vault_token},
        json_payload={"data": existing},
        expected={200, 204},
    )


def verify_sourcemaps_permission(base_url: str, org: str, auth_header: str) -> None:
    url = openobserve_api_url(base_url, org, "sourcemaps/values")
    try:
        http_request("GET", url, auth_header=auth_header, expected={200})
    except BootstrapError as exc:
        raise BootstrapError(
            "generated service-account credential cannot list source maps; "
            "on Enterprise/OpenFGA grant sourcemaps list/upload permissions "
            f"before upload. Root error: {exc}"
        ) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openobserve-url", default=os.environ.get("OO_URL", DEFAULT_OO_URL))
    parser.add_argument("--org", default=os.environ.get("OO_ORG", DEFAULT_ORG))
    parser.add_argument("--email", default=os.environ.get("OO_SOURCEMAP_SERVICE_ACCOUNT_EMAIL", DEFAULT_EMAIL))
    parser.add_argument("--first-name", default=os.environ.get("OO_SOURCEMAP_SERVICE_ACCOUNT_FIRST_NAME", DEFAULT_FIRST_NAME))
    parser.add_argument("--last-name", default=os.environ.get("OO_SOURCEMAP_SERVICE_ACCOUNT_LAST_NAME", DEFAULT_LAST_NAME))
    parser.add_argument("--admin-auth-header", default=os.environ.get("OO_ADMIN_AUTH_HEADER") or os.environ.get("OO_AUTH_HEADER"))
    parser.add_argument("--admin-username", default=os.environ.get("OO_ADMIN_USERNAME"))
    parser.add_argument("--admin-password", default=os.environ.get("OO_ADMIN_PASSWORD"))
    parser.add_argument(
        "--read-admin-from-kubernetes",
        action="store_true",
        default=env_bool("OO_READ_ADMIN_FROM_KUBERNETES", False),
    )
    parser.add_argument("--k8s-root-secret-namespace", default=os.environ.get("OO_ROOT_SECRET_NAMESPACE", "openobserve"))
    parser.add_argument("--k8s-root-secret-name", default=os.environ.get("OO_ROOT_SECRET_NAME", "openobserve-root-creds"))
    parser.add_argument(
        "--rotate-if-existing-without-usable-vault-secret",
        action="store_true",
        default=env_bool("OO_ROTATE_IF_EXISTING_WITHOUT_USABLE_VAULT_SECRET", False),
    )
    parser.add_argument("--vault-addr", default=os.environ.get("VAULT_ADDR"))
    parser.add_argument("--vault-token", default=os.environ.get("VAULT_TOKEN"))
    parser.add_argument("--vault-mount", default=os.environ.get("OO_SOURCEMAP_VAULT_MOUNT", DEFAULT_VAULT_MOUNT))
    parser.add_argument("--vault-path", default=os.environ.get("OO_SOURCEMAP_VAULT_PATH", DEFAULT_VAULT_PATH))
    parser.add_argument("--vault-field", default=os.environ.get("OO_SOURCEMAP_VAULT_FIELD", DEFAULT_VAULT_FIELD))
    parser.add_argument(
        "--wait-timeout-seconds",
        type=int,
        default=int(os.environ.get("OO_WAIT_TIMEOUT_SECONDS", DEFAULT_WAIT_TIMEOUT_SECONDS)),
    )
    parser.add_argument(
        "--write-vault",
        action="store_true",
        default=env_bool("OO_SOURCEMAP_WRITE_VAULT", False),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    admin_auth = resolve_admin_auth(args)
    wait_for_openobserve_api(args.openobserve_url, args.org, admin_auth, args.wait_timeout_seconds)
    existing_vault_auth = ""

    if args.write_vault:
        if not args.vault_addr or not args.vault_token:
            raise BootstrapError("VAULT_ADDR and VAULT_TOKEN are required with --write-vault")
        existing_vault_auth = str(
            read_vault_kv2(
                args.vault_addr,
                args.vault_token,
                args.vault_mount,
                args.vault_path,
            ).get(args.vault_field, "")
        )
        if existing_vault_auth:
            existing_username = basic_auth_username(existing_vault_auth)
            if existing_username and existing_username.lower() != args.email.lower():
                raise BootstrapError(
                    f"Vault credential at {args.vault_mount}/data/{args.vault_path} "
                    f"is for {existing_username}, not {args.email}"
                )

    created = False
    rotated = False
    service_account_auth = ""

    if service_account_exists(args.openobserve_url, args.org, admin_auth, args.email):
        if existing_vault_auth:
            try:
                verify_sourcemaps_permission(args.openobserve_url, args.org, existing_vault_auth)
                service_account_auth = existing_vault_auth
                print(f"service account already exists and Vault credential verified: {args.email}")
            except BootstrapError:
                if not args.rotate_if_existing_without_usable_vault_secret:
                    raise
                token = rotate_service_account_token(
                    args.openobserve_url,
                    args.org,
                    admin_auth,
                    args.email,
                    args.first_name,
                    args.last_name,
                )
                service_account_auth = basic_auth(args.email, token)
                rotated = True
                print(f"rotated service-account token after Vault credential failed verification: {args.email}")
        elif args.rotate_if_existing_without_usable_vault_secret:
            token = rotate_service_account_token(
                args.openobserve_url,
                args.org,
                admin_auth,
                args.email,
                args.first_name,
                args.last_name,
            )
            service_account_auth = basic_auth(args.email, token)
            rotated = True
            print(f"rotated service-account token: {args.email}")
        else:
            raise BootstrapError(
                f"service account {args.email} already exists, but no usable Vault "
                "credential was available. Re-run with "
                "--rotate-if-existing-without-usable-vault-secret to invalidate the "
                "old token and capture a new one."
            )
    else:
        token = create_service_account(
            args.openobserve_url,
            args.org,
            admin_auth,
            args.email,
            args.first_name,
            args.last_name,
        )
        service_account_auth = basic_auth(args.email, token)
        created = True
        print(f"created service account and captured generated token: {args.email}")

    verify_sourcemaps_permission(args.openobserve_url, args.org, service_account_auth)

    if args.write_vault and service_account_auth != existing_vault_auth:
        write_vault_kv2(
            args.vault_addr,
            args.vault_token,
            args.vault_mount,
            args.vault_path,
            args.vault_field,
            service_account_auth,
        )
        print(f"wrote source-map upload auth header to Vault: {args.vault_mount}/data/{args.vault_path} field={args.vault_field}")

    print(
        json.dumps(
            {
                "email": args.email,
                "org": args.org,
                "created": created,
                "rotated": rotated,
                "verified_sourcemaps_list": True,
                "vault_written": bool(args.write_vault and service_account_auth != existing_vault_auth),
                "vault_path": f"{args.vault_mount}/data/{args.vault_path}" if args.write_vault else None,
                "vault_field": args.vault_field if args.write_vault else None,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
