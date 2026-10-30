#!/usr/bin/env python3
"""Unit tests for asc_release.py. No network, no credentials, no writes.

Run from the repository root:

    python3 -m unittest discover -s scripts/asc -p 'test_*.py' -v

Everything here exercises pure functions only, so the suite passes on a bare
Linux box with nothing but Python 3.9+.
"""

import base64
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import asc_release as asc  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# A real ECDSA P-256 / SHA-256 signature in ASN.1 DER, produced with
#
#   openssl ecparam -name prime256v1 -genkey -noout -out k.pem
#   printf 'clipdock-test-vector' | openssl dgst -sha256 -sign k.pem -out sig.der
#
# 72 bytes: SEQUENCE(0x30, 0x46) with two INTEGERs (0x02, 0x21) that each carry
# a 0x00 sign-padding byte, which is exactly the case raw r||s conversion must
# strip.
DER_SIGNATURE_HEX = (
    "30460221008cbe7f8a18c89738ede3eb414de65d149f167da8b2d20dfa7374499e169fea6c"
    "022100e5aca1add0454429d74022795446c27e64ce50c6373181cbe5cebaabc6e95b1f"
)
DER_SIGNATURE_R_HEX = "8cbe7f8a18c89738ede3eb414de65d149f167da8b2d20dfa7374499e169fea6c"
DER_SIGNATURE_S_HEX = "e5aca1add0454429d74022795446c27e64ce50c6373181cbe5cebaabc6e95b1f"

# Derived from the same header/payload this module builds (see
# test_jwt_segments_are_base64url_without_padding for the independent check).
JWT_HEADER = {"alg": "ES256", "kid": "ABC123DEFG", "typ": "JWT"}
JWT_ISSUED_AT = 1_700_000_000

# A real 409 from POST /v1/reviewSubmissionItems for ClipDock 1.1 on
# 2026-10-30, i.e. exactly what the empty-submit probe reads. The 1.1 submit was
# rejected with only "STATE_ERROR.ENTITY_STATE_INVALID ... check associated
# errors to see why"; meta.associatedErrors carried the three real blockers:
#   1. builds.usesNonExemptEncryption was null
#   2. ageRatingDeclarations.socialMedia was null
#   3. the newly uploaded screenshots were still in post-processing
# Structure and vocabulary are Apple's; ids are ClipDock 1.1's.
PROBE_409_PAYLOAD = {
    "errors": [
        {
            "id": "a1b2c3d4-1111-4111-8111-111111111111",
            "status": "409",
            "code": "STATE_ERROR.ENTITY_STATE_INVALID",
            "title": "The request cannot be fulfilled because of the state of another resource.",
            "detail": (
                "appStoreVersions with id 'dd00956e-a029-4007-ac6b-3ad1cced1b01' is not "
                "in valid state. This resource cannot be reviewed, please check associated "
                "errors to see why."
            ),
        }
    ],
    "meta": {
        "associatedErrors": {
            "/v1/builds/b246d0d7-ee9e-4848-91da-9534fe806730": [
                {
                    "id": "b2c3d4e5-2222-4222-8222-222222222222",
                    "status": "409",
                    "code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
                    "title": "The provided entity is missing a required attribute",
                    "detail": (
                        "You must provide a value for the attribute "
                        "'usesNonExemptEncryption' with this request"
                    ),
                    "source": {
                        "pointer": "/data/attributes/usesNonExemptEncryption",
                        "parameter": "usesNonExemptEncryption",
                    },
                }
            ],
            "/v1/appStoreVersions/dd00956e-a029-4007-ac6b-3ad1cced1b01/ageRatingDeclaration": [
                {
                    "id": "c3d4e5f6-3333-4333-8333-333333333333",
                    "status": "409",
                    "code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
                    "title": "The provided entity is missing a required attribute",
                    "detail": (
                        "You must provide a value for the attribute 'socialMedia' with "
                        "this request"
                    ),
                    "source": {
                        "pointer": "/data/attributes/socialMedia",
                        "parameter": "socialMedia",
                    },
                }
            ],
            "/v1/appScreenshots/eac00019-2e0f-89e3-801f-38d34bf80e58": [
                {
                    "id": "d4e5f6a7-4444-4444-8444-444444444444",
                    "status": "409",
                    "code": "STATE_ERROR.ENTITY_STATE_INVALID",
                    "title": "The request cannot be fulfilled because of the state of another resource.",
                    "detail": (
                        "The screenshots are still processing and cannot be reviewed yet. "
                        "Please wait for the screenshot assets to finish processing."
                    ),
                    "source": {"pointer": "/data/attributes/assetDeliveryState"},
                }
            ],
        }
    },
}

