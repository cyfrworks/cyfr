# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Cosign do
  @moduledoc """
  Wraps the `cosign` CLI for OCI image signature verification via Sigstore.

  Reads configuration from `Application.get_env(:cyfr, :sigstore)`:

  - `verification: :keyed` — verify with a specific public key (`key_path`)
  - `verification: :keyless` — verify via Sigstore's keyless (Fulcio + Rekor) flow

  Returns signer identity, issuer, and verification timestamp on success.
  """

  require Logger

  @doc """
  Verify the signature of an OCI image reference.

  Returns `{:ok, metadata}` with signer identity/issuer on success,
  or `{:error, reason}` on failure.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify(oci_ref) when is_binary(oci_ref) do
    case System.find_executable("cosign") do
      nil ->
        {:error,
         "cosign not found in PATH. Install: https://docs.sigstore.dev/cosign/system_config/installation/"}

      cosign_path ->
        config = Application.get_env(:cyfr, :sigstore, verification: :keyless)
        do_verify(cosign_path, oci_ref, config)
    end
  end

  defp do_verify(cosign_path, oci_ref, config) do
    args = build_args(oci_ref, config)

    case System.cmd(cosign_path, args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_verify_output(output)

      {output, _exit_code} ->
        {:error, "Signature verification failed for #{oci_ref}: #{String.trim(output)}"}
    end
  end

  defp build_args(oci_ref, config) do
    case Keyword.get(config, :verification, :keyless) do
      :keyed ->
        key_path = Keyword.fetch!(config, :key_path)
        # "--" terminates flag parsing so an oci_ref starting with "-" can never
        # be interpreted as a cosign flag (System.cmd is already non-shell).
        ["verify", "--key", key_path, "--output", "json", "--", oci_ref]

      :keyless ->
        [
          "verify",
          "--certificate-identity-regexp",
          ".*",
          "--certificate-oidc-issuer-regexp",
          ".*",
          "--output",
          "json",
          # "--" terminates flag parsing (see :keyed branch above).
          "--",
          oci_ref
        ]
    end
  end

  defp parse_verify_output(output) do
    case Jason.decode(output) do
      {:ok, [first | _]} ->
        optional_claims = first["optional"] || %{}
        identity = optional_claims["Subject"] || optional_claims["subject"]
        issuer = optional_claims["Issuer"] || optional_claims["issuer"]

        {:ok,
         %{
           identity: identity,
           issuer: issuer,
           verified_at: DateTime.utc_now()
         }}

      {:ok, []} ->
        {:error, "No signatures found in cosign output"}

      {:ok, _} ->
        # Single object instead of array
        {:ok,
         %{
           identity: nil,
           issuer: nil,
           verified_at: DateTime.utc_now()
         }}

      {:error, _} ->
        # cosign succeeded but output wasn't JSON — still verified
        Logger.debug("[Compendium.Cosign] cosign output was not JSON, treating as verified")

        {:ok,
         %{
           identity: nil,
           issuer: nil,
           verified_at: DateTime.utc_now()
         }}
    end
  end
end
