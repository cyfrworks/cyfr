# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Cosign do
  @moduledoc """
  Wraps the `cosign` CLI for OCI image signature verification via Sigstore.

  Reads configuration from `Application.get_env(:cyfr, :sigstore)`:

  - `verification: :keyed` — verify with a specific public key (`key_path`,
    `CYFR_COSIGN_KEY`). The same key signs on publish and verifies on pull,
    so keyed verification pins pulls to that one key.
  - `verification: :keyless` — verify via Sigstore's keyless (Fulcio + Rekor)
    flow against a named signer: `identity` and `issuer` are regexps the
    certificate must match (`CYFR_COSIGN_IDENTITY` / `CYFR_COSIGN_ISSUER`)
  - `cosign_path` — the cosign executable, a name looked up on `PATH` or an
    absolute path (default `"cosign"`)
  - `timeout_ms` — how long one cosign run may take before it is killed and
    the verification answers `:unavailable` (default 30 s)

  Returns signer identity, issuer, and verification timestamp on success.

  ## A verification is bound to a digest and names a signer

  cosign is asked about `<registry>/<repository>@<digest>`, never a tag, and
  its answer counts only when it is a JSON array whose first entry's
  `critical.image.docker-manifest-digest` is the digest the caller stored.

  - Keyless: the first entry's `optional` claims must carry a non-empty
    certificate subject and issuer, which are the recorded signer. The
    identity and issuer regexps are required; missing values refuse
    verification before cosign runs.
  - Keyed: a keyed signature carries no certificate, so the recorded signer
    is the key itself — `identity: "key:sha256:<hex>"` over the bytes of
    the key file handed to cosign, `issuer: "key"` — computed here, never
    read from cosign's output. An unset key refuses, and an unreadable or
    empty key file refuses, before cosign runs.
  """

  require Logger

  # One cosign run's budget. A cosign that neither answers nor exits
  # (a registry or transparency log that holds the connection open) must not
  # hold the pull that is waiting on it.
  @timeout_ms 30_000

  @typedoc """
  Why a verification did not happen or did not pass.

    * `:unavailable` — cosign is absent, cannot be started, or did not exit
      within the timeout
    * `{:unset, settings}` — the named settings are required and unset
    * `{:unreadable_key, key_path}` — the configured key file cannot be read
      or is empty
    * `{:rejected, output}` — cosign exited non-zero
    * `:unreadable` — cosign exited 0 without a JSON answer
    * `:not_an_array` — the answer is JSON but not an array
    * `:empty` — the answer is an empty array
    * `:digest_mismatch` — the first entry does not name the expected digest
    * `:no_identity` — the first entry carries no subject or no issuer
  """
  @type refusal ::
          :unavailable
          | {:unset, [String.t()]}
          | {:unreadable_key, String.t()}
          | {:rejected, String.t()}
          | :unreadable
          | :not_an_array
          | :empty
          | :digest_mismatch
          | :no_identity

  @doc """
  Verify the signature of the image at `reference`, which must name
  `expected_digest`.

  Returns `{:ok, metadata}` with signer identity/issuer on success,
  or `{:error, refusal}` on failure.
  """
  @spec verify(String.t(), String.t()) ::
          {:ok, %{identity: String.t(), issuer: String.t(), verified_at: DateTime.t()}}
          | {:error, refusal()}
  def verify(reference, expected_digest)
      when is_binary(reference) and is_binary(expected_digest) do
    config = Application.get_env(:cyfr, :sigstore, verification: :keyless)

    # What this server will accept as a signature is settled before we go
    # looking for the tool: it is a property of the configuration, not of
    # the machine, and it is the half that decides whether "verified" means
    # anything.
    with {:ok, args, signer} <- build_args(reference, config),
         {:ok, cosign_path} <- find_cosign(config),
         {:ok, output} <- run(cosign_path, args, timeout_ms(config)) do
      parse_verify_output(output, expected_digest, signer)
    end
  end

  @doc """
  Renders a refusal as the sentence a pull records.
  """
  @spec describe(refusal()) :: String.t()
  def describe(:unavailable),
    do:
      "cosign is unavailable (not installed, not startable, or did not answer in time). " <>
        "Install: https://docs.sigstore.dev/cosign/system_config/installation/"

  def describe({:unset, settings}),
    do:
      "signature verification needs a signer to check against: set " <>
        Enum.join(settings, " and ") <>
        ". Matching any identity would make \"verified\" mean only that someone, " <>
        "somewhere, signed this."

  def describe({:unreadable_key, key_path}),
    do: "the verification key at #{key_path} (CYFR_COSIGN_KEY) cannot be read or is empty"

  def describe({:rejected, output}), do: "cosign refused the signature: #{output}"
  def describe(:unreadable), do: "cosign returned an unreadable response"
  def describe(:not_an_array), do: "cosign's answer is not a list of verified signatures"
  def describe(:empty), do: "cosign's answer lists no verified signatures"

  def describe(:digest_mismatch),
    do: "cosign verified a different manifest digest than the one pulled"

  def describe(:no_identity), do: "cosign's answer names no signer subject and issuer"

  defp timeout_ms(config) do
    case Keyword.get(config, :timeout_ms, @timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @timeout_ms
    end
  end

  defp find_cosign(config) do
    case System.find_executable(Keyword.get(config, :cosign_path, "cosign")) do
      nil -> {:error, :unavailable}
      path -> {:ok, path}
    end
  end

  # System.cmd/3 has no timeout, so cosign runs on a port this process
  # owns. On timeout the port is closed and the OS process killed by pid:
  # closing the port alone leaves cosign running.
  defp run(cosign_path, args, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, port} <- open(cosign_path, args) do
      collect(port, [], deadline)
    end
  end

  defp open(cosign_path, args) do
    {:ok,
     Port.open({:spawn_executable, cosign_path}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: args
     ])}
  rescue
    # spawn_executable raises when the file exists but cannot be executed.
    error in ErlangError ->
      Logger.warning(
        "[Compendium.Cosign] cosign could not be started: #{inspect(error.original)}"
      )

      {:error, :unavailable}
  end

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        collect(port, [acc, chunk], deadline)

      {^port, {:exit_status, 0}} ->
        flush_exit(port)
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, _status}} ->
        flush_exit(port)
        {:error, {:rejected, acc |> IO.iodata_to_binary() |> String.trim()}}
    after
      remaining ->
        kill(port)
        {:error, :unavailable}
    end
  end

  defp kill(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    # The port may already have closed on its own between the deadline and
    # here; closing a closed port raises.
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if os_pid, do: kill_os_process(os_pid)

    Logger.warning("[Compendium.Cosign] cosign did not answer within its timeout; killed it")
    flush_port(port)
  end

  defp kill_os_process(os_pid) do
    case System.find_executable("kill") do
      nil ->
        Logger.error("[Compendium.Cosign] no kill executable; cosign pid #{os_pid} left running")

      kill ->
        System.cmd(kill, ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  # Messages the port sent before it was closed stay in this process's
  # mailbox; the caller is a pull and must not inherit them.
  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> flush_exit(port)
    end
  end

  # A caller that traps exits receives the port's exit signal as a message.
  defp flush_exit(port) do
    receive do
      {:EXIT, ^port, _} -> :ok
    after
      0 -> :ok
    end
  end

  # Answers cosign's arguments and the signer a passing answer records:
  # `:certificate` reads it from the answer's claims, `{:key, identity}` is
  # the key this server handed cosign.
  defp build_args(reference, config) do
    case Keyword.get(config, :verification, :keyless) do
      :keyed ->
        keyed_args(reference, Keyword.get(config, :key_path))

      :keyless ->
        keyless_args(reference, config)
    end
  end

  defp keyed_args(reference, key_path) when is_binary(key_path) and key_path != "" do
    # The fingerprint is of the bytes at the path cosign is handed, read
    # before cosign runs; cosign's answer says nothing about which key it
    # used.
    case File.read(key_path) do
      {:ok, key} when key != "" ->
        fingerprint = :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

        # "--" terminates flag parsing so a reference starting with "-"
        # can never be interpreted as a cosign flag (the port is not a
        # shell).
        {:ok, ["verify", "--key", key_path, "--output", "json", "--", reference],
         {:key, "key:sha256:" <> fingerprint}}

      _ ->
        {:error, {:unreadable_key, key_path}}
    end
  end

  defp keyed_args(_reference, _key_path), do: {:error, {:unset, ["CYFR_COSIGN_KEY"]}}

  defp keyless_args(reference, config) do
    identity = Keyword.get(config, :identity)
    issuer = Keyword.get(config, :issuer)

    case Enum.reject(
           [{"CYFR_COSIGN_IDENTITY", identity}, {"CYFR_COSIGN_ISSUER", issuer}],
           fn {_setting, value} -> present?(value) end
         ) do
      [] ->
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
           reference
         ], :certificate}

      unset ->
        {:error, {:unset, Enum.map(unset, &elem(&1, 0))}}
    end
  end

  # cosign writes its "Verification for ..." preamble to stderr and the
  # JSON answer to stdout as one line; the port merges the two, so the
  # answer is the whole output when that decodes, else its last line that
  # decodes as JSON. Either way the value then has to pass every check
  # below: finding JSON is not accepting it.
  defp parse_verify_output(output, expected_digest, signer) do
    case decode_answer(output) do
      {:ok, answer} ->
        check_answer(answer, expected_digest, signer)

      :error ->
        # `--output json` was asked for; anything else means this is not the
        # cosign we think we are talking to. Reading an unparseable answer as
        # a successful verification is the one direction that must not be
        # guessed.
        Logger.warning(
          "[Compendium.Cosign] cosign exited 0 but its output was not JSON — " <>
            "refusing to record a verification"
        )

        {:error, :unreadable}
    end
  end

  defp decode_answer(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, answer} ->
        {:ok, answer}

      {:error, _} ->
        output
        |> String.split("\n")
        |> Enum.reverse()
        |> Enum.find_value(:error, &decode_json_line/1)
    end
  end

  defp decode_json_line(line) do
    line = String.trim(line)

    with true <- String.starts_with?(line, ["[", "{"]),
         {:ok, answer} <- Jason.decode(line) do
      {:ok, answer}
    else
      _ -> nil
    end
  end

  # The answer binds to the pulled manifest only through the digest the
  # signature covers. A keyless answer names a signer only through the
  # certificate's subject and issuer, and one missing either is not a
  # verification; a keyed answer's signer is the key handed to cosign.
  defp check_answer(answer, _expected_digest, _signer) when not is_list(answer),
    do: {:error, :not_an_array}

  defp check_answer([], _expected_digest, _signer), do: {:error, :empty}

  defp check_answer([first | _], expected_digest, signer) do
    with :ok <- check_digest(first, expected_digest) do
      check_identity(first, signer)
    end
  end

  defp check_digest(
         %{"critical" => %{"image" => %{"docker-manifest-digest" => digest}}},
         expected_digest
       )
       when digest == expected_digest,
       do: :ok

  defp check_digest(_entry, _expected_digest), do: {:error, :digest_mismatch}

  defp check_identity(_entry, {:key, identity}),
    do: {:ok, %{identity: identity, issuer: "key", verified_at: DateTime.utc_now()}}

  defp check_identity(%{"optional" => %{} = claims}, :certificate) do
    identity = claims["Subject"] || claims["subject"]
    issuer = claims["Issuer"] || claims["issuer"]

    if present?(identity) and present?(issuer) do
      {:ok, %{identity: identity, issuer: issuer, verified_at: DateTime.utc_now()}}
    else
      {:error, :no_identity}
    end
  end

  defp check_identity(_entry, :certificate), do: {:error, :no_identity}

  defp present?(value), do: is_binary(value) and value != ""
end