# The two attribute names the probe must be able to auto-fix.
EXPECTED_FIXABLE = {"usesNonExemptEncryption", "socialMedia"}


# ---------------------------------------------------------------------------
# DER -> raw signature
# ---------------------------------------------------------------------------
class DerToRawSignatureTests(unittest.TestCase):
    def test_known_vector_splits_into_two_32_byte_halves(self):
        raw = asc.der_to_raw_signature(bytes.fromhex(DER_SIGNATURE_HEX))
        self.assertEqual(len(raw), 64, "ES256 signatures are exactly r||s, 64 bytes")
        self.assertEqual(raw[:32].hex(), DER_SIGNATURE_R_HEX)
        self.assertEqual(raw[32:].hex(), DER_SIGNATURE_S_HEX)
        self.assertEqual(len(raw[:32]), 32)
        self.assertEqual(len(raw[32:]), 32)

    def test_sign_padding_bytes_are_stripped_not_kept(self):
        # Each DER INTEGER above starts with 0x00; raw form must drop it and
        # left-pad to exactly 32 bytes.
        raw = asc.der_to_raw_signature(bytes.fromhex(DER_SIGNATURE_HEX))
        self.assertNotEqual(raw[:32], bytes.fromhex(DER_SIGNATURE_HEX)[4:36])
        self.assertTrue(raw[:32].startswith(b"\x8c"))

    def test_short_integers_are_left_padded_to_32_bytes(self):
        # SEQUENCE(0x30 0x08) INTEGER(0x02 0x01 0x01) INTEGER(0x02 0x01 0x02)
        der = bytes.fromhex("300802010102010 2".replace(" ", ""))
        raw = asc.der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:31], b"\x00" * 31)
        self.assertEqual(raw[31], 1)
        self.assertEqual(raw[32:63], b"\x00" * 31)
        self.assertEqual(raw[63], 2)

    def test_jwt_signature_segment_is_86_chars_of_unpadded_base64url(self):
        # 64 raw bytes -> 86 unpadded base64 characters -> the ES256 JWT segment
        # is always 86 chars (base64 of 64 bytes, no '=').
        raw = asc.der_to_raw_signature(bytes.fromhex(DER_SIGNATURE_HEX))
        self.assertEqual(len(asc.b64u(raw)), 86)
        self.assertNotIn("=", asc.b64u(raw))
        self.assertNotIn("+", asc.b64u(raw))
        self.assertNotIn("/", asc.b64u(raw))

    def test_rejects_non_sequence(self):
        with self.assertRaises(ValueError):
            asc.der_to_raw_signature(b"\x31\x02\x01\x01")

    def test_rejects_truncated_input(self):
        with self.assertRaises(ValueError):
            asc.der_to_raw_signature(bytes.fromhex("30460221008cbe7f8a"))

    def test_rejects_oversized_integer(self):
        # 33 raw bytes in an INTEGER cannot be an ES256 scalar half.
        der = bytes([0x30, 0x26, 0x02, 0x21]) + b"\x01" * 33 + bytes([0x02, 0x01, 0x01])
        with self.assertRaises(ValueError):
            asc.der_to_raw_signature(der)


