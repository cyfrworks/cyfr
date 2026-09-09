# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Cosign do
  @moduledoc """
  Wraps the `cosign` CLI for OCI image signature verification via Sigstore.

  Reads configuration from `Application.get_env(:cyfr, :sigstore)`:

  - `verification: :keyed` — verify with a specific public key (`key_path`)
  - `verification: :keyless` — verify via Sigstore's keyless (Fulcio + Rekor)
    flow against a named signer: `identity` and `issuer` are regexps the
    certificate must match (`CYFR_COSIGN_IDENTITY` / `CYFR_COSIGN_ISSUER`)

  Returns signer identity, issuer, and verification timestamp on success.

  ## Keyless verification names a signer

  Keyless verification requires an explicit trusted certificate identity
  and OIDC issuer. Missing values refuse verification.
  """

  require Logger

  @doc """
  Verify the signature of an OCI image reference.

  Returns `{:ok, metadata}` with signer identity/issuer on success,
  or `{:error, reason}` on failure.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify(oci_ref) when is_binary(oci_ref) do
    config = Application.get_env(:cyfr, :sigstore, verification: :keyless)

    # What this server will accept as a signature is settled before we go
    # looking for the tool: it is a property of the configuration, not of
    # the machine, and it is the half that decides whether "verified" means
    # anything.
    with {:ok, args} <- build_args(oci_ref, config),
         {:ok, cosign_path} <- find_cosign() do
      run(cosign_path, args, oci_ref)
    end
  end

  defp find_cosign do
    case System.find_executable("cosign") do
      nil ->
        {:error,
         "cosign not found in PATH. Install: https://docs.sigstore.dev/cosign/system_config/installation/"}

      path ->
        {:ok, path}
    end
  end

  defp run(cosign_path, args, oci_ref) do
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
        {:ok, ["verify", "--key", key_path, "--output", "json", "--", oci_ref]}

      :keyless ->
        keyless_args(oci_ref, config)
    end
  end

  defp keyless_args(oci_ref, config) do
    identity = Keyword.get(config, :identity)
    issuer = Keyword.get(config, :issuer)

    if is_binary(identity) and identity != "" and is_binary(issuer) and issuer != "" do
      {:ok,
       [
         "verify",
         "--certificate-identity-regexp",
         identity,
         "--certificate-oidc-issuer-regexp",
         issuer,
         "--output",
         "json",
         # "--" terminates flag parsing (see :keyed branch above).
         "--",
         oci_ref
       ]}
    else
      {:error,
       "keyless signature verification needs a signer to check against: set " <>
         "CYFR_COSIGN_IDENTITY and CYFR_COSIGN_ISSUER (regexps the signing " <>
         "certificate must match), or CYFR_COSIGN_KEY for keyed verification. " <>
         "Matching any identity would make \"verified\" mean only that someone, " <>
         "somewhere, signed this."}
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
        # `--output json` was asked for; anything else means this is not the
        # cosign we think we are talking to. Reading an unparseable answer as
        # a successful verification is the one direction that must not be
        # guessed.
        Logger.warning(
          "[Compendium.Cosign] cosign exited 0 but its output was not JSON — " <>
            "refusing to record a verification"
        )

        {:error, "cosign returned an unreadable response"}
    end
  end
end
