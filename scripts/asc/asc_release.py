#!/usr/bin/env python3
"""App Store Connect release helper for ClipDock (Python 3 stdlib only).

Subcommands
-----------
probe        Read-only snapshot: app, every appStoreVersion with state, recent
             builds with processingState, current review submissions.
preflight    The empty-submit error probe. Creates a throwaway review submission,
             POSTs a reviewSubmissionItem for the target version and reads
             ``meta.associatedErrors`` from the 409. That single response lists
             *every* missing prerequisite. A clean (201) probe deletes the item
             it just created, so probing leaves nothing behind. ``--fix`` applies
             the two known-safe fixes, waits for screenshot assets to finish
             processing and re-probes until clean. Exits non-zero while anything
             is unresolved.
screenshots  Replace a version's screenshots per localization, reusing the
             ``screenshotDisplayType`` that already exists in App Store Connect.
submit       Attach the build and submit the version for review. Refuses to
             submit unless a fresh preflight probe is clean.

Every mutating subcommand takes ``--dry-run``: it prints the exact HTTP method,
path and redacted body, and makes no writes.

Authentication is an App Store Connect API key (ES256 JWT). Credentials come
from CLI flags or the environment, never from this file:

    ASC_ISSUER_ID   issuer UUID
    ASC_KEY_ID      key id, e.g. ABC123DEFG
    ASC_KEY_PATH    path to AuthKey_<key id>.p8
    ASC_APP_ID      optional app id (defaults to ClipDock)

Exit codes: 0 ok, 2 usage/config, 3 unresolved prerequisites, 4 ASC/network error.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import namedtuple
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

API_BASE = "https://api.appstoreconnect.apple.com"

# ClipDock's App Store Connect app id. Overridable everywhere (--app-id),
# so nothing here is load-bearing for another app.
DEFAULT_APP_ID = "6759184867"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_UNRESOLVED = 3
EXIT_ASC_ERROR = 4
EXIT_INTERRUPTED = 130

# ---------------------------------------------------------------------------
# Screenshots: what the API actually accepts
# ---------------------------------------------------------------------------
# There is NO ``APP_IPHONE_69`` value for appStoreScreenshotSets.  Verified
# 2026-10-30 against the live API:
#   409 ENTITY_ERROR.ATTRIBUTE.TYPE: 'APP_IPHONE_69' is not a valid value for
#   the attribute 'screenshotDisplayType'. Expected one of: 'APP_DESKTOP',
#   'APP_IPAD_PRO_3GEN_129', 'APP_IPHONE_55', 'APP_APPLE_VISION_PRO', ...
# The largest valid iPhone value is ``APP_IPHONE_67``, and it accepts both
# 1320x2868 (6.9") and 1290x2796 (6.7") uploads.
#
# So we never guess: we read the display types that already exist on a previous
# version and reuse one.  ``FALLBACK_DISPLAY_TYPE`` is only used when ASC has no
# iPhone screenshot set to copy from, and using it prints a warning.
FALLBACK_DISPLAY_TYPE = "APP_IPHONE_67"
INVALID_DISPLAY_TYPES = frozenset({"APP_IPHONE_69"})
IPHONE_DISPLAY_TYPE_PREFERENCE = (
    "APP_IPHONE_67",
    "APP_IPHONE_65",
    "APP_IPHONE_61",
    "APP_IPHONE_58",
    "APP_IPHONE_55",
    "APP_IPHONE_47",
    "APP_IPHONE_40",
    "APP_IPHONE_35",
)
NON_IPHONE_PREFIXES = ("APP_IPAD", "APP_WATCH", "APP_DESKTOP", "APP_APPLE", "IMESSAGE_")
ACCEPTED_SCREENSHOT_SIZES: Dict[str, Tuple[Tuple[int, int], ...]] = {
    "APP_IPHONE_67": ((1320, 2868), (1290, 2796)),
    "APP_IPHONE_65": ((1284, 2778), (1242, 2688)),
    "APP_IPHONE_61": ((1206, 2622), (1179, 2556)),
}

# Diagnostic hint only -- never used to authenticate.  ClipDock's Sales and
# Trends key cannot read /v1/builds; the App Manager key can.
BUILD_ACCESS_403_HINT = (
    "403 on /v1/builds is almost always the wrong key: ClipDock has two ASC keys.\n"
    "  AuthKey_YYK7P6W893.p8  -> App Manager role, can read builds and submit for review.\n"
    "  AuthKey_7XL5564K84.p8  -> Sales and Trends only, CANNOT read /v1/builds.\n"
    "  Point ASC_KEY_ID / ASC_KEY_PATH (or --key-id / --key-path) at the App Manager key."
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------
class AscToolError(Exception):
    """Base class for every error this tool raises on purpose."""

    exit_code = EXIT_ASC_ERROR


class UsageError(AscToolError):
    """Bad flags, missing inputs, unsafe request."""

    exit_code = EXIT_USAGE


class CredentialError(UsageError):
    """Missing or unusable API key."""


class AscApiError(AscToolError):
    """The API returned an error status we did not expect."""

    def __init__(self, method: str, path: str, status: int, payload: Any, note: str = ""):
        self.method = method
        self.path = path
        self.status = status
        self.payload = payload
        self.note = note
        message = "%s %s -> HTTP %s: %s" % (method, path, status, describe_errors(payload))
        if note:
            message += "\n" + note
        super().__init__(message)


# ---------------------------------------------------------------------------
# Small pure helpers
# ---------------------------------------------------------------------------
def b64u(raw: bytes) -> str:
    """base64url without padding, as JWT and ASC require."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def b64u_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def der_to_raw_signature(der: bytes) -> bytes:
    """Convert an ASN.1 DER ECDSA signature into the raw 64-byte r||s form.

    ES256 (JWS) wants the two 32-byte integers concatenated; openssl emits DER.
    """
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE (first byte 0x%02x)" % (der[0] if der else 0))
    if der[1] < 0x80:
        idx = 2
    elif der[1] == 0x81:
        idx = 3
    elif der[1] == 0x82:
        idx = 4
    else:
        raise ValueError("unsupported DER length encoding")

    out = bytearray()
    for _ in range(2):
        if idx + 2 > len(der) or der[idx] != 0x02:
            raise ValueError("expected a DER INTEGER at offset %d" % idx)
        length = der[idx + 1]
        if length & 0x80:
            raise ValueError("unsupported multi-byte INTEGER length")
        start = idx + 2
        end = start + length
        if end > len(der):
            raise ValueError("truncated DER INTEGER")
        value = der[start:end].lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("ECDSA integer longer than 32 bytes")
        out += value.rjust(32, b"\x00")
        idx = end
    if len(out) != 64:
        raise ValueError("expected 64 raw signature bytes, got %d" % len(out))
    return bytes(out)


def build_jwt_segments(
    key_id: str,
    issuer: str,
    issued_at: float,
    lifetime: int = 1140,
    audience: str = "appstoreconnect-v1",
) -> Tuple[str, Dict[str, Any], Dict[str, Any]]:
    """Return ("<header>.<payload>", header, payload) for an ES256 JWT.

    ASC rejects tokens whose lifetime is 20 minutes or more, so default to 19.
    """
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer,
        "iat": int(issued_at),
        "exp": int(issued_at) + int(lifetime),
        "aud": audience,
    }
    segments = "%s.%s" % (
        b64u(json.dumps(header, separators=(",", ":"), sort_keys=True).encode("utf-8")),
        b64u(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")),
    )
    return segments, header, payload


JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}")
BEARER_RE = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+")
SENSITIVE_KEYS = frozenset(
    {
        "token",
        "accesstoken",
        "access_token",
        "authorization",
        "password",
        "secret",
        "clientsecret",
        "privatekey",
        "private_key",
        "apikey",
        "api_key",
        "signature",
    }
)
MAX_LOGGED_STRING = 300


def redact_token(text: str) -> str:
    """Strip anything that looks like a JWT or a bearer credential."""
    if not text:
        return text
    text = JWT_RE.sub("<jwt-redacted>", text)
    return BEARER_RE.sub(r"\1<redacted>", text)


def redact_body(obj: Any) -> Any:
    """Deep-copy with secrets masked and long strings truncated, for logging."""
    if isinstance(obj, dict):
        out: Dict[str, Any] = {}
        for key, value in obj.items():
            if isinstance(key, str) and key.lower() in SENSITIVE_KEYS:
                out[key] = "<redacted>"
            else:
                out[key] = redact_body(value)
        return out
    if isinstance(obj, (list, tuple)):
        return [redact_body(item) for item in obj]
    if isinstance(obj, str):
        if len(obj) > MAX_LOGGED_STRING:
            return obj[:MAX_LOGGED_STRING] + "...<truncated %d chars>" % (len(obj) - MAX_LOGGED_STRING)
        return redact_token(obj)
    return obj