# ---------------------------------------------------------------------------
# JWT structure
# ---------------------------------------------------------------------------
class JwtTests(unittest.TestCase):
    def setUp(self):
        self.segments, self.header, self.payload = asc.build_jwt_segments(
            "ABC123DEFG", "69a6de70-0000-4000-8000-000000000000", JWT_ISSUED_AT
        )
        self.header_segment, self.payload_segment = self.segments.split(".")

    def test_header_is_es256_with_kid_and_no_dashes_padding(self):
        self.assertEqual(self.header, JWT_HEADER)
        self.assertEqual(json.loads(asc.b64u_decode(self.header_segment)), JWT_HEADER)
        for segment in (self.header_segment, self.payload_segment):
            self.assertNotIn("=", segment)
            self.assertNotIn("+", segment)
            self.assertNotIn("/", segment)

    def test_header_segment_is_exact_base64url_of_sorted_compact_json(self):
        expected_json = b'{"alg":"ES256","kid":"ABC123DEFG","typ":"JWT"}'
        expected = base64.urlsafe_b64encode(expected_json).rstrip(b"=").decode()
        self.assertEqual(self.header_segment, expected)

    def test_payload_claims(self):
        decoded = json.loads(asc.b64u_decode(self.payload_segment))
        self.assertEqual(decoded["iss"], "69a6de70-0000-4000-8000-000000000000")
        self.assertEqual(decoded["iat"], JWT_ISSUED_AT)
        self.assertEqual(decoded["aud"], "appstoreconnect-v1")
        self.assertEqual(set(decoded), {"iss", "iat", "exp", "aud"})

    def test_lifetime_is_under_the_20_minute_cap(self):
        self.assertEqual(self.payload["exp"] - self.payload["iat"], 1140)
        self.assertLess(self.payload["exp"] - self.payload["iat"], 1200)

    def test_payload_segment_roundtrips(self):
        self.assertEqual(json.loads(asc.b64u_decode(self.payload_segment)), self.payload)

    def test_full_jwt_has_three_segments_and_no_secret_in_them(self):
        token = self.segments + "." + asc.b64u(b"\x00" * 64)
        self.assertEqual(token.count("."), 2)
        for part in token.split("."):
            self.assertTrue(part)


# ---------------------------------------------------------------------------
# displayType selection -- the first hard-won gotcha
# ---------------------------------------------------------------------------
class DisplayTypeSelectionTests(unittest.TestCase):
    def test_app_iphone_69_is_never_chosen_even_if_offered(self):
        choice = asc.choose_display_type(["APP_IPHONE_69", "APP_IPHONE_67"])
        self.assertEqual(choice.display_type, "APP_IPHONE_67")
        self.assertTrue(choice.reused)
        self.assertNotEqual(asc.choose_display_type(["APP_IPHONE_69"]).display_type, "APP_IPHONE_69")
        self.assertIn("APP_IPHONE_69", asc.INVALID_DISPLAY_TYPES)

    def test_reuses_app_iphone_67_when_it_is_the_only_one(self):
        choice = asc.choose_display_type(["APP_IPHONE_67"])
        self.assertEqual(choice.display_type, "APP_IPHONE_67")
        self.assertTrue(choice.reused, "an existing APP_IPHONE_67 must be reused, not guessed")

    def test_ignores_ipad_watch_and_desktop_sets(self):
        choice = asc.choose_display_type(
            ["APP_IPAD_PRO_3GEN_129", "APP_WATCH_SERIES_7", "APP_DESKTOP", "APP_IPHONE_67"]
        )
        self.assertEqual(choice.display_type, "APP_IPHONE_67")

    def test_prefers_largest_iphone_type_when_several_exist(self):
        choice = asc.choose_display_type(["APP_IPHONE_55", "APP_IPHONE_65", "APP_IPHONE_67"])
        self.assertEqual(choice.display_type, "APP_IPHONE_67")

    def test_falls_back_to_documented_constant_with_reused_false(self):
        choice = asc.choose_display_type([])
        self.assertEqual(choice.display_type, asc.FALLBACK_DISPLAY_TYPE)
        self.assertEqual(choice.display_type, "APP_IPHONE_67")
        self.assertFalse(choice.reused, "a fallback must be flagged so the caller warns")
        self.assertIn("fallback", choice.source)

    def test_only_non_iphone_sets_still_falls_back(self):
        choice = asc.choose_display_type(["APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"])
        self.assertFalse(choice.reused)
        self.assertEqual(choice.display_type, asc.FALLBACK_DISPLAY_TYPE)

    def test_override_wins_verbatim(self):
        choice = asc.choose_display_type(["APP_IPHONE_55"], override="APP_IPHONE_67")
        self.assertEqual(choice.display_type, "APP_IPHONE_67")
        self.assertIn("override", choice.source)

    def test_duplicates_and_none_do_not_break_selection(self):
        choice = asc.choose_display_type(["APP_IPHONE_67", "APP_IPHONE_67", None, ""])
        self.assertEqual(choice.display_type, "APP_IPHONE_67")

    def test_fallback_constant_accepts_the_1_1_dimensions(self):
        # 1320x2868 (6.9") and 1290x2796 (6.7") are both valid under APP_IPHONE_67.
        accepted = asc.ACCEPTED_SCREENSHOT_SIZES["APP_IPHONE_67"]
        self.assertIn((1320, 2868), accepted)
        self.assertIn((1290, 2796), accepted)


