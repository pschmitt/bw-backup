#!/usr/bin/env python3

import argparse
import base64
import difflib
import hashlib
import json
import sys
import urllib.parse
import urllib.request
import uuid

# -----------------------------------------------------------------------------
# Master Password Hash Logic
# -----------------------------------------------------------------------------


def derive_master_key_pbkdf2(
    password: str, email: str, iterations: int, dklen: int = 32
) -> bytes:
    return hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        email.strip().encode("utf-8"),
        iterations,
        dklen=dklen,
    )


def compute_master_password_auth_hash(
    master_key: bytes, password: str, iterations: int = 1, dklen: int = 32
) -> str:
    out = hashlib.pbkdf2_hmac(
        "sha256",
        master_key,
        password.encode("utf-8"),
        iterations,
        dklen=dklen,
    )
    return base64.b64encode(out).decode("ascii")


def safe_json_load(response_body: bytes, context: str):
    try:
        return json.loads(response_body.decode("utf-8"))
    except Exception as exc:
        sys.stderr.write(f"Failed to parse JSON from {context}: {exc}\n")
        sys.exit(1)


def action_hash(args):
    master_key = derive_master_key_pbkdf2(
        password=args.password,
        email=args.email,
        iterations=args.kdf_iterations,
    )

    final_iters = 2 if args.local else 1
    mph_b64 = compute_master_password_auth_hash(
        master_key, args.password, iterations=final_iters
    )
    print(mph_b64)


# -----------------------------------------------------------------------------
# Item Matching Logic
# -----------------------------------------------------------------------------


def get_clean_item(item):
    # Create a copy to modify
    item_copy = item.copy()
    # Remove fields that change or are irrelevant for content matching
    fields_to_remove = [
        "attachments",
        "collectionIds",
        "creationDate",
        "deletedDate",
        "folderId",
        # "history", # TODO should we include this?
        "id",
        "object",
        "organizationId",
        "passwordHistory",
        "passwordRevisionDate",
        "revisionDate",
    ]
    for field in fields_to_remove:
        item_copy.pop(field, None)

    # Sort lists to ensure deterministic order
    if item_copy.get("login") and isinstance(item_copy["login"], dict):
        if item_copy["login"].get("uris") and isinstance(
            item_copy["login"]["uris"], list
        ):
            # Sort by URI string to ensure deterministic order
            item_copy["login"]["uris"] = sorted(
                item_copy["login"]["uris"],
                key=lambda x: (x.get("uri", "") or "", x.get("match", 0) or 0),
            )
        if item_copy["login"].get("fido2Credentials") and isinstance(
            item_copy["login"]["fido2Credentials"], list
        ):
            item_copy["login"]["fido2Credentials"] = sorted(
                item_copy["login"]["fido2Credentials"],
                key=lambda x: (x.get("credentialId", "") or ""),
            )

    if item_copy.get("fields") and isinstance(item_copy["fields"], list):
        # Sort fields by name, value, and type
        item_copy["fields"] = sorted(
            item_copy["fields"],
            key=lambda x: (
                x.get("name", "") or "",
                str(x.get("value", "") or ""),
                x.get("type", 0) or 0,
            ),
        )

    return item_copy


def get_item_hash(item, debug=False):
    item_copy = get_clean_item(item)
    # Sort keys to ensure consistent JSON string
    item_str = json.dumps(item_copy, sort_keys=True)
    if debug:
        sys.stderr.write(f"DEBUG HASH INPUT for {item.get('id')}: {item_str}\n")
    return hashlib.sha256(item_str.encode("utf-8")).hexdigest()


def action_match(args):
    try:
        with open(args.source_file, "r") as f:
            source_data = json.load(f)

        with open(args.dest_file, "r") as f:
            dest_data = json.load(f)
    except Exception as e:
        sys.stderr.write(f"Error reading JSON files: {e}\n")
        sys.exit(1)

    # Handle both wrapped {items: [...]} and raw array [...] formats
    source_items = (
        source_data.get("items", source_data)
        if isinstance(source_data, dict)
        else source_data
    )
    dest_items = (
        dest_data.get("items", dest_data) if isinstance(dest_data, dict) else dest_data
    )

    if not isinstance(source_items, list) or not isinstance(dest_items, list):
        sys.stderr.write("Error: JSON data does not contain a list of items.\n")
        sys.exit(1)

    dest_map = {}
    # Also keep a map of name -> list of items for fuzzy matching debugging
    dest_name_map = {}

    for item in dest_items:
        if "id" in item:
            h = get_item_hash(item)
            if h not in dest_map:
                dest_map[h] = []
            dest_map[h].append(item["id"])

            name = item.get("name")
            if name:
                if name not in dest_name_map:
                    dest_name_map[name] = []
                dest_name_map[name].append(item)

    debug_count = 0
    for item in source_items:
        if "id" in item:
            h = get_item_hash(item)
            if h in dest_map and dest_map[h]:
                # Pop the first matching ID to handle duplicates correctly
                dest_id = dest_map[h].pop(0)
                print(f"{item['id']}\t{dest_id}")
            else:
                # Fallback: Try unique name match
                name = item.get("name")
                matched_by_name = False
                if name and name in dest_name_map:
                    candidates = dest_name_map[name]
                    # Filter candidates that are still available in dest_map
                    available_candidates = []
                    for cand in candidates:
                        cand_h = get_item_hash(cand)
                        if cand_h in dest_map and cand["id"] in dest_map[cand_h]:
                            available_candidates.append(cand)

                    if len(available_candidates) == 1:
                        dest_item = available_candidates[0]
                        dest_h = get_item_hash(dest_item)
                        dest_map[dest_h].remove(dest_item["id"])
                        print(f"{item['id']}\t{dest_item['id']}")
                        matched_by_name = True

                if not matched_by_name:
                    if debug_count < 3:
                        sys.stderr.write(
                            f"DEBUG: No match for source item {item['id']} ({item.get('name')})\n"
                        )
                        # Try to find a candidate by name
                        name = item.get("name")
                        if name and name in dest_name_map:
                            candidates = dest_name_map[name]
                            sys.stderr.write(
                                f"DEBUG: Found {len(candidates)} candidates with same name.\n"
                            )
                            for cand in candidates:
                                src_clean = get_clean_item(item)
                                dst_clean = get_clean_item(cand)

                                src_str = json.dumps(
                                    src_clean, sort_keys=True, indent=2
                                )
                                dst_str = json.dumps(
                                    dst_clean, sort_keys=True, indent=2
                                )

                                # Only show diff if they are "close" enough?
                                # For now, just showing diff for same-named items is a good heuristic for "close"
                                diff = difflib.unified_diff(
                                    src_str.splitlines(),
                                    dst_str.splitlines(),
                                    fromfile=f"Source {item['id']}",
                                    tofile=f"Dest {cand['id']}",
                                    lineterm="",
                                )
                                for line in diff:
                                    sys.stderr.write(f"DIFF: {line}\n")
                    debug_count += 1


