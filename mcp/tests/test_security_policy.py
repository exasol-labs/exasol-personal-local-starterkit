"""Security-policy edge cases for MCP requests."""

from __future__ import annotations

import unittest

from mcp.core.models import CredentialReference, DeploymentMode, OperationName, OperationRequest, ServerDefinition
from mcp.security.policy import SecurityPolicy


class SecurityPolicyEdgeCaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = SecurityPolicy()

    def test_http_non_loopback_target_is_blocked(self) -> None:
        findings = self.policy.preflight(
            OperationRequest(
                operation=OperationName.CONFIGURE,
                deployment_mode=DeploymentMode.HTTP,
                server_definition=ServerDefinition(
                    transport=DeploymentMode.HTTP,
                    name="exasol",
                    url="http://10.20.30.40:8080/mcp",
                ),
            )
        )
        self.assertTrue(any(finding.code == "unsafe_http_target" and finding.blocking for finding in findings))

    def test_stdio_without_command_is_blocked(self) -> None:
        findings = self.policy.preflight(
            OperationRequest(
                operation=OperationName.CONFIGURE,
                deployment_mode=DeploymentMode.STDIO,
                server_definition=ServerDefinition(
                    transport=DeploymentMode.STDIO,
                    name="exasol",
                    command=None,
                ),
            )
        )
        self.assertTrue(any(finding.code == "missing_server_command" and finding.blocking for finding in findings))

    def test_literal_credential_reference_is_warned(self) -> None:
        findings = self.policy.preflight(
            OperationRequest(
                operation=OperationName.CONFIGURE,
                deployment_mode=DeploymentMode.STDIO,
                server_definition=ServerDefinition(
                    transport=DeploymentMode.STDIO,
                    name="exasol",
                    command="uvx",
                ),
                credential_reference=CredentialReference(kind="literal", value="secret"),
            )
        )
        self.assertTrue(any(finding.code == "plaintext_credential_reference" for finding in findings))

    def test_inline_env_plaintext_credential_is_warned(self) -> None:
        # The path the installer actually uses: an inline_env reference whose
        # value is embedded in the server env block (plaintext on disk).
        findings = self.policy.preflight(
            OperationRequest(
                operation=OperationName.CONFIGURE,
                deployment_mode=DeploymentMode.STDIO,
                server_definition=ServerDefinition(
                    transport=DeploymentMode.STDIO,
                    name="exasol",
                    command="uvx",
                    env={"EXA_PASSWORD": "s3cret"},
                ),
                credential_reference=CredentialReference(kind="inline_env", name="EXA_PASSWORD"),
            )
        )
        self.assertTrue(any(finding.code == "plaintext_credential_reference" for finding in findings))

    def test_inline_env_without_embedded_value_is_not_warned(self) -> None:
        # A pure env-var reference (no value written to the config) is not plaintext.
        findings = self.policy.preflight(
            OperationRequest(
                operation=OperationName.CONFIGURE,
                deployment_mode=DeploymentMode.STDIO,
                server_definition=ServerDefinition(
                    transport=DeploymentMode.STDIO,
                    name="exasol",
                    command="uvx",
                ),
                credential_reference=CredentialReference(kind="inline_env", name="EXA_PASSWORD"),
            )
        )
        self.assertFalse(any(finding.code == "plaintext_credential_reference" for finding in findings))


if __name__ == "__main__":
    unittest.main()