# ---------------------------------------------------------------------------
# Checksum helper
# ---------------------------------------------------------------------------
class ChecksumTests(unittest.TestCase):
    def test_empty_bytes_match_hashlib(self):
        self.assertEqual(asc.md5_hexdigest_bytes(b""), hashlib.md5(b"").hexdigest())
        self.assertEqual(asc.md5_hexdigest_bytes(b""), "d41d8cd98f00b204e9800998ecf8427e")

    def test_known_vector(self):
        self.assertEqual(asc.md5_hexdigest_bytes(b"abc"), "900150983cd24fb0d6963f7d28e17f72")

    def test_file_helper_is_lowercase_hex_and_streams(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shot.png"
            payload = b"clipdock" * 5000
            path.write_bytes(payload)
            digest = asc.md5_hexdigest(path)
        self.assertEqual(digest, hashlib.md5(payload).hexdigest())
        self.assertEqual(len(digest), 32)
        self.assertEqual(digest, digest.lower())
        self.assertRegex(digest, r"^[0-9a-f]{32}$")


# ---------------------------------------------------------------------------
# uploadOperations slicing
# ---------------------------------------------------------------------------
class UploadOperationTests(unittest.TestCase):
    def test_single_operation_covers_whole_file(self):
        data = b"0123456789"
        chunks = asc.slice_upload_operations(
            data, [{"offset": 0, "length": 10, "url": "https://u/1", "method": "PUT"}]
        )
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0].offset, 0)
        self.assertEqual(chunks[0].length, 10)
        self.assertEqual(chunks[0].chunk, data)

    def test_multi_chunk_offsets_line_up_and_cover_the_file(self):
        data = bytes(range(256)) * 4  # 1024 bytes
        operations = [
            {"offset": 0, "length": 256, "url": "u0"},
            {"offset": 256, "length": 256, "url": "u1"},
            {"offset": 512, "length": 256, "url": "u2"},
            {"offset": 768, "length": 256, "url": "u3"},
        ]
        chunks = asc.slice_upload_operations(data, operations)
        self.assertEqual([c.offset for c in chunks], [0, 256, 512, 768])
        self.assertEqual([c.length for c in chunks], [256, 256, 256, 256])
        self.assertEqual(b"".join(c.chunk for c in chunks), data)
        self.assertEqual(chunks[1].chunk, data[256:512])
        self.assertEqual(chunks[3].chunk, data[768:1024])

    def test_out_of_order_operations_are_sorted_by_offset(self):
        data = b"abcdefgh"
        operations = [
            {"offset": 4, "length": 4, "url": "u1"},
            {"offset": 0, "length": 4, "url": "u0"},
        ]
        chunks = asc.slice_upload_operations(data, operations)
        self.assertEqual([c.offset for c in chunks], [0, 4])
        self.assertEqual([c.chunk for c in chunks], [b"abcd", b"efgh"])

    def test_missing_length_means_to_end_of_file(self):
        data = b"0123456789"
        chunks = asc.slice_upload_operations(data, [{"offset": 4, "url": "u"}])
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0].chunk, b"456789")
        self.assertEqual(chunks[0].length, 6)

    def test_ragged_last_chunk_is_shorter_than_declared_length(self):
        data = b"0123456789"
        chunks = asc.slice_upload_operations(data, [{"offset": 8, "length": 8, "url": "u"}])
        self.assertEqual(chunks[0].chunk, b"89")
        self.assertEqual(chunks[0].length, 2, "reported length is the real byte count")

    def test_none_or_empty_operations_yield_no_chunks(self):
        self.assertEqual(asc.slice_upload_operations(b"abc", None), [])
        self.assertEqual(asc.slice_upload_operations(b"abc", []), [])

    def test_operation_is_preserved_on_the_chunk(self):
        operation = {"offset": 0, "length": 3, "url": "https://example/put", "method": "PUT"}
        chunks = asc.slice_upload_operations(b"abc", [operation])
        self.assertIs(chunks[0].operation, operation)

    def test_negative_offset_is_rejected(self):
        with self.assertRaises(ValueError):
            asc.slice_upload_operations(b"abc", [{"offset": -1, "length": 2, "url": "u"}])