# -----------------------------------------------------------------------------
# Purge Vault Logic
# -----------------------------------------------------------------------------


def ensure_server_url(server: str) -> str:
    return server.rstrip("/")


def http_post_form(url: str, data: dict) -> dict:
    encoded = urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=encoded,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            body = resp.read()
    except Exception as exc:
        sys.stderr.write(f"Failed HTTP POST form to {url}: {exc}\n")
        sys.exit(1)
    return safe_json_load(body, url)


def http_post_json(url: str, data: dict, bearer_token: str) -> dict:
    encoded = json.dumps(data).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=encoded,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {bearer_token}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            body = resp.read()
    except Exception as exc:
        sys.stderr.write(f"Failed HTTP POST json to {url}: {exc}\n")
        sys.exit(1)
    if not body:
        return {}
    return safe_json_load(body, url)


def action_purge(args):
    server = ensure_server_url(args.server)
    device_identifier = str(uuid.uuid4())

    login_payload = {
        "grant_type": "client_credentials",
        "client_id": args.api_client_id,
        "client_secret": args.api_client_secret,
        "device_identifier": device_identifier,
        "device_name": args.device_name,
        "device_type": args.device_type,
        "scope": "api",
    }

    login_url = f"{server}/identity/connect/token"
    login_data = http_post_form(login_url, login_payload)

    access_token = login_data.get("access_token")
    kdf_iterations = login_data.get("KdfIterations")

    if not access_token or not kdf_iterations:
        sys.stderr.write("Login response missing access_token or KdfIterations.\n")
        sys.exit(1)

    master_key = derive_master_key_pbkdf2(
        password=args.master_password,
        email=args.email,
        iterations=int(kdf_iterations),
    )
    master_password_hash = compute_master_password_auth_hash(
        master_key, args.master_password
    )

    purge_url = f"{server}/api/ciphers/purge"
    purge_payload = {"masterPasswordHash": master_password_hash}

    http_post_json(purge_url, purge_payload, access_token)
    print("✅ Vault purged successfully")


# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Bitwarden Portal Helper Script")
    subparsers = parser.add_subparsers(
        dest="action", required=True, help="Action to perform"
    )

    # Subcommand: hash
    parser_hash = subparsers.add_parser("hash", help="Calculate master password hash")
    parser_hash.add_argument("--email", "-e", required=True, help="User email")
    parser_hash.add_argument("--password", "-p", required=True, help="Master password")
    parser_hash.add_argument(
        "--kdf-iterations", type=int, default=600000, help="KDF iterations"
    )
    parser_hash.add_argument(
        "--local", action="store_true", help="Calculate local hash"
    )
    parser_hash.set_defaults(func=action_hash)

    # Subcommand: match
    parser_match = subparsers.add_parser(
        "match", help="Match items between source and destination JSON"
    )
    parser_match.add_argument("source_file", help="Source JSON file")
    parser_match.add_argument("dest_file", help="Destination JSON file")
    parser_match.set_defaults(func=action_match)

    parser_purge = subparsers.add_parser("purge", help="Purge vault contents")
    parser_purge.add_argument("--server", "-s", required=True, help="Bitwarden server")
    parser_purge.add_argument(
        "--api-client-id", "-c", required=True, help="API client ID"
    )
    parser_purge.add_argument(
        "--api-client-secret", "-S", required=True, help="API client secret"
    )
    parser_purge.add_argument("--email", "-e", required=True, help="Account email")
    parser_purge.add_argument(
        "--master-password", "-m", required=True, help="Master password"
    )
    parser_purge.add_argument(
        "--device-name", default="bw.py", help="Device name for the API device"
    )
    parser_purge.add_argument(
        "--device-type", default="script", help="Device type for the API device"
    )
    parser_purge.set_defaults(func=action_purge)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