def md5_hexdigest_bytes(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def md5_hexdigest(path: Path) -> str:
    """MD5 of a file, streamed -- ASC wants this as ``sourceFileChecksum``."""
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


UploadChunk = namedtuple("UploadChunk", "operation offset length chunk")


def slice_upload_operations(data: bytes, upload_operations: Optional[Sequence[dict]]) -> List[UploadChunk]:
    """Turn ASC ``uploadOperations`` into (operation, byte range) chunks.

    ASC hands back one operation per part with an explicit ``offset`` and
    ``length``; a missing length means "to end of file".  Operations are sorted
    by offset so multi-part uploads stay in order.
    """
    chunks: List[UploadChunk] = []
    for op in sorted(upload_operations or [], key=lambda item: (item.get("offset") or 0)):
        offset = op.get("offset") or 0
        length = op.get("length")
        if offset < 0:
            raise ValueError("negative upload offset")
        if length is None:
            piece = data[offset:]
        else:
            piece = data[offset : offset + length]
        chunks.append(UploadChunk(op, offset, len(piece), piece))
    return chunks


def read_png_size(path: Path) -> Optional[Tuple[int, int]]:
    """Return (width, height) from a PNG IHDR, or None if it is not a PNG."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(33)
    except OSError:
        return None
    if len(head) < 24 or not head.startswith(PNG_SIGNATURE) or head[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return int(width), int(height)


def check_screenshot_size(path: Path, display_type: str) -> Optional[str]:
    """Return a problem description, or None when the size is acceptable.

    Only types we have verified are checked; anything else passes through.
    """
    accepted = ACCEPTED_SCREENSHOT_SIZES.get(display_type)
    if not accepted:
        return None
    size = read_png_size(path)
    if size is None:
        return None
    if size in accepted:
        return None
    expected = " or ".join("%dx%d" % pair for pair in accepted)
    return "%s is %dx%d but %s accepts %s" % (path.name, size[0], size[1], display_type, expected)


DisplayTypeChoice = namedtuple("DisplayTypeChoice", "display_type reused source")


def _is_iphone_display_type(display_type: str) -> bool:
    if display_type in INVALID_DISPLAY_TYPES:
        return False
    return not display_type.startswith(NON_IPHONE_PREFIXES)


def _display_type_rank(display_type: str) -> int:
    try:
        return IPHONE_DISPLAY_TYPE_PREFERENCE.index(display_type)
    except ValueError:
        return len(IPHONE_DISPLAY_TYPE_PREFERENCE)


def choose_display_type(
    available: Iterable[str],
    override: Optional[str] = None,
    fallback: str = FALLBACK_DISPLAY_TYPE,
) -> DisplayTypeChoice:
    """Pick the screenshotDisplayType to use.

    Preference order:
      1. ``override`` (explicit ``--display-type``), used verbatim.
      2. The largest iPhone display type that already exists in ASC.
      3. ``fallback`` -- the documented constant -- with ``reused=False`` so the
         caller can print a warning.

    ``APP_IPHONE_69`` is never returned: the API has no such value.
    """
    if override:
        return DisplayTypeChoice(str(override), False, "explicit --display-type override")

    candidates = []
    seen = set()
    for raw in available:
        if not raw:
            continue
        display_type = str(raw)
        if display_type in seen:
            continue
        seen.add(display_type)
        if not _is_iphone_display_type(display_type):
            continue
        candidates.append(display_type)

    if candidates:
        best = sorted(candidates, key=lambda item: (_display_type_rank(item), item))[0]
        return DisplayTypeChoice(best, True, "reused from an existing App Store Connect version")

    return DisplayTypeChoice(str(fallback), False, "documented fallback constant")



# ---------------------------------------------------------------------------
# Empty-submit probe: associated error flattening
# ---------------------------------------------------------------------------
# POSTing a reviewSubmissionItem for an incomplete version answers
#   409 STATE_ERROR.ENTITY_STATE_INVALID
# whose ``meta.associatedErrors`` holds the real list, keyed by resource path.
# Apple puts it on the first error object, not at the body top level:
#
#   {"errors": [{"status": "409", "code": "STATE_ERROR.ENTITY_STATE_INVALID",
#                "detail": "... check associated errors to see why",
#                "meta": {"associatedErrors": {
#                    "/v1/builds/b1": [{"code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
#                                       "detail": "... usesNonExemptEncryption ..."}]}}}]}
#
# Older payloads carry the same map one level up, at ``body.meta``; both are
# read.  That single response names *every* missing prerequisite -- in the 1.1
# run: builds.usesNonExemptEncryption, ageRatingDeclarations.socialMedia, and
# screenshots still in post-processing.  Without it ASC only says "check
# associated errors to see why".
AssociatedError = namedtuple(
    "AssociatedError", "resource code title detail parameters suggested_fix"
)

# Exactly two auto-fixes are safe enough to apply unattended.  Both are
# "declare false" defaults that ClipDock genuinely satisfies; neither changes
# user-visible metadata and both are reversible in App Store Connect.
#
#   attribute     -- the API attribute to PATCH
#   value         -- the safe value
#   targets       -- which resource type the attribute lives on
AUTO_FIXES: Dict[str, Dict[str, Any]] = {
    "usesNonExemptEncryption": {
        "attribute": "usesNonExemptEncryption",
        "value": False,
        "targets": ("build", "builds"),
        "why": "the build only uses HTTPS / Apple-provided crypto, so export compliance is plain false",
    },
    "socialMedia": {
        "attribute": "socialMedia",
        "value": False,
        "targets": ("appStoreVersionAgeRatingDeclaration", "ageRatingDeclaration", "appStoreVersions"),
        "why": "ClipDock has no social features, chat, or user-generated content feed",
    },
}

# Dotted paths ASC uses for the two known-safe attributes, longest first.
_AUTO_FIX_ALIASES = (
    ("builds.usesnonexemptencryption", "usesNonExemptEncryption"),
    ("build.usesnonexemptencryption", "usesNonExemptEncryption"),
    ("appstoreversionageratingdeclaration.socialmedia", "socialMedia"),
    ("ageratingdeclaration.socialmedia", "socialMedia"),
    ("appstoreversionageratingdeclarations.socialmedia", "socialMedia"),
    ("ageratingdeclarations.socialmedia", "socialMedia"),
    ("usesnonexemptencryption", "usesNonExemptEncryption"),
    ("socialmedia", "socialMedia"),
)

POINTER_ATTRIBUTE_RE = re.compile(r"/data/attributes/([A-Za-z0-9_]+)")


def _canonical_dotted(text: str) -> str:
    """Lowercase alphanumerics only, keeping dots: ``Builds.Uses_X`` -> ``builds.usesx``."""
    cleaned = re.sub(r"[^A-Za-z0-9.]+", ".", str(text or ""))
    return ".".join(part for part in cleaned.split(".") if part).lower()


def _pointer_attribute(*candidates: Any) -> Optional[str]:
    """Extract ``usesNonExemptEncryption`` from a JSON:API ``source.pointer``."""
    for candidate in candidates:
        if not isinstance(candidate, str):
            continue
        match = POINTER_ATTRIBUTE_RE.search(candidate)
        if match:
            return match.group(1)
        tail = candidate.rstrip("/").rsplit("/", 1)[-1]
        if tail and tail != candidate:
            return tail
    return None


def _error_from_payload(raw: Any, fallback_resource: str = "") -> AssociatedError:
    if not isinstance(raw, dict):
        return AssociatedError(fallback_resource, "", "", str(raw), {}, None)
    source = raw.get("source") if isinstance(raw.get("source"), dict) else {}
    parameters: Dict[str, Any] = {}
    if isinstance(source.get("parameters"), dict):
        parameters.update(source["parameters"])
    pointer = source.get("pointer")
    if pointer:
        parameters.setdefault("pointer", pointer)
    resource = raw.get("resource") or fallback_resource or pointer or ""
    return AssociatedError(
        str(resource),
        str(raw.get("code") or ""),
        str(raw.get("title") or ""),
        str(raw.get("detail") or ""),
        parameters,
        raw.get("suggestedFix"),
    )


def _flatten_associated_container(associated: Any, fallback_resource: str = "") -> List[AssociatedError]:
    """One ``associatedErrors`` value: a dict keyed by resource path, or a list."""
    results: List[AssociatedError] = []
    if isinstance(associated, dict):
        for resource, entries in associated.items():
            for entry in entries if isinstance(entries, list) else [entries]:
                results.append(_error_from_payload(entry, str(resource)))
    elif isinstance(associated, list):
        for entry in associated:
            results.append(_error_from_payload(entry, fallback_resource))
    return results


def flatten_associated_errors(payload: Any) -> List[AssociatedError]:
    """Flatten a 409 payload into an ordered list of associated errors.

    Looks in this order and keeps the first place that yields anything:
      1. ``errors[i].meta.associatedErrors`` on each top-level error -- the
         real ASC shape: a dict keyed by resource path, or a flat list
      2. ``meta.associatedErrors`` at the body top level (the older shape)
      3. the top-level ``errors`` list itself, only when neither of the
         above produced anything (no associated detail available)
    """
    if not isinstance(payload, dict):
        return []
    top_errors = payload.get("errors") or []

    results: List[AssociatedError] = []
    for entry in top_errors:
        if not isinstance(entry, dict):
            continue
        meta = entry.get("meta") if isinstance(entry.get("meta"), dict) else {}
        results.extend(_flatten_associated_container(meta.get("associatedErrors")))
    if results:
        return results

    meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
    results = _flatten_associated_container(meta.get("associatedErrors"))
    if results:
        return results

    return [_error_from_payload(entry) for entry in top_errors]


def error_blob(error: AssociatedError) -> str:
    """Every text field of an error joined and lowercased, for matching."""
    return " ".join(
        (error.resource, error.code, error.title, error.detail)
        + tuple(str(value) for value in (error.parameters or {}).values() if value)
    ).lower()


def fix_target(error: AssociatedError) -> Optional[str]:
    """The auto-fix key this error maps to, or None.

    Matching looks at the JSON:API pointer, the resource path, then free text,
    because ASC is not consistent about which one carries the attribute name.
    """
    pointer = (error.parameters or {}).get("pointer") or (error.parameters or {}).get("attribute")
    attribute = _pointer_attribute(pointer)
    if attribute:
        lowered = attribute.lower()
        for name in AUTO_FIXES:
            if lowered == name.lower():
                return name

    resource = _canonical_dotted(error.resource)
    if resource:
        for dotted, name in _AUTO_FIX_ALIASES:
            if resource == dotted or resource.endswith("." + dotted) or resource.startswith(dotted + "."):
                return name
        for dotted, name in _AUTO_FIX_ALIASES:
            if dotted in resource:
                return name

    # The attribute path can also arrive as source.parameter, e.g.
    # {"source": {"parameter": "usesNonExemptEncryption"}}.
    parameter = str((error.parameters or {}).get("parameter") or "")
    if parameter:
        lowered = _canonical_dotted(parameter)
        for name in AUTO_FIXES:
            if lowered == name.lower():
                return name

    blob = _canonical_dotted(error_blob(error))
    for dotted, name in _AUTO_FIX_ALIASES:
        if dotted in blob:
            return name
    return None


def error_dedupe_key(error: AssociatedError) -> str:
    return "|".join((error.resource, error.code, error.detail))


def dedupe_errors(errors: Iterable[AssociatedError]) -> List[AssociatedError]:
    out: List[AssociatedError] = []
    seen = set()
    for error in errors:
        key = error_dedupe_key(error)
        if key in seen:
            continue
        seen.add(key)
        out.append(error)
    return out


def is_screenshot_processing_error(error: AssociatedError) -> bool:
    """The transient "screenshots are still being processed" associated error."""
    blob = error_blob(error)
    if "screenshot" not in blob:
        return False
    return any(
        word in blob
        for word in ("processing", "not complete", "in progress", "not yet", "still")
    )


def is_waitable_error(error: AssociatedError) -> bool:
    """Errors that resolving by simply waiting for ASC can clear."""
    return is_screenshot_processing_error(error)


def describe_error(index: int, error: AssociatedError, total: Optional[int] = None) -> str:
    """A printable block: what ASC said and what this tool will do about it."""
    head = "%s%d." % ("", index) if total is None else "%d/%d." % (index, total)
    lines = ["%s %s" % (head, error.code or "(no code)")]
    if error.resource:
        lines.append("    resource: %s" % error.resource)
    if error.title:
        lines.append("    title:    %s" % error.title)
    if error.detail:
        lines.append("    detail:   %s" % error.detail)
    fix_name = fix_target(error)
    if fix_name:
        fix = AUTO_FIXES[fix_name]
        lines.append(
            "    action:   auto-fix %s = %r (only when currently null) -- %s"
            % (fix["attribute"], fix["value"], fix["why"])
        )
    elif is_waitable_error(error):
        lines.append("    action:   wait for screenshot assets to reach COMPLETE, then re-probe")
    else:
        lines.append("    action:   none available -- fix in App Store Connect or by hand, then re-probe")
    return "\n".join(lines)


def summarize_errors(errors: Sequence[AssociatedError], limit: int = 6) -> str:
    """Compact one-line-per-error summary for raised ApiError messages."""
    if not errors:
        return "no associated errors"
    shown = ["%s [%s] %s" % (e.code, e.resource, e.detail[:180]) for e in errors[:limit]]
    if len(errors) > limit:
        shown.append("... and %d more" % (len(errors) - limit))
    return "; ".join(shown)


def describe_errors(payload: Any) -> str:
    """Best-effort one-line description of any ASC error payload."""
    if not isinstance(payload, dict):
        return str(payload)[:300]
    associated = flatten_associated_errors(payload)
    top = payload.get("errors") or []
    if associated:
        return summarize_errors(associated)
    if top:
        return "; ".join(
            "%s: %s" % (entry.get("code"), (entry.get("title") or entry.get("detail") or ""))
            for entry in top
            if isinstance(entry, dict)
        )[:600]
    return json.dumps(payload)[:300]


# ---------------------------------------------------------------------------
# Credentials and JWT
# ---------------------------------------------------------------------------
Credentials = namedtuple("Credentials", "issuer key_id key_path")


def resolve_credentials(
    issuer: Optional[str],
    key_id: Optional[str],
    key_path: Optional[str],
    env: Optional[Dict[str, str]] = None,
) -> Credentials:
    """Flags win, then environment.  Raises CredentialError with a clear message."""
    env = os.environ if env is None else env
    issuer_v = (issuer or env.get("ASC_ISSUER_ID") or "").strip()
    key_id_v = (key_id or env.get("ASC_KEY_ID") or "").strip()
    key_path_v = (key_path or env.get("ASC_KEY_PATH") or "").strip()

    missing = []
    if not issuer_v:
        missing.append("issuer id (--issuer or ASC_ISSUER_ID)")
    if not key_id_v:
        missing.append("key id (--key-id or ASC_KEY_ID)")
    if not key_path_v:
        missing.append("key path (--key-path or ASC_KEY_PATH)")
    if missing:
        raise CredentialError(
            "missing App Store Connect credentials: " + "; ".join(missing) + "\n"
            "Export them first, e.g.\n"
            "    export ASC_ISSUER_ID=...  ASC_KEY_ID=...  ASC_KEY_PATH=~/path/AuthKey_<KEYID>.p8\n"
            "The private key is never read from this repository and never written to disk."
        )

    path = Path(os.path.expanduser(key_path_v))
    if not path.is_file():
        raise CredentialError("App Store Connect key file not found: %s" % path)
    if path.suffix.lower() != ".p8":
        raise CredentialError("expected a .p8 private key, got %s" % path)
    return Credentials(issuer_v, key_id_v, path)


def sign_with_openssl(key_path: Path, signing_input: bytes) -> bytes:
    """ES256-sign ``signing_input`` with openssl and return a raw 64-byte signature.

    Uses ``openssl dgst -sha256 -sign`` on purpose: it is on every macOS box, so
    the tool needs no third-party crypto package.
    """
    try:
        completed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
            input=signing_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except (OSError, FileNotFoundError) as exc:
        raise CredentialError(
            "could not run openssl (%s). It ships with macOS and Linux; install it or "
            "put it on PATH." % exc
        ) from exc
    if completed.returncode != 0:
        message = completed.stderr.decode("utf-8", "replace").strip()
        raise CredentialError(
            "openssl could not sign with %s: %s" % (key_path.name, message or "no stderr")
        )
    return der_to_raw_signature(completed.stdout)


def mint_jwt(credentials: Credentials, now: Optional[float] = None) -> str:
    """Mint a fresh ES256 bearer token.  Never log the result."""
    segments, _header, _payload = build_jwt_segments(
        credentials.key_id, credentials.issuer, time.time() if now is None else now
    )
    signature = sign_with_openssl(credentials.key_path, segments.encode("ascii"))
    return "%s.%s" % (segments, b64u(signature))


# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------
class AscClient:
    """Tiny JSON:API client.  Read-only paths stay readable even in dry-run."""

    def __init__(
        self,
        credentials: Optional[Credentials],
        app_id: str,
        dry_run: bool = False,
        verbose: bool = False,
        timeout: int = 120,
        log: Optional[Callable[[str], None]] = None,
        clock: Callable[[], float] = time.time,
    ):
        self.credentials = credentials
        self.app_id = app_id
        self.dry_run = dry_run
        self.verbose = verbose
        self.timeout = timeout
        self.log = log or (lambda message: print(message, file=sys.stderr))
        self._clock = clock
        self._token: Optional[str] = None
        self._token_minted_at = 0.0
        self.calls: List[Tuple[str, str]] = []

    # -- auth -------------------------------------------------------------
    def token(self) -> str:
        if self.credentials is None:
            raise CredentialError(
                "this command needs an App Store Connect API key; pass --issuer/--key-id/"
                "--key-path or set ASC_ISSUER_ID/ASC_KEY_ID/ASC_KEY_PATH"
            )
        # Refresh well before the 19-minute expiry.
        if self._token is None or (self._clock() - self._token_minted_at) > 900:
            self._token = mint_jwt(self.credentials, now=self._clock())
            self._token_minted_at = self._clock()
            if self.verbose:
                self.log("[auth] minted ES256 token (redacted)")
        return self._token

    # -- transport --------------------------------------------------------
    def request(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        expect: Sequence[int] = (200, 201, 204),
        allow_status: Sequence[int] = (),
    ) -> Tuple[int, Any]:
        """One API call.  Returns (status, parsed JSON).  Raises AscApiError."""
        method = method.upper()
        url = path if path.startswith("http") else API_BASE + path
        self.calls.append((method, path))
        payload = None if body is None else json.dumps(body).encode("utf-8")

        if self.verbose:
            self.log("[api] %s %s" % (method, path if not path.startswith("http") else "<upload-url>"))
            if body is not None:
                self.log("[api]   body: " + json.dumps(redact_body(body), ensure_ascii=False))

        headers = {"Accept": "application/json"}
        if payload is not None:
            headers["Content-Type"] = "application/json"
        if path.startswith(API_BASE) or not path.startswith("http"):
            headers["Authorization"] = "Bearer " + self.token()

        request = urllib.request.Request(url, data=payload, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read() or b""
        except urllib.error.URLError as exc:
            raise AscApiError(method, path, 0, {"errors": [{"detail": str(exc.reason)}]}) from exc

        parsed: Any
        if raw:
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                parsed = {"raw": raw[:500].decode("utf-8", "replace")}
        else:
            parsed = {}

        if status in allow_status:
            return status, parsed
        if status not in expect:
            raise AscApiError(method, path, status, parsed, note=self._hint_for(method, path, status))
        return status, parsed

    def _hint_for(self, method: str, path: str, status: int) -> str:
        if status == 403 and "/v1/builds" in path:
            return BUILD_ACCESS_403_HINT
        if status == 401:
            return (
                "401 means the JWT was rejected: check that --key-id matches the .p8 file, "
                "that the issuer id is the *team* issuer (Users and Access -> Integrations), "
                "and that the key has not been revoked."
            )
        if status == 403:
            return (
                "403 means this key lacks permission for %s. ClipDock's Sales and Trends key "
                "(AuthKey_7XL5564K84.p8) cannot read builds or submit; use the App Manager key "
                "(AuthKey_YYK7P6W893.p8)." % path
            )
        return ""

    # -- mutating calls honour --dry-run ----------------------------------
    def write(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        expect: Sequence[int] = (200, 201, 204),
        description: str = "",
        allow_status: Sequence[int] = (),
    ) -> Tuple[int, Any]:
        """A call that changes state.  In dry-run prints and returns (0, {})."""
        method = method.upper()
        if self.dry_run:
            print("[dry-run] %s %s%s" % (method, path, ("  # " + description) if description else ""))
            if body is not None:
                print("[dry-run]   body: " + json.dumps(redact_body(body), ensure_ascii=False, sort_keys=True))
            return 0, {}
        if self.verbose and description:
            self.log("[api] %s (%s)" % (method, description))
        return self.request(method, path, body, expect=expect, allow_status=allow_status)

    # -- convenience GETs -------------------------------------------------
    def get(self, path: str) -> Any:
        _status, payload = self.request("GET", path)
        return payload

    def paginate(self, path: str, max_pages: int = 10) -> List[dict]:
        """Follow ``links.next`` up to max_pages and concatenate ``data``."""
        items: List[dict] = []
        url = path
        for _ in range(max_pages):
            payload = self.get(url)
            items.extend(payload.get("data") or [])
            next_link = (payload.get("links") or {}).get("next")
            if not next_link:
                break
            url = next_link
        return items


# ---------------------------------------------------------------------------
# Resource lookups
# ---------------------------------------------------------------------------
_VERSION_FIELDS = "versionString,platform,appStoreState,appVersionState,createdDate,releaseType"
_BUILD_FIELDS = "version,processingState,uploadedDate,expired,usesNonExemptEncryption"


def fetch_app(client: AscClient) -> dict:
    payload = client.get("/v1/apps/%s" % client.app_id)
    return payload.get("data") or {}


def fetch_versions(client: AscClient, limit: int = 50) -> List[dict]:
    return client.paginate(
        "/v1/apps/%s/appStoreVersions?limit=%d&fields[appStoreVersions]=%s"
        % (client.app_id, limit, _VERSION_FIELDS)
    )


def find_version(versions: Iterable[dict], version_string: str) -> Optional[dict]:
    for version in versions:
        attributes = version.get("attributes") or {}
        if str(attributes.get("versionString")) == str(version_string):
            if str(attributes.get("platform") or "IOS").upper() != "IOS":
                continue
            return version
    return None


def fetch_builds(client: AscClient, limit: int = 25) -> List[dict]:
    return client.paginate(
        "/v1/builds?filter[app]=%s&sort=-uploadedDate&limit=%d&fields[builds]=%s"
        % (client.app_id, limit, _BUILD_FIELDS)
    )


def find_build(builds: Iterable[dict], version_string: str) -> Optional[dict]:
    """Newest build whose ``version`` attribute matches, VALID preferred."""
    matches = [
        build
        for build in builds
        if str((build.get("attributes") or {}).get("version")) == str(version_string)
    ]
    if not matches:
        return None
    valid = [b for b in matches if (b.get("attributes") or {}).get("processingState") == "VALID"]
    return (valid or matches)[0]


def is_build_ready(build: dict) -> bool:
    return (build.get("attributes") or {}).get("processingState") == "VALID"


def fetch_review_submissions(client: AscClient, limit: int = 20) -> List[dict]:
    return client.paginate(
        "/v1/reviewSubmissions?filter[app]=%s&filter[platform]=IOS&limit=%d"
        % (client.app_id, limit)
    )


OPEN_SUBMISSION_STATES = ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES")
DONE_SUBMISSION_STATES = ("WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETE")


def pick_open_submission(submissions: Iterable[dict]) -> Optional[dict]:
    """The editable submission, if ASC already has one for this app."""
    for submission in submissions:
        if (submission.get("attributes") or {}).get("state") in OPEN_SUBMISSION_STATES:
            return submission
    return None


def find_waiting_submission(submissions: Iterable[dict]) -> Optional[dict]:
    for submission in submissions:
        state = (submission.get("attributes") or {}).get("state")
        if state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
            return submission
    return None


def fetch_localizations(client: AscClient, version_id: str) -> List[dict]:
    return client.paginate(
        "/v1/appStoreVersions/%s/appStoreVersionLocalizations?limit=50" % version_id
    )


def fetch_screenshot_sets(client: AscClient, localization_id: str) -> List[dict]:
    return client.paginate(
        "/v1/appStoreVersionLocalizations/%s/appScreenshotSets?limit=20" % localization_id
    )


def fetch_screenshots(client: AscClient, set_id: str) -> List[dict]:
    return client.paginate("/v1/appScreenshotSets/%s/appScreenshots?limit=50" % set_id)


def existing_display_types(sets: Iterable[dict]) -> List[str]:
    return [
        str((item.get("attributes") or {}).get("screenshotDisplayType"))
        for item in sets
        if (item.get("attributes") or {}).get("screenshotDisplayType")
    ]


def collect_reusable_display_types(client: AscClient, version_id: str) -> List[str]:
    """Every screenshotDisplayType already present anywhere on this version."""
    found: List[str] = []
    for localization in fetch_localizations(client, version_id):
        for display_type in existing_display_types(
            fetch_screenshot_sets(client, localization["id"])
        ):
            if display_type not in found:
                found.append(display_type)
    return found


def collect_display_types_from_other_versions(client: AscClient, versions: Iterable[dict]) -> List[str]:
    """Fall back to any other version of the app when this one has no sets yet."""
    found: List[str] = []
    for version in versions:
        attributes = version.get("attributes") or {}
        if str(attributes.get("appStoreState") or "") in ("PREPARE_FOR_SUBMISSION",):
            continue
        for localization in fetch_localizations(client, version["id"]):
            for display_type in existing_display_types(
                fetch_screenshot_sets(client, localization["id"])
            ):
                if display_type not in found:
                    found.append(display_type)
        if found:
            break
    return found


def resolve_display_type(
    client: AscClient,
    version_id: str,
    versions: Iterable[dict],
    override: Optional[str] = None,
) -> DisplayTypeChoice:
    """Reuse an existing displayType, warning loudly if we must fall back."""
    if override:
        return choose_display_type([], override=override)
    available = collect_reusable_display_types(client, version_id)
    if not available:
        available = collect_display_types_from_other_versions(client, versions)
    choice = choose_display_type(available)
    if not choice.reused:
        print(
            "WARNING: no existing iPhone screenshot set found on any App Store Connect "
            "version, so falling back to the documented constant %s.\n"
            "         That constant accepts %s and is the largest valid iPhone display type,\n"
            "         but it may not be the type Apple expects for this app -- check the\n"
            "         version's screenshots page before submitting."
            % (
                choice.display_type,
                " / ".join("%dx%d" % pair for pair in ACCEPTED_SCREENSHOT_SIZES.get(choice.display_type, ())),
            ),
            file=sys.stderr,
        )
    elif choice.display_type in INVALID_DISPLAY_TYPES:
        raise UsageError(
            "%s is not a valid screenshotDisplayType; ASC rejects it with "
            "ENTITY_ERROR.ATTRIBUTE.TYPE" % choice.display_type
        )
    return choice


# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------
def describe_version(version: dict) -> str:
    attributes = version.get("attributes") or {}
    return "%-8s %-12s appStoreState=%-24s appVersionState=%s" % (
        attributes.get("versionString") or "?",
        attributes.get("platform") or "IOS",
        attributes.get("appStoreState") or "?",
        attributes.get("appVersionState") or "?",
    )


def command_probe(client: AscClient, args: argparse.Namespace) -> int:
    """Read-only snapshot.  Safe to run any time, key or no key for --help."""
    print("== App ==")
    app = fetch_app(client)
    app_attributes = app.get("attributes") or {}
    print("  id:        %s" % app.get("id", client.app_id))
    print("  name:      %s" % (app_attributes.get("name") or "?"))
    print("  bundleId:  %s" % (app_attributes.get("bundleId") or "?"))
    print("  sku:       %s" % (app_attributes.get("sku") or "?"))

    print("\n== appStoreVersions ==")
    versions = fetch_versions(client)
    if not versions:
        print("  (none)")
    for version in versions:
        print("  %s  id=%s" % (describe_version(version), version.get("id")))

    print("\n== builds (newest first) ==")
    builds = fetch_builds(client, limit=10)
    if not builds:
        print("  (none)")
    for build in builds:
        attributes = build.get("attributes") or {}
        print(
            "  build %-6s %-14s uploaded=%s expired=%s id=%s"
            % (
                attributes.get("version") or "?",
                attributes.get("processingState") or "?",
                attributes.get("uploadedDate") or "?",
                attributes.get("expired"),
                build.get("id"),
            )
        )

    print("\n== reviewSubmissions ==")
    submissions = fetch_review_submissions(client)
    if not submissions:
        print("  (none)")
    for submission in submissions:
        attributes = submission.get("attributes") or {}
        print(
            "  %s state=%-20s submitted=%s id=%s"
            % (
                (submission.get("id") or "?")[:8],
                attributes.get("state") or "?",
                attributes.get("submittedDate") or "-",
                submission.get("id"),
            )
        )

    if args.version:
        print("\n== target version %s ==" % args.version)
        version = find_version(versions, args.version)
        if not version:
            print("  NOT FOUND -- create it in App Store Connect or with this tool's runbook")
        else:
            print("  id=%s" % version.get("id"))
            build = None
            try:
                build = (client.get("/v1/appStoreVersions/%s/build" % version["id"]) or {}).get("data")
            except AscApiError as exc:
                print("  build relationship unreadable: %s" % exc)
            print("  attached build: %s" % ((build or {}).get("id") or "(none)"))
            localizations = fetch_localizations(client, version["id"])
            print("  localizations: %d" % len(localizations))
            for localization in localizations:
                attributes = localization.get("attributes") or {}
                sets = fetch_screenshot_sets(client, localization["id"])
                print(
                    "    %-10s whatsNew=%s sets=%s"
                    % (
                        attributes.get("locale") or "?",
                        "yes" if (attributes.get("whatsNew") or "").strip() else "EMPTY",
                        ", ".join(existing_display_types(sets)) or "(none)",
                    )
                )
    return EXIT_OK


# ---------------------------------------------------------------------------
# preflight: the empty-submit error probe
# ---------------------------------------------------------------------------
ProbeResult = namedtuple(
    "ProbeResult", "clean status errors submission_id item_created dry"
)


def ensure_open_submission(client: AscClient, args: argparse.Namespace) -> dict:
    """Reuse the app's open review submission, or create a throwaway one.

    An empty submission with no items is harmless and ASC hands the same one
    back next time, so probing does not pile up junk.
    """
    if getattr(args, "submission_id", None):
        payload = client.get("/v1/reviewSubmissions/%s" % args.submission_id)
        data = payload.get("data") or {}
        if not data:
            raise UsageError("review submission %s not found" % args.submission_id)
        return data

    submissions = fetch_review_submissions(client)
    open_submission = pick_open_submission(submissions)
    if open_submission:
        print(
            "  reusing open reviewSubmission %s (state=%s)"
            % (open_submission["id"], (open_submission.get("attributes") or {}).get("state"))
        )
        return open_submission

    waiting = find_waiting_submission(submissions)
    if waiting:
        print(
            "  WARNING: submission %s is already %s; ASC allows one submission in flight per app."
            % (waiting["id"], (waiting.get("attributes") or {}).get("state"))
        )

    body = {
        "data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": client.app_id}}},
        }
    }
    status, payload = client.write(
        "POST",
        "/v1/reviewSubmissions",
        body,
        description="create a review submission to probe against",
    )
    if status == 0:  # dry-run
        return {"id": "<new-review-submission>", "attributes": {"state": "READY_FOR_REVIEW"}}
    data = payload.get("data") or {}
    print("  created reviewSubmission %s (state=%s)" % (data.get("id"), (data.get("attributes") or {}).get("state")))
    return data


def probe_submission_errors(
    client: AscClient, version_id: str, submission_id: str
) -> ProbeResult:
    """POST a reviewSubmissionItem and read meta.associatedErrors from the 409.

    A clean probe means the item was created (status 201); the item is
    deleted again before returning, so probing is side-effect free and never
    leaves a stray item pointing at the version.  On 409 nothing was created,
    so there is nothing to delete.  The real submit attaches its own fresh
    item with ``attach_submission_item``.
    """
    body = {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
            },
        }
    }
    if client.dry_run:
        # The probe is itself a write, so dry-run only prints it. Nothing is
        # verified -- say so rather than implying a clean bill of health.
        print("[dry-run] POST /v1/reviewSubmissionItems")
        print("[dry-run]   body: " + json.dumps(redact_body(body), ensure_ascii=False, sort_keys=True))
        print("[dry-run]   would read meta.associatedErrors from a 409; not sent, so nothing was verified")
        return ProbeResult(None, 0, [], submission_id, False, True)
    status, payload = client.request(
        "POST", "/v1/reviewSubmissionItems", body, allow_status=(201, 409)
    )
    if status == 201:
        item_id = (payload.get("data") or {}).get("id")
        if item_id:
            # The probe must not leave anything behind: a version sitting in
            # Ready for Review with a stray item stops accepting screenshot
            # changes, and a second item for the same version breaks submit.
            client.request(
                "DELETE",
                "/v1/reviewSubmissionItems/%s" % item_id,
                expect=(200, 204),
            )
        return ProbeResult(True, status, [], submission_id, True, False)
    if status == 409:
        errors = dedupe_errors(flatten_associated_errors(payload))
        return ProbeResult(False, status, errors, submission_id, False, False)
    raise AscApiError(
        "POST",
        "/v1/reviewSubmissionItems",
        status,
        payload,
        note="expected 201 (clean) or 409 (prerequisites listed in meta.associatedErrors)",
    )


def attach_submission_item(client: AscClient, version_id: str, submission_id: str) -> List[AssociatedError]:
    """POST the version item into the submission and KEEP it: ASC refuses to
    submit a submission that does not contain the target version.

    The probe deletes the item it creates, and ``--skip-preflight`` never
    creates one, so the real submit must attach a fresh item itself, right
    before PATCHing ``submitted: true``.  Returns the deduped associated
    errors when ASC refuses (409) -- the caller must not submit then -- or
    an empty list when the item is attached (or dry-run printed the attempt).
    """
    body = {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
            },
        }
    }
    status, payload = client.write(
        "POST",
        "/v1/reviewSubmissionItems",
        body,
        description="attach the version to the review submission",
        allow_status=(201, 409),
    )
    if status in (0, 201):
        return []
    if status == 409:
        return dedupe_errors(flatten_associated_errors(payload))
    raise AscApiError(
        "POST",
        "/v1/reviewSubmissionItems",
        status,
        payload,
        note="expected 201 (item attached) or 409 (prerequisites listed in meta.associatedErrors)",
    )


def print_probe_errors(errors: Sequence[AssociatedError]) -> None:
    total = len(errors)
    for index, error in enumerate(errors, 1):
        print(describe_error(index, error, total=total))
        print("")


def fetch_build_detail(client: AscClient, build_id: str) -> dict:
    payload = client.get("/v1/builds/%s?fields[builds]=version,processingState,usesNonExemptEncryption" % build_id)
    return payload.get("data") or {}


def fetch_app_infos(client: AscClient) -> List[dict]:
    return client.paginate("/v1/apps/%s/appInfos?limit=50" % client.app_id)


def pick_app_info(app_infos: Sequence[dict], version: dict) -> Optional[dict]:
    """The appInfo that owns this version: the one whose appStoreVersion
    relationship points at it, or the only appInfo when there is just one."""
    if not app_infos:
        return None
    version_id = version.get("id")
    for info in app_infos:
        relationships = info.get("relationships") or {}
        linked = (relationships.get("appStoreVersion") or {}).get("data") or {}
        if version_id and linked.get("id") == version_id:
            return info
    if len(app_infos) == 1:
        return app_infos[0]
    return None


def fetch_age_rating_declaration(client: AscClient, version: dict) -> Optional[dict]:
    """Read the version's age rating declaration through its appInfo.

    Apple removed ``GET /v1/appStoreVersions/{id}/ageRatingDeclaration`` in
    API 4.3; the declaration now hangs off the appInfo:
    ``GET /v1/apps/{appId}/appInfos`` to resolve the appInfo, then
    ``GET /v1/appInfos/{appInfoId}/ageRatingDeclaration``.  Prints exactly
    why it cannot be resolved and returns None in that case.
    """
    try:
        app_infos = fetch_app_infos(client)
    except AscApiError as exc:
        print("  ageRatingDeclaration unresolved: could not list appInfos: %s" % exc)
        return None
    if not app_infos:
        print(
            "  ageRatingDeclaration unresolved: app %s has no appInfos "
            "(the per-version endpoint was removed in API 4.3)" % client.app_id
        )
        return None
    app_info = pick_app_info(app_infos, version)
    if not app_info:
        print(
            "  ageRatingDeclaration unresolved: none of the %d appInfos on app %s "
            "points at version %s" % (len(app_infos), client.app_id, version.get("id"))
        )
        return None
    try:
        payload = client.get("/v1/appInfos/%s/ageRatingDeclaration" % app_info["id"])
    except AscApiError as exc:
        print("  could not read ageRatingDeclaration: %s" % exc)
        return None
    declaration = payload.get("data") or None
    if not declaration:
        print("  appInfo %s has no ageRatingDeclaration" % app_info["id"])
    return declaration


def apply_auto_fixes(
    client: AscClient,
    errors: Sequence[AssociatedError],
    version: dict,
    build: Optional[dict],
) -> List[str]:
    """Apply the known-safe fixes, and only where the value is currently null.

    Returns a list of human-readable outcomes.  Anything not in AUTO_FIXES is
    left alone on purpose -- this tool does not guess at metadata.
    """
    outcomes: List[str] = []
    wanted = []
    for error in errors:
        name = fix_target(error)
        if name and name not in wanted:
            wanted.append(name)
    if not wanted:
        return outcomes

    for name in wanted:
        fix = AUTO_FIXES[name]
        if name == "usesNonExemptEncryption":
            if not build:
                outcomes.append("skip usesNonExemptEncryption: no build attached/resolved yet")
                continue
            detail = fetch_build_detail(client, build["id"])
            current = (detail.get("attributes") or {}).get("usesNonExemptEncryption")
            if current is not None:
                outcomes.append(
                    "skip usesNonExemptEncryption: build %s already declares %r"
                    % ((detail.get("attributes") or {}).get("version") or build["id"], current)
                )
                continue
            body = {
                "data": {
                    "type": "builds",
                    "id": build["id"],
                    "attributes": {"usesNonExemptEncryption": fix["value"]},
                }
            }
            client.write(
                "PATCH",
                "/v1/builds/%s" % build["id"],
                body,
                description="export compliance: usesNonExemptEncryption=false",
            )
            outcomes.append("set usesNonExemptEncryption=false on build %s" % build["id"])

        elif name == "socialMedia":
            declaration = fetch_age_rating_declaration(client, version)
            if not declaration:
                outcomes.append(
                    "skip socialMedia: no ageRatingDeclaration resolved for version %s"
                    % version.get("id")
                )
                continue
            current = (declaration.get("attributes") or {}).get("socialMedia")
            if current is not None:
                outcomes.append("skip socialMedia: already declares %r" % (current,))
                continue
            body = {
                "data": {
                    "type": "ageRatingDeclarations",
                    "id": declaration["id"],
                    "attributes": {"socialMedia": fix["value"]},
                }
            }
            client.write(
                "PATCH",
                "/v1/ageRatingDeclarations/%s" % declaration["id"],
                body,
                description="age rating: socialMedia=false",
            )
            outcomes.append("set socialMedia=false on ageRatingDeclaration %s" % declaration["id"])
    return outcomes


def wait_for_screenshot_assets(
    client: AscClient, version_id: str, timeout: float = 600.0, interval: float = 15.0
) -> bool:
    """Poll every screenshot on the version until assets are COMPLETE.

    Returns True when everything is ready (or there is nothing to wait for).
    """
    deadline = time.time() + timeout
    announced = False
    while True:
        pending = 0
        failed: List[str] = []
        for localization in fetch_localizations(client, version_id):
            for screenshot_set in fetch_screenshot_sets(client, localization["id"]):
                for screenshot in fetch_screenshots(client, screenshot_set["id"]):
                    state = ((screenshot.get("attributes") or {}).get("assetDeliveryState") or {}).get("state")
                    if state == "COMPLETE":
                        continue
                    if state in ("FAILED",):
                        failed.append(
                            "%s/%s"
                            % (
                                (localization.get("attributes") or {}).get("locale"),
                                (screenshot.get("attributes") or {}).get("fileName") or screenshot["id"],
                            )
                        )
                    else:
                        pending += 1
        if failed:
            print("  screenshot asset processing FAILED: %s" % ", ".join(failed))
            return False
        if pending == 0:
            if announced:
                print("  all screenshot assets COMPLETE")
            return True
        if time.time() >= deadline:
            print("  timed out with %d screenshot asset(s) still processing" % pending)
            return False
        if not announced:
            print("  waiting for %d screenshot asset(s) to finish processing..." % pending)
            announced = True
        time.sleep(interval)


def command_preflight(client: AscClient, args: argparse.Namespace) -> int:
    """Probe, report, optionally fix, re-probe.  Non-zero while unresolved."""
    if not args.version:
        raise UsageError("preflight needs --version, e.g. --version 1.1")

    print("== preflight %s ==" % args.version)
    versions = fetch_versions(client)
    version = find_version(versions, args.version)
    if not version:
        print(
            "ERROR: no iOS appStoreVersion %r on app %s. Create it first (Xcode or ASC UI)."
            % (args.version, client.app_id),
            file=sys.stderr,
        )
        return EXIT_USAGE
    print("  version id: %s (%s)" % (version["id"], describe_version(version).split("appStoreState=")[-1]))

    build: Optional[dict] = None
    if args.build:
        build = find_build(fetch_builds(client), args.build)
        if not build:
            print(
                "  WARNING: build %r not found on app %s; preflight will not attach it."
                % (args.build, client.app_id)
            )
    if build is None:
        try:
            attached = (client.get("/v1/appStoreVersions/%s/build" % version["id"]) or {}).get("data")
        except AscApiError:
            attached = None
        if attached:
            build = attached
    if build:
        print("  build: %s (%s)" % (build.get("id"), (build.get("attributes") or {}).get("processingState") or "?"))

    submission = ensure_open_submission(client, args)
    submission_id = submission.get("id")

    attempts = max(1, int(args.max_probes))
    final_errors: List[AssociatedError] = []
    for attempt in range(1, attempts + 1):
        print("\n-- probe attempt %d/%d (POST /v1/reviewSubmissionItems) --" % (attempt, attempts))
        result = probe_submission_errors(client, version["id"], submission_id)
        if result.dry:
            print("\npreflight: DRY RUN -- the probe was not sent, so nothing was verified.")
            print("Re-run without --dry-run to read meta.associatedErrors for real.")
            return EXIT_OK
        if result.clean:
            print("  CLEAN: ASC accepted the version as reviewable (no associated errors).")
            print("\npreflight: OK -- %s is ready to submit." % args.version)
            return EXIT_OK

        print("  ASC rejected the item (HTTP %s). Associated errors:" % result.status)
        print("")
        print_probe_errors(result.errors)
        final_errors = result.errors

        if not args.fix:
            print("Re-run with --fix to apply the two known-safe fixes and wait for assets,")
            print("then probe again. Nothing above is resolved automatically without --fix.")
            break

        fixes_applied = apply_auto_fixes(client, result.errors, version, build)
        for outcome in fixes_applied:
            print("  fix: %s" % outcome)

        if any(is_waitable_error(error) for error in result.errors):
            if not wait_for_screenshot_assets(client, version["id"], timeout=args.wait_timeout):
                print("  screenshots did not become ready; stopping.", file=sys.stderr)
                break
        elif not fixes_applied:
            print("  nothing this tool may change automatically; stopping.", file=sys.stderr)
            break

        if attempt < attempts:
            time.sleep(args.probe_interval)

    print("\npreflight: UNRESOLVED -- %d associated error(s) remain." % len(final_errors), file=sys.stderr)
    print(
        "Fix them in App Store Connect (or with the API) and re-run. Submitting now would "
        "fail with only 'STATE_ERROR.ENTITY_STATE_INVALID', which is why this probe exists.",
        file=sys.stderr,
    )
    return EXIT_UNRESOLVED


# ---------------------------------------------------------------------------
# screenshots
# ---------------------------------------------------------------------------
LocaleFiles = namedtuple("LocaleFiles", "locale files")


def parse_locale_dirs(values: Sequence[str]) -> List[Tuple[str, Path]]:
    """``--locale-dir en-US=path`` (repeatable) -> [(locale, Path)]."""
    parsed: List[Tuple[str, Path]] = []
    for raw in values:
        if "=" not in raw:
            raise UsageError(
                "--locale-dir needs locale=path, e.g. --locale-dir en-US=./out/en -- got %r" % raw
            )
        locale, _, path_text = raw.partition("=")
        locale = locale.strip()
        if not locale:
            raise UsageError("--locale-dir %r has an empty locale" % raw)
        path = Path(os.path.expanduser(path_text.strip()))
        if not path.is_dir():
            raise UsageError("--locale-dir %s: %s is not a directory" % (locale, path))
        parsed.append((locale, path))
    if not parsed:
        raise UsageError("screenshots needs at least one --locale-dir locale=path")
    return parsed


SCREENSHOT_NAME_RE = re.compile(r"^(\d{1,3})")


def collect_screenshot_files(directory: Path) -> List[Path]:
    """Numbered PNGs in a locale directory, ordered 01,02,... then by name."""
    files = [path for path in directory.iterdir() if path.is_file() and path.suffix.lower() == ".png"]
    if not files:
        raise UsageError("no .png files in %s" % directory)

    def sort_key(path: Path) -> Tuple[int, str]:
        match = SCREENSHOT_NAME_RE.match(path.name)
        return (int(match.group(1)) if match else 10_000, path.name)

    return sorted(files, key=sort_key)


def plan_screenshot_uploads(
    locale_dirs: Sequence[Tuple[str, Path]], display_type: str
) -> Tuple[List[LocaleFiles], List[str]]:
    """Resolve files per locale and collect any size mismatches as warnings."""
    plan: List[LocaleFiles] = []
    warnings: List[str] = []
    for locale, directory in locale_dirs:
        files = collect_screenshot_files(directory)
        for path in files:
            problem = check_screenshot_size(path, display_type)
            if problem:
                warnings.append("%s: %s" % (locale, problem))
        plan.append(LocaleFiles(locale, files))
    return plan, warnings


def upload_bytes_to_operations(client: AscClient, upload_operations: Sequence[dict], data: bytes, label: str) -> None:
    """PUT each byte range to its pre-signed URL (no ASC auth on these URLs)."""
    for chunk in slice_upload_operations(data, upload_operations):
        headers = {
            header.get("name"): header.get("value")
            for header in (chunk.operation.get("requestHeaders") or [])
            if header.get("name")
        }
        method = str(chunk.operation.get("method") or "PUT").upper()
        url = chunk.operation.get("url")
        if not url:
            raise UsageError("upload operation for %s has no url" % label)
        if client.dry_run:
            print(
                "[dry-run] %s <upload-url>  # %s bytes %d..%d of %s"
                % (method, label, chunk.offset, chunk.offset + chunk.length, label)
            )
            continue
        if client.verbose:
            client.log("[upload] %s bytes %d..%d of %s" % (method, chunk.offset, chunk.offset + chunk.length, label))
        request = urllib.request.Request(url, data=chunk.chunk, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=client.timeout * 2) as response:
                response.read()
                if response.status not in (200, 201, 204):
                    raise AscApiError(method, "<upload-url>", response.status, {"errors": [{"detail": "chunk rejected"}]})
        except urllib.error.HTTPError as exc:
            raise AscApiError(
                method,
                "<upload-url>",
                exc.code,
                {"errors": [{"detail": "upload chunk %d..%d rejected" % (chunk.offset, chunk.offset + chunk.length)}]},
            ) from exc


def ensure_screenshot_set(client: AscClient, localization_id: str, display_type: str) -> Optional[str]:
    """Return the set id for display_type, creating it when missing."""
    for screenshot_set in fetch_screenshot_sets(client, localization_id):
        if (screenshot_set.get("attributes") or {}).get("screenshotDisplayType") == display_type:
            return screenshot_set["id"]
    body = {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {
                "appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": localization_id}
                }
            },
        }
    }
    print("  creating appScreenshotSet %s" % display_type)
    status, payload = client.write(
        "POST", "/v1/appScreenshotSets", body, description="create %s set" % display_type
    )
    if status == 0:
        return None
    created = payload.get("data") or {}
    print("  created set %s" % created.get("id"))
    return created.get("id")


def clear_screenshot_set(client: AscClient, set_id: str) -> int:
    """Delete every existing screenshot in the set.  Returns how many were removed."""
    removed = 0
    for screenshot in fetch_screenshots(client, set_id):
        status, _payload = client.write(
            "DELETE",
            "/v1/appScreenshots/%s" % screenshot["id"],
            None,
            description="delete old screenshot",
        )
        if status == 0 or status in (200, 204):
            removed += 1
    return removed


def upload_one_screenshot(client: AscClient, set_id: str, path: Path) -> Optional[str]:
    """reserve -> PUT chunks -> PATCH uploaded=true with the MD5 checksum."""
    data = path.read_bytes()
    checksum = md5_hexdigest_bytes(data)
    body = {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileName": path.name, "fileSize": len(data)},
            "relationships": {
                "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}
            },
        }
    }
    status, payload = client.write(
        "POST", "/v1/appScreenshots", body, description="reserve %s" % path.name
    )
    if status == 0:
        print("[dry-run] MD5(%s) = %s" % (path.name, checksum))
        return None
    reserved = payload.get("data") or {}
    screenshot_id = reserved.get("id")
    operations = (reserved.get("attributes") or {}).get("uploadOperations") or []
    if not operations:
        raise AscApiError(
            "POST",
            "/v1/appScreenshots",
            status,
            payload,
            note="reservation for %s returned no uploadOperations" % path.name,
        )
    upload_bytes_to_operations(client, operations, data, path.name)
    commit = {
        "data": {
            "type": "appScreenshots",
            "id": screenshot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
        }
    }
    client.write(
        "PATCH", "/v1/appScreenshots/%s" % screenshot_id, commit, description="commit %s" % path.name
    )
    return screenshot_id


def command_screenshots(client: AscClient, args: argparse.Namespace) -> int:
    if not args.version:
        raise UsageError("screenshots needs --version, e.g. --version 1.1")
    locale_dirs = parse_locale_dirs(args.locale_dir or [])

    print("== screenshots %s ==" % args.version)
    versions = fetch_versions(client)
    version = find_version(versions, args.version)
    if not version:
        print(
            "ERROR: no iOS appStoreVersion %r on app %s." % (args.version, client.app_id),
            file=sys.stderr,
        )
        return EXIT_USAGE
    localizations = {((item.get("attributes") or {}).get("locale")): item for item in fetch_localizations(client, version["id"])}
    if not localizations:
        print(
            "ERROR: version %s has no localizations; create them (preflight/ASC UI) first."
            % args.version,
            file=sys.stderr,
        )
        return EXIT_USAGE

    print("  resolving screenshotDisplayType from existing App Store Connect data...")
    choice = resolve_display_type(client, version["id"], versions, override=args.display_type)
    print("  displayType: %s (%s)" % (choice.display_type, choice.source))

    plan, warnings = plan_screenshot_uploads(locale_dirs, choice.display_type)
    for warning in warnings:
        print("  WARNING: %s" % warning, file=sys.stderr)
    for locale_files in plan:
        missing = locale_files.locale not in localizations
        print(
            "  %-10s %d file(s)%s"
            % (locale_files.locale, len(locale_files.files), "  (NO LOCALIZATION -- skipped)" if missing else "")
        )
    if all(locale_files.locale not in localizations for locale_files in plan):
        print("ERROR: none of the --locale-dir locales exist on this version.", file=sys.stderr)
        return EXIT_USAGE

    for locale_files in plan:
        localization = localizations.get(locale_files.locale)
        if not localization:
            continue
        print("\n-- %s (%s) --" % (locale_files.locale, localization["id"]))
        set_id = ensure_screenshot_set(client, localization["id"], choice.display_type)
        if set_id is None:
            for index, path in enumerate(locale_files.files, 1):
                upload_one_screenshot(client, "<dry-set>", path)
            continue
        removed = clear_screenshot_set(client, set_id)
        print("  cleared %d old screenshot(s) from set %s" % (removed, set_id))
        for index, path in enumerate(locale_files.files, 1):
            print("  [%d/%d] %s" % (index, len(locale_files.files), path.name))
            upload_one_screenshot(client, set_id, path)

    if client.dry_run:
        print("\n[dry-run] no screenshots were uploaded.")
        return EXIT_OK

    print("\nwaiting for screenshot assets to reach COMPLETE...")
    if not wait_for_screenshot_assets(client, version["id"], timeout=args.wait_timeout):
        print("ERROR: screenshot assets did not finish processing.", file=sys.stderr)
        return EXIT_ASC_ERROR
    print("\nscreenshots: OK")
    return EXIT_OK


# ---------------------------------------------------------------------------
# whats-new file
# ---------------------------------------------------------------------------
LOCALE_TOKEN = r"[a-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*"
WHATS_NEW_HEADING_RE = re.compile(
    r"^\s*#{1,6}\s*(?:what'?s\s*new\s*[-–—:]?\s*)?\[?(" + LOCALE_TOKEN + r")\]?\s*$"
)
WHATS_NEW_INI_RE = re.compile(r"^\s*\[?(" + LOCALE_TOKEN + r")\]?\s*[:=]\s*(.*)$")


def parse_whats_new_text(text: str) -> Dict[str, str]:
    """Parse a tiny Markdown or INI file of per-locale release notes.

    Accepted shapes::

        ## en-US
        Fixed the picker scrim.

        ## zh-Hans
        优化相册选择器底部遮罩。

    or::

        en-US = Fixed the picker scrim.
        zh-Hans = 优化相册选择器底部遮罩。

    or::

        [en-US]
        Fixed the picker scrim.
    """
    sections: Dict[str, List[str]] = {}
    current: Optional[str] = None
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        heading = WHATS_NEW_HEADING_RE.match(stripped)
        if heading and (stripped.startswith("#") or stripped.startswith("[")):
            current = heading.group(1)
            sections.setdefault(current, [])
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped[1:-1].strip()
            sections.setdefault(current, [])
            continue
        inline = WHATS_NEW_INI_RE.match(stripped)
        if inline and not stripped.startswith("#") and (":" in stripped or "=" in stripped):
            locale = inline.group(1)
            value = inline.group(2).strip()
            sections.setdefault(locale, [])
            if value:
                sections[locale].append(value)
            current = locale
            continue
        if current is None:
            continue
        sections[current].append(raw_line.rstrip())

    result: Dict[str, str] = {}
    for locale, lines in sections.items():
        joined = "\n".join(line for line in lines).strip()
        if joined:
            result[locale] = joined
    return result


def load_whats_new(path_text: str) -> Dict[str, str]:
    path = Path(os.path.expanduser(path_text))
    if not path.is_file():
        raise UsageError("--whats-new-file not found: %s" % path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise UsageError("could not read --whats-new-file %s: %s" % (path, exc)) from exc
    parsed = parse_whats_new_text(text)
    if not parsed:
        raise UsageError(
            "--whats-new-file %s has no locale sections. Use '## en-US' headings or 'en-US = text'." % path
        )
    return parsed


def sync_whats_new(
    client: AscClient, version_id: str, whats_new: Dict[str, str]
) -> List[str]:
    """Create or update one localization per locale.  Returns a change log."""
    existing = {
        ((item.get("attributes") or {}).get("locale")): item
        for item in fetch_localizations(client, version_id)
    }
    changes: List[str] = []
    for locale, text in whats_new.items():
        localization = existing.get(locale)
        if localization:
            current = ((localization.get("attributes") or {}).get("whatsNew") or "").strip()
            if current == text.strip():
                changes.append("%s: whatsNew already current" % locale)
                continue
            body = {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": localization["id"],
                    "attributes": {"whatsNew": text},
                }
            }
            client.write(
                "PATCH",
                "/v1/appStoreVersionLocalizations/%s" % localization["id"],
                body,
                description="update whatsNew for %s" % locale,
            )
            changes.append("%s: PATCH whatsNew" % locale)
        else:
            body = {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": locale, "whatsNew": text},
                    "relationships": {
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
                    },
                }
            }
            client.write(
                "POST",
                "/v1/appStoreVersionLocalizations",
                body,
                description="create localization %s" % locale,
            )
            changes.append("%s: POST new localization with whatsNew" % locale)
    return changes


# ---------------------------------------------------------------------------
# submit
# ---------------------------------------------------------------------------
def attach_build(client: AscClient, version: dict, build: dict) -> str:
    """Point the version's build relationship at ``build`` (idempotent)."""
    try:
        current = (client.get("/v1/appStoreVersions/%s/build" % version["id"]) or {}).get("data")
    except AscApiError:
        current = None
    if current and current.get("id") == build["id"]:
        return "build %s already attached" % build["id"]
    body = {
        "data": {
            "type": "appStoreVersions",
            "id": version["id"],
            "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}},
        }
    }
    client.write(
        "PATCH", "/v1/appStoreVersions/%s" % version["id"], body, description="attach build %s" % build["id"]
    )
    return "attached build %s" % build["id"]


def command_submit(client: AscClient, args: argparse.Namespace) -> int:
    if not args.version:
        raise UsageError("submit needs --version, e.g. --version 1.1")

    print("== submit %s ==" % args.version)
    versions = fetch_versions(client)
    version = find_version(versions, args.version)
    if not version:
        print("ERROR: no iOS appStoreVersion %r on app %s." % (args.version, client.app_id), file=sys.stderr)
        return EXIT_USAGE
    print("  version id: %s" % version["id"])

    state = (version.get("attributes") or {}).get("appStoreState")
    if state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "READY_FOR_SALE"):
        print("  version is already %s; nothing to submit." % state)
        return EXIT_OK

    build: Optional[dict] = None
    if args.build:
        build = find_build(fetch_builds(client), args.build)
        if not build:
            print("ERROR: build %r not found on app %s." % (args.build, client.app_id), file=sys.stderr)
            return EXIT_USAGE
        if not is_build_ready(build):
            print(
                "ERROR: build %s is %s, not VALID; wait for processing before submitting."
                % (args.build, (build.get("attributes") or {}).get("processingState")),
                file=sys.stderr,
            )
            return EXIT_ASC_ERROR
        print("  " + attach_build(client, version, build))
    else:
        try:
            attached = (client.get("/v1/appStoreVersions/%s/build" % version["id"]) or {}).get("data")
        except AscApiError:
            attached = None
        if attached:
            build = attached
            print(
                "  build: %s (%s, already attached -- reusing it)"
                % (
                    build.get("id"),
                    (build.get("attributes") or {}).get("processingState") or "state unknown",
                )
            )
        else:
            print(
                "ERROR: submit needs --build: version %s has no build attached. "
                "Upload one (Xcode or altool) and pass --build, or attach it in "
                "App Store Connect first." % version["id"],
                file=sys.stderr,
            )
            return EXIT_USAGE

    if args.whats_new_file:
        whats_new = load_whats_new(args.whats_new_file)
        for change in sync_whats_new(client, version["id"], whats_new):
            print("  whatsNew: %s" % change)
    elif client.dry_run:
        print("  (no --whats-new-file; release notes are left as they are)")

    if not args.skip_preflight:
        print("\n-- preflight probe (required before submit) --")
        submission = ensure_open_submission(client, args)
        submission_id = submission.get("id")
        result = probe_submission_errors(client, version["id"], submission_id)
        if result.dry:
            print("  [dry-run] probe not sent, so prerequisites were NOT verified.")
        if not result.clean and not result.dry:
            print("  ASC rejected the item (HTTP %s). Associated errors:" % result.status)
            print("")
            print_probe_errors(result.errors)
            print(
                "\nREFUSING TO SUBMIT: %d associated error(s) remain. Run "
                "`asc_release.py preflight --version %s --fix`, fix what it cannot, then retry."
                % (len(result.errors), args.version),
                file=sys.stderr,
            )
            return EXIT_UNRESOLVED
        if result.clean:
            print("  CLEAN: no associated errors.")
    else:
        print("  WARNING: --skip-preflight given; submitting without the empty-submit probe.")
        submission = ensure_open_submission(client, args)
        submission_id = submission.get("id")

    item_errors = attach_submission_item(client, version["id"], submission_id)
    if item_errors:
        print("  ASC refused the version item (HTTP 409). Associated errors:", file=sys.stderr)
        print("")
        print_probe_errors(item_errors)
        print(
            "\nREFUSING TO SUBMIT: review submission %s would not contain version %s. "
            "Fix the errors above and retry." % (submission_id, args.version),
            file=sys.stderr,
        )
        return EXIT_UNRESOLVED

    print("\n-- submitting reviewSubmission %s --" % submission_id)
    body = {"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}}
    status, payload = client.write(
        "PATCH",
        "/v1/reviewSubmissions/%s" % submission_id,
        body,
        description="submit for review",
        allow_status=(409,),
    )
    if status == 0:
        print("[dry-run] would now be WAITING_FOR_REVIEW")
        return EXIT_OK
    if status == 409:
        errors = dedupe_errors(flatten_associated_errors(payload))
        print("  submit rejected (409). Associated errors:", file=sys.stderr)
        print_probe_errors(errors)
        return EXIT_UNRESOLVED
    attributes = (payload.get("data") or {}).get("attributes") or {}
    print(
        "  SUBMITTED %s state=%s submittedDate=%s"
        % (submission_id, attributes.get("state"), attributes.get("submittedDate"))
    )
    return EXIT_OK


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    # Shared flags live on a parent parser so they work both before and after
    # the subcommand: `asc_release.py --version 1.1 probe` and
    # `asc_release.py probe --version 1.1` are equivalent.
    shared = argparse.ArgumentParser(add_help=False)
    # default=SUPPRESS everywhere: a subparser copies its own defaults over the
    # namespace the parent already filled, which would silently discard a flag
    # given before the subcommand.  normalize_args() supplies the real defaults.
    shared.add_argument("--app-id", default=argparse.SUPPRESS,
                        help="ASC app id (default: $ASC_APP_ID, else ClipDock's %s)" % DEFAULT_APP_ID)
    shared.add_argument("--issuer", default=argparse.SUPPRESS, help="issuer id (default: $ASC_ISSUER_ID)")
    shared.add_argument("--key-id", default=argparse.SUPPRESS, help="API key id (default: $ASC_KEY_ID)")
    shared.add_argument("--key-path", default=argparse.SUPPRESS,
                        help="path to the .p8 key (default: $ASC_KEY_PATH)")
    shared.add_argument("--version", default=argparse.SUPPRESS,
                        help="marketing version to act on, e.g. 1.1")
    shared.add_argument("--build", default=argparse.SUPPRESS,
                        help="build number (CFBundleVersion), e.g. 12")
    shared.add_argument("--locale-dir", action="append", default=argparse.SUPPRESS,
                        metavar="LOCALE=PATH",
                        help="screenshots: locale directory, repeatable, e.g. --locale-dir en-US=./out/en")
    shared.add_argument("--display-type", default=argparse.SUPPRESS,
                        help="override screenshotDisplayType instead of reusing an existing one")
    shared.add_argument("--whats-new-file", default=argparse.SUPPRESS, metavar="PATH",
                        help="per-locale release notes (## en-US headings or en-US = text)")
    shared.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS,
                        help="print exact HTTP method/path/redacted body; make no writes")
    shared.add_argument("--verbose", action="store_true", default=argparse.SUPPRESS,
                        help="log API calls with tokens redacted")

    parser = argparse.ArgumentParser(
        prog="asc_release.py",
        parents=[shared],
        description=(
            "App Store Connect release helper for ClipDock. Stdlib only. "
            "Reuses the screenshotDisplayType that already exists and probes submit "
            "prerequisites with an empty submission before touching the real submit."
        ),
        epilog=(
            "Credentials come from flags or the environment:\n"
            "  ASC_ISSUER_ID, ASC_KEY_ID, ASC_KEY_PATH, ASC_APP_ID\n"
            "Never put the key id, issuer id or key itself in the repository.\n"
            "The Sales and Trends key (AuthKey_7XL5564K84.p8) cannot read /v1/builds;\n"
            "use the App Manager key (AuthKey_YYK7P6W893.p8).\n"
            "Run `probe` first; every mutating subcommand accepts --dry-run."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    subparsers = parser.add_subparsers(dest="command", metavar="COMMAND")

    probe = subparsers.add_parser(
        "probe", parents=[shared], help="read-only snapshot of app, versions, builds, submissions"
    )
    probe.set_defaults(handler=command_probe)

    preflight = subparsers.add_parser(
        "preflight",
        parents=[shared],
        help="empty-submit probe: print every associated error, optionally fix and re-probe",
    )
    preflight.add_argument("--fix", action="store_true",
                           help="apply the two known-safe fixes and wait for screenshot assets")
    preflight.add_argument("--max-probes", type=int, default=3,
                           help="how many times to probe when --fix is used (default 3)")
    preflight.add_argument("--probe-interval", type=float, default=10.0,
                           help="seconds between probes (default 10)")
    preflight.add_argument("--wait-timeout", type=float, default=900.0,
                           help="seconds to wait for screenshot assets (default 900)")
    preflight.add_argument("--submission-id", default=None,
                           help="probe an existing review submission instead of making one")
    preflight.set_defaults(handler=command_preflight)

    screenshots = subparsers.add_parser(
        "screenshots",
        parents=[shared],
        help="upload screenshots, reusing the displayType that already exists",
    )
    screenshots.add_argument("--wait-timeout", type=float, default=1800.0,
                             help="seconds to wait for assets to reach COMPLETE (default 1800)")
    screenshots.set_defaults(handler=command_screenshots)

    submit = subparsers.add_parser(
        "submit",
        parents=[shared],
        help="attach the build and submit for review (refuses unless preflight is clean)",
    )
    submit.add_argument("--skip-preflight", action="store_true",
                        help="do not run the empty-submit probe (not recommended)")
    submit.add_argument("--submission-id", default=None,
                        help="submit a specific existing review submission")
    submit.set_defaults(handler=command_submit)
    return parser


COMMANDS_NEEDING_AUTH = ("probe", "preflight", "screenshots", "submit")


def build_client(args: argparse.Namespace) -> AscClient:
    credentials = resolve_credentials(args.issuer, args.key_id, args.key_path)
    return AscClient(
        credentials,
        app_id=args.app_id,
        dry_run=args.dry_run,
        verbose=args.verbose,
    )


def normalize_args(args: argparse.Namespace) -> argparse.Namespace:
    """Fill in every shared-flag default (they are declared with SUPPRESS)."""
    defaults = {
        "app_id": os.environ.get("ASC_APP_ID") or DEFAULT_APP_ID,
        "issuer": None,
        "key_id": None,
        "key_path": None,
        "version": None,
        "build": None,
        "locale_dir": [],
        "display_type": None,
        "whats_new_file": None,
        "dry_run": False,
        "verbose": False,
    }
    for name, value in defaults.items():
        if not hasattr(args, name) or getattr(args, name) is None:
            setattr(args, name, value if not isinstance(value, list) else [])
    args.locale_dir = list(args.locale_dir or [])
    args.dry_run = bool(args.dry_run)
    args.verbose = bool(args.verbose)
    return args


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = normalize_args(parser.parse_args(argv))
    if not getattr(args, "handler", None):
        parser.print_help()
        return EXIT_USAGE
    if args.dry_run:
        print("[dry-run] no writes will be made; only GET requests are sent")
    try:
        client = build_client(args)
        return int(args.handler(client, args) or EXIT_OK)
    except CredentialError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return EXIT_USAGE
    except UsageError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return EXIT_USAGE
    except AscApiError as exc:
        print("ERROR: %s" % redact_token(str(exc)), file=sys.stderr)
        return exc.exit_code
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return EXIT_INTERRUPTED


if __name__ == "__main__":
    sys.exit(main())