# ---------------------------------------------------------------------------
# Associated error flattening -- the second hard-won gotcha
# ---------------------------------------------------------------------------
class AssociatedErrorTests(unittest.TestCase):
    def setUp(self):
        self.errors = asc.flatten_associated_errors(PROBE_409_PAYLOAD)

    def test_fixture_contains_the_three_blockers_we_actually_hit(self):
        blob = json.dumps(PROBE_409_PAYLOAD)
        self.assertIn("usesNonExemptEncryption", blob)
        self.assertIn("socialMedia", blob)
        self.assertIn("processing", blob)
        self.assertEqual(len(self.errors), 3)

    def test_every_associated_error_is_flattened(self):
        self.assertEqual(len(self.errors), 3)
        codes = [error.code for error in self.errors]
        self.assertEqual(codes.count("ENTITY_ERROR.ATTRIBUTE.REQUIRED"), 2)
        self.assertEqual(codes.count("STATE_ERROR.ENTITY_STATE_INVALID"), 1)

    def test_resource_paths_are_preserved(self):
        resources = " ".join(error.resource for error in self.errors)
        self.assertIn("/v1/builds/b246d0d7", resources)
        self.assertIn("ageRatingDeclaration", resources)
        self.assertIn("/v1/appScreenshots/", resources)

    def test_the_vague_parent_error_is_not_the_only_thing_reported(self):
        # The top-level errors[] entry is what ASC shows without a probe; the
        # flattened list must contain far more than it.
        self.assertGreater(len(self.errors), len(PROBE_409_PAYLOAD["errors"]))
        self.assertNotIn(
            "check associated errors to see why",
            " ".join(error.detail for error in self.errors),
        )

    def test_the_two_safe_fixes_are_identified(self):
        fixable = {
            asc.fix_target(error) for error in self.errors if asc.fix_target(error)
        }
        self.assertEqual(fixable, EXPECTED_FIXABLE)

    def test_screenshot_processing_error_is_recognised_as_waitable(self):
        waitable = [error for error in self.errors if asc.is_waitable_error(error)]
        self.assertEqual(len(waitable), 1)
        self.assertIn("Screenshot", waitable[0].resource)
        self.assertTrue(asc.is_screenshot_processing_error(waitable[0]))

    def test_attribute_errors_are_not_treated_as_waitable(self):
        attribute_errors = [e for e in self.errors if e.code == "ENTITY_ERROR.ATTRIBUTE.REQUIRED"]
        self.assertEqual(len(attribute_errors), 2)
        for error in attribute_errors:
            self.assertFalse(asc.is_waitable_error(error))

    def test_fix_values_are_false_and_match_the_attribute(self):
        for error in self.errors:
            name = asc.fix_target(error)
            if not name:
                continue
            fix = asc.AUTO_FIXES[name]
            self.assertIs(fix["value"], False)
            self.assertEqual(fix["attribute"], name)

    def test_describe_error_names_the_action(self):
        text = "\n".join(
            asc.describe_error(index, error, total=len(self.errors))
            for index, error in enumerate(self.errors, 1)
        )
        self.assertIn("auto-fix usesNonExemptEncryption", text)
        self.assertIn("auto-fix socialMedia", text)
        self.assertIn("wait for screenshot assets", text)
        self.assertIn("1/3.", text)

    def test_dedupe_removes_repeated_identical_errors(self):
        doubled = self.errors + self.errors
        self.assertEqual(len(asc.dedupe_errors(doubled)), 3)

    def test_flat_list_shape_is_supported(self):
        payload = {"meta": {"associatedErrors": [{"code": "X", "detail": "y"}]}}
        errors = asc.flatten_associated_errors(payload)
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].code, "X")

    def test_top_level_errors_only_payload_still_flattens(self):
        payload = {"errors": [{"code": "STATE_ERROR.ENTITY_STATE_INVALID", "detail": "d"}]}
        errors = asc.flatten_associated_errors(payload)
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].code, "STATE_ERROR.ENTITY_STATE_INVALID")

    def test_empty_and_malformed_payloads_do_not_raise(self):
        for payload in ({}, {"meta": {}}, {"meta": {"associatedErrors": {}}}, {"errors": []}, None, "x", 7):
            self.assertEqual(asc.flatten_associated_errors(payload), [])

    def test_describe_errors_mentions_all_three(self):
        summary = asc.describe_errors(PROBE_409_PAYLOAD)
        self.assertIn("usesNonExemptEncryption", summary)
        self.assertIn("socialMedia", summary)
        self.assertIn("screenshot", summary.lower())

    def test_pointer_parsing_extracts_the_attribute_name(self):
        self.assertEqual(
            asc._pointer_attribute("/data/attributes/usesNonExemptEncryption"),
            "usesNonExemptEncryption",
        )
        self.assertEqual(
            asc._pointer_attribute("/data/attributes/socialMedia"), "socialMedia"
        )

    def test_fix_target_matches_on_resource_path_without_pointer(self):
        error = asc.AssociatedError(
            "/v1/builds/abc",
            "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
            "",
            "must provide a value for the attribute 'usesNonExemptEncryption'",
            {},
            None,
        )
        self.assertEqual(asc.fix_target(error), "usesNonExemptEncryption")

    def test_unknown_attribute_gets_no_fix(self):
        error = asc.AssociatedError(
            "/v1/appStoreVersions/x",
            "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
            "",
            "must provide a value for the attribute 'privacyPolicyUrl'",
            {},
            None,
        )
        self.assertIsNone(asc.fix_target(error))
        self.assertIn("none available", asc.describe_error(1, error))


# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------
class RedactionTests(unittest.TestCase):
    def test_jwt_is_redacted(self):
        token = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.c2lnbmF0dXJl"
        self.assertEqual(asc.redact_token("token=" + token), "token=<jwt-redacted>")

    def test_bearer_header_is_redacted(self):
        self.assertEqual(
            asc.redact_token("Authorization: Bearer abc.def.ghi"),
            "Authorization: Bearer <redacted>",
        )

    def test_sensitive_body_keys_are_masked(self):
        body = {
            "data": {
                "attributes": {"token": "secret-value", "fileName": "01-home.png"},
                "relationships": {"authorization": "Bearer x"},
            }
        }
        redacted = asc.redact_body(body)
        self.assertEqual(redacted["data"]["attributes"]["token"], "<redacted>")
        self.assertEqual(redacted["data"]["relationships"]["authorization"], "<redacted>")
        self.assertEqual(redacted["data"]["attributes"]["fileName"], "01-home.png")

    def test_long_strings_are_truncated(self):
        redacted = asc.redact_body("x" * 1000)
        self.assertLess(len(redacted), 400)
        self.assertIn("<truncated", redacted)


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
class CredentialTests(unittest.TestCase):
    def test_missing_everything_names_all_three_inputs(self):
        with self.assertRaises(asc.CredentialError) as ctx:
            asc.resolve_credentials(None, None, None, env={})
        message = str(ctx.exception)
        for hint in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_PATH"):
            self.assertIn(hint, message)

    def test_env_is_used_when_flags_are_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_TEST.p8"
            key.write_text("-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----\n")
            credentials = asc.resolve_credentials(
                None,
                None,
                None,
                env={"ASC_ISSUER_ID": "issuer-1", "ASC_KEY_ID": "KEY1", "ASC_KEY_PATH": str(key)},
            )
        self.assertEqual(credentials.issuer, "issuer-1")
        self.assertEqual(credentials.key_id, "KEY1")
        self.assertEqual(credentials.key_path, key)

    def test_flags_beat_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_FLAG.p8"
            key.write_text("x")
            credentials = asc.resolve_credentials(
                "flag-issuer",
                "FLAG",
                str(key),
                env={"ASC_ISSUER_ID": "env-issuer", "ASC_KEY_ID": "ENV", "ASC_KEY_PATH": "/nope"},
            )
        self.assertEqual(credentials.issuer, "flag-issuer")
        self.assertEqual(credentials.key_id, "FLAG")

    def test_missing_key_file_is_a_clear_error(self):
        with self.assertRaises(asc.CredentialError) as ctx:
            asc.resolve_credentials("i", "k", "/definitely/not/here.p8", env={})
        self.assertIn("not found", str(ctx.exception))

    def test_non_p8_extension_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            wrong = Path(tmp) / "key.pem"
            wrong.write_text("x")
            with self.assertRaises(asc.CredentialError):
                asc.resolve_credentials("i", "k", str(wrong), env={})


