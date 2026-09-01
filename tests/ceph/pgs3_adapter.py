"""Narrow compatibility adapter for pgs3's always-enabled versioning model."""

from __future__ import annotations

from typing import Any


_original_make_api_call = None


def pytest_configure(config: Any) -> None:
    del config
    global _original_make_api_call
    from botocore.client import BaseClient

    if _original_make_api_call is not None:
        return
    _original_make_api_call = BaseClient._make_api_call

    def make_api_call(self: Any, operation_name: str, api_params: dict[str, Any]):
        if operation_name == "PutBucketVersioning":
            configuration = api_params.get("VersioningConfiguration", {})
            status = configuration.get("Status")
            mfa_delete = configuration.get("MFADelete")
            unexpected = set(configuration) - {"Status", "MFADelete"}
            if status == "Enabled" and mfa_delete in (None, "Disabled") and not unexpected:
                return {
                    "ResponseMetadata": {
                        "HTTPStatusCode": 200,
                        "HTTPHeaders": {},
                        "RetryAttempts": 0,
                    }
                }
        assert _original_make_api_call is not None
        return _original_make_api_call(self, operation_name, api_params)

    BaseClient._make_api_call = make_api_call


def pytest_unconfigure(config: Any) -> None:
    del config
    global _original_make_api_call
    if _original_make_api_call is None:
        return
    from botocore.client import BaseClient

    BaseClient._make_api_call = _original_make_api_call
    _original_make_api_call = None