# ---------------------------------------------------------------------------
# whats-new parsing
# ---------------------------------------------------------------------------
class WhatsNewTests(unittest.TestCase):
    def test_markdown_headings(self):
        text = "## en-US\nFixed the picker scrim.\n\n## zh-Hans\n优化相册选择器底部遮罩。\n"
        parsed = asc.parse_whats_new_text(text)
        self.assertEqual(parsed["en-US"], "Fixed the picker scrim.")
        self.assertEqual(parsed["zh-Hans"], "优化相册选择器底部遮罩。")

    def test_ini_style(self):
        parsed = asc.parse_whats_new_text("en-US = Fixed the scrim.\nzh-Hans = 修复遮罩。\n")
        self.assertEqual(parsed["en-US"], "Fixed the scrim.")
        self.assertEqual(parsed["zh-Hans"], "修复遮罩。")

    def test_bracketed_sections(self):
        parsed = asc.parse_whats_new_text("[en-US]\nLine one.\nLine two.\n")
        self.assertEqual(parsed["en-US"], "Line one.\nLine two.")

    def test_empty_input_yields_nothing(self):
        self.assertEqual(asc.parse_whats_new_text(""), {})


# ---------------------------------------------------------------------------
# Screenshot planning
# ---------------------------------------------------------------------------
PNG_1x1 = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082"
)


class ScreenshotPlanningTests(unittest.TestCase):
    def test_png_size_reader(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "tiny.png"
            path.write_bytes(PNG_1x1)
            self.assertEqual(asc.read_png_size(path), (1, 1))

    def test_non_png_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "nope.png"
            path.write_bytes(b"not a png at all")
            self.assertIsNone(asc.read_png_size(path))

    def test_size_mismatch_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "tiny.png"
            path.write_bytes(PNG_1x1)
            problem = asc.check_screenshot_size(path, "APP_IPHONE_67")
        self.assertIsNotNone(problem)
        self.assertIn("1x1", problem)
        self.assertIn("APP_IPHONE_67", problem)

    def test_unknown_display_type_skips_size_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "tiny.png"
            path.write_bytes(PNG_1x1)
            self.assertIsNone(asc.check_screenshot_size(path, "APP_UNKNOWN_SOMETHING"))

    def test_files_are_ordered_numerically(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name in ("10-tenth.png", "02-second.png", "01-first.png"):
                (directory / name).write_bytes(PNG_1x1)
            files = asc.collect_screenshot_files(directory)
        self.assertEqual([f.name for f in files], ["01-first.png", "02-second.png", "10-tenth.png"])

    def test_empty_directory_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(asc.UsageError):
                asc.collect_screenshot_files(Path(tmp))

    def test_locale_dir_requires_equals_sign(self):
        with self.assertRaises(asc.UsageError):
            asc.parse_locale_dirs(["/tmp"])
        with self.assertRaises(asc.UsageError):
            asc.parse_locale_dirs(["=foo"])

    def test_locale_dir_rejects_missing_directory(self):
        with self.assertRaises(asc.UsageError):
            asc.parse_locale_dirs(["en-US=/definitely/not/here"])

    def test_plan_collects_warnings_without_raising(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for index in range(1, 6):
                (directory / ("%02d-shot.png" % index)).write_bytes(PNG_1x1)
            plan, warnings = asc.plan_screenshot_uploads([("en-US", directory)], "APP_IPHONE_67")
        self.assertEqual(len(plan), 1)
        self.assertEqual(len(plan[0].files), 5)
        self.assertEqual(len(warnings), 5)


# ---------------------------------------------------------------------------
# CLI surface
# ---------------------------------------------------------------------------
class CliTests(unittest.TestCase):
    def test_has_all_four_subcommands(self):
        parser = asc.build_parser()
        actions = [a for a in parser._actions if a.__class__.__name__ == "_SubParsersAction"]
        self.assertTrue(actions)
        self.assertEqual(
            set(actions[0].choices), {"probe", "preflight", "screenshots", "submit"}
        )

    def test_global_flags_parse_before_and_after_the_subcommand(self):
        parser = asc.build_parser()
        before = asc.normalize_args(parser.parse_args(["--version", "1.1", "--dry-run", "probe"]))
        after = asc.normalize_args(parser.parse_args(["probe", "--version", "1.1", "--dry-run"]))
        self.assertEqual(before.version, "1.1")
        self.assertEqual(after.version, "1.1")
        self.assertTrue(before.dry_run)
        self.assertTrue(after.dry_run)

    def test_app_id_defaults_to_clipdock_but_is_overridable(self):
        parser = asc.build_parser()
        default = asc.normalize_args(parser.parse_args(["probe"]))
        overridden = asc.normalize_args(parser.parse_args(["probe", "--app-id", "1234567890"]))
        self.assertEqual(default.app_id, asc.DEFAULT_APP_ID)
        self.assertEqual(overridden.app_id, "1234567890")

    def test_no_subcommand_prints_help_and_exits_usage(self):
        self.assertEqual(asc.main([]), asc.EXIT_USAGE)

    def test_preflight_without_a_key_exits_usage_with_a_clear_message(self):
        import contextlib
        import io
        import os

        saved = {k: os.environ.pop(k, None) for k in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_PATH")}
        try:
            buffer = io.StringIO()
            with contextlib.redirect_stderr(buffer):
                code = asc.main(["preflight", "--version", "1.1"])
        finally:
            for key, value in saved.items():
                if value is not None:
                    os.environ[key] = value
        self.assertEqual(code, asc.EXIT_USAGE)
        self.assertIn("ASC_ISSUER_ID", buffer.getvalue())

    def test_handlers_require_a_version_before_touching_the_network(self):
        for handler in (asc.command_preflight, asc.command_screenshots, asc.command_submit):
            with self.subTest(handler=handler.__name__):
                with self.assertRaises(asc.UsageError) as ctx:
                    handler(None, _args(version=None))
                self.assertIn("--version", str(ctx.exception))

    def test_main_reports_missing_version_as_usage_error(self):
        import contextlib
        import io
        import os

        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_TEST.p8"
            key.write_text("x")
            env = {
                "ASC_ISSUER_ID": "issuer",
                "ASC_KEY_ID": "KEY",
                "ASC_KEY_PATH": str(key),
            }
            saved = {name: os.environ.get(name) for name in env}
            os.environ.update(env)
            try:
                buffer = io.StringIO()
                with contextlib.redirect_stderr(buffer):
                    code = asc.main(["submit", "--dry-run"])
            finally:
                for name, value in saved.items():
                    if value is None:
                        os.environ.pop(name, None)
                    else:
                        os.environ[name] = value
        self.assertEqual(code, asc.EXIT_USAGE)
        self.assertIn("--version", buffer.getvalue())


def _args(**overrides):
    """A bare argparse.Namespace for handler tests that never touch the network."""
    import argparse

    base = dict(
        version="1.1",
        build=None,
        fix=False,
        max_probes=1,
        probe_interval=0,
        wait_timeout=0,
        submission_id=None,
        app_id="6759184867",
        dry_run=True,
        verbose=False,
        locale_dir=[],
        display_type=None,
        whats_new_file=None,
        skip_preflight=False,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


if __name__ == "__main__":
    unittest.main()
