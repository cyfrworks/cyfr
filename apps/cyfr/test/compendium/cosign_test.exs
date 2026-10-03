# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.CosignTest do
  use ExUnit.Case, async: false

  alias Compendium.Cosign

  @digest "sha256:" <> String.duplicate("a", 64)
  @other_digest "sha256:" <> String.duplicate("b", 64)
  @reference "registry.example.com/test/repo@" <> @digest

  @signer [
    verification: :keyless,
    identity: "^release@example\\.com$",
    issuer: "^https://accounts\\.google\\.com$"
  ]

  setup do
    original = Application.get_env(:cyfr, :sigstore)

    dir = Path.join(System.tmp_dir!(), "cyfr_cosign_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if original,
        do: Application.put_env(:cyfr, :sigstore, original),
        else: Application.delete_env(:cyfr, :sigstore)
    end)

    {:ok, dir: dir}
  end

  # Keyless verification against `.*` identity and `.*` issuer accepts a
  # signature from anyone who can obtain a Sigstore certificate — while the
  # component row it feeds records `signature_verified: true`. An operator
  # who wants keyless has to say whose signature counts, and the refusal
  # comes before cosign runs.
  describe "a verification names a signer" do
    test "refuses naming both settings when neither is configured", %{dir: dir} do
      cosign = stand_in(dir, answer: entry(@digest))
      Application.put_env(:cyfr, :sigstore, verification: :keyless, cosign_path: cosign)

      assert {:error, {:unset, ["CYFR_COSIGN_IDENTITY", "CYFR_COSIGN_ISSUER"]} = refusal} =
               Cosign.verify(@reference, @digest)

      assert Cosign.describe(refusal) =~ "CYFR_COSIGN_IDENTITY and CYFR_COSIGN_ISSUER"
      refute invoked?(dir)
    end

    test "refuses naming exactly the setting that is missing", %{dir: dir} do
      cosign = stand_in(dir, answer: entry(@digest))

      for {partial, missing} <- [
            {[identity: "someone@example.com"], ["CYFR_COSIGN_ISSUER"]},
            {[issuer: "https://accounts.google.com"], ["CYFR_COSIGN_IDENTITY"]},
            {[identity: "", issuer: ""], ["CYFR_COSIGN_IDENTITY", "CYFR_COSIGN_ISSUER"]}
          ] do
        Application.put_env(
          :cyfr,
          :sigstore,
          [verification: :keyless, cosign_path: cosign] ++ partial
        )

        assert {:error, {:unset, ^missing}} = Cosign.verify(@reference, @digest)
      end

      refute invoked?(dir)
    end

    test "keyed verification without a key refuses naming the key setting", %{dir: dir} do
      cosign = stand_in(dir, answer: entry(@digest))
      Application.put_env(:cyfr, :sigstore, verification: :keyed, cosign_path: cosign)

      assert {:error, {:unset, ["CYFR_COSIGN_KEY"]}} = Cosign.verify(@reference, @digest)
      refute invoked?(dir)
    end
  end

  describe "the answer binds to the expected digest and names a signer" do
    test "an array whose first entry names the digest and a signer verifies", %{dir: dir} do
      use_stand_in(dir, answer: [entry(@digest)], preamble: true)

      assert {:ok, %{identity: "release@example.com", issuer: issuer, verified_at: at}} =
               Cosign.verify(@reference, @digest)

      assert issuer == "https://accounts.google.com"
      assert %DateTime{} = at

      # The reference cosign is asked about is the one given, after the
      # flag terminator, with the configured signer.
      assert [
               "verify",
               "--certificate-identity-regexp",
               "^release@example\\.com$",
               "--certificate-oidc-issuer-regexp",
               "^https://accounts\\.google\\.com$",
               "--output",
               "json",
               "--",
               @reference
             ] == invoked_args(dir)
    end

    test "a single object is not an array", %{dir: dir} do
      use_stand_in(dir, answer: entry(@digest))
      assert {:error, :not_an_array} = Cosign.verify(@reference, @digest)
    end

    test "an empty array lists no signature", %{dir: dir} do
      use_stand_in(dir, answer: [])
      assert {:error, :empty} = Cosign.verify(@reference, @digest)
    end

    test "a first entry naming a different digest is refused", %{dir: dir} do
      use_stand_in(dir, answer: [entry(@other_digest), entry(@digest)])
      assert {:error, :digest_mismatch} = Cosign.verify(@reference, @digest)
    end

    test "a first entry naming no digest is refused", %{dir: dir} do
      use_stand_in(dir, answer: [Map.delete(entry(@digest), "critical")])
      assert {:error, :digest_mismatch} = Cosign.verify(@reference, @digest)

      use_stand_in(dir, answer: ["not an entry"])
      assert {:error, :digest_mismatch} = Cosign.verify(@reference, @digest)
    end

    test "a keyless entry without a subject or an issuer is not a verification", %{dir: dir} do
      for optional <- [
            %{"Issuer" => "https://accounts.google.com"},
            %{"Subject" => "release@example.com"},
            %{"Subject" => "", "Issuer" => "https://accounts.google.com"},
            %{}
          ] do
        use_stand_in(dir, answer: [Map.put(entry(@digest), "optional", optional)])
        assert {:error, :no_identity} = Cosign.verify(@reference, @digest)
      end

      use_stand_in(dir, answer: [Map.delete(entry(@digest), "optional")])
      assert {:error, :no_identity} = Cosign.verify(@reference, @digest)
    end

    @tag :capture_log
    test "an answer that is not JSON is unreadable", %{dir: dir} do
      use_stand_in(dir, raw: "Verified OK\n")
      assert {:error, :unreadable} = Cosign.verify(@reference, @digest)
    end

    test "a non-zero exit is cosign's refusal, with its words", %{dir: dir} do
      use_stand_in(dir, raw: "Error: no matching signatures\n", status: 1)

      assert {:error, {:rejected, "Error: no matching signatures"} = refusal} =
               Cosign.verify(@reference, @digest)

      assert Cosign.describe(refusal) =~ "no matching signatures"
    end
  end

  # A keyed signature carries no certificate: the signer recorded is the key
  # this server handed cosign, fingerprinted from the file's bytes, never
  # anything cosign's answer claims.
  describe "keyed verification records the key as the signer" do
    test "an array naming the digest without a subject or issuer verifies", %{dir: dir} do
      key = keyed(dir, answer: [Map.delete(entry(@digest), "optional")])
      fingerprint = "key:sha256:" <> sha256_hex(File.read!(key))

      assert {:ok, %{identity: ^fingerprint, issuer: "key", verified_at: %DateTime{}}} =
               Cosign.verify(@reference, @digest)

      assert ["verify", "--key", ^key, "--output", "json", "--", @reference] =
               invoked_args(dir)
    end

    test "a subject cosign's answer claims is not the recorded signer", %{dir: dir} do
      key = keyed(dir, answer: [entry(@digest)])
      fingerprint = "key:sha256:" <> sha256_hex(File.read!(key))

      assert {:ok, %{identity: ^fingerprint, issuer: "key"}} = Cosign.verify(@reference, @digest)
    end

    test "the answer's shape and digest are checked as in keyless mode", %{dir: dir} do
      keyed(dir, answer: Map.delete(entry(@digest), "optional"))
      assert {:error, :not_an_array} = Cosign.verify(@reference, @digest)

      keyed(dir, answer: [])
      assert {:error, :empty} = Cosign.verify(@reference, @digest)

      keyed(dir, answer: [Map.delete(entry(@other_digest), "optional")])
      assert {:error, :digest_mismatch} = Cosign.verify(@reference, @digest)
    end

    test "a missing or empty key file refuses before cosign runs", %{dir: dir} do
      cosign = stand_in(dir, answer: [entry(@digest)])
      missing = Path.join(dir, "missing.pub")
      empty = Path.join(dir, "empty.pub")
      File.write!(empty, "")

      for key_path <- [missing, empty] do
        Application.put_env(:cyfr, :sigstore,
          verification: :keyed,
          key_path: key_path,
          cosign_path: cosign
        )

        assert {:error, {:unreadable_key, ^key_path} = refusal} =
                 Cosign.verify(@reference, @digest)

        assert Cosign.describe(refusal) =~ "CYFR_COSIGN_KEY"
      end

      refute invoked?(dir)
    end
  end

  describe "cosign that cannot answer is unavailable" do
    test "an absent cosign", %{dir: dir} do
      Application.put_env(:cyfr, :sigstore, @signer ++ [cosign_path: Path.join(dir, "absent")])
      assert {:error, :unavailable} = Cosign.verify(@reference, @digest)
    end

    test "no cosign on PATH" do
      Application.put_env(:cyfr, :sigstore, @signer)
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")
        assert {:error, :unavailable} = Cosign.verify(@reference, @digest)
      after
        System.put_env("PATH", original_path)
      end
    end

    @tag :capture_log
    test "a cosign that hangs is killed and answers unavailable", %{dir: dir} do
      cosign = stand_in(dir, hang: true)
      Application.put_env(:cyfr, :sigstore, @signer ++ [cosign_path: cosign, timeout_ms: 300])

      {micros, result} = :timer.tc(fn -> Cosign.verify(@reference, @digest) end)

      assert {:error, :unavailable} = result
      assert micros < 10_000_000

      # The OS process is gone (or a zombie awaiting its reaper), not left
      # sleeping, and nothing from the port is left for the caller.
      pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
      assert eventually(fn -> not running?(pid) end)
      refute_received {_port, {:data, _}}
      refute_received {_port, {:exit_status, _}}
    end
  end

  # -- Stand-in cosign -------------------------------------------------------

  defp use_stand_in(dir, opts) do
    cosign = stand_in(dir, opts)
    Application.put_env(:cyfr, :sigstore, @signer ++ [cosign_path: cosign])
  end

  # A shell script in the test's own directory that records its arguments
  # one per line, then answers `opts[:answer]` as JSON (or `opts[:raw]`),
  # exits `opts[:status]`, or with `hang: true` records its pid and sleeps.
  # `preamble: true` writes the stderr text real cosign prints first.
  defp stand_in(dir, opts) do
    path = Path.join(dir, "cosign")
    File.rm(Path.join(dir, "args"))

    body =
      if opts[:hang] do
        "echo $$ > '#{dir}/pid'\nexec sleep 60\n"
      else
        answer = if Keyword.has_key?(opts, :answer), do: Jason.encode!(opts[:answer]) <> "\n"
        output = Path.join(dir, "output")
        File.write!(output, opts[:raw] || answer)

        preamble =
          if opts[:preamble],
            do:
              "echo 'Verification for #{@reference} --' >&2\n" <>
                "echo '  - The cosign claims were validated' >&2\n",
            else: ""

        preamble <> "cat '#{output}'\nexit #{opts[:status] || 0}\n"
      end

    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{dir}/args'\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # A stand-in answering `opts` and a key file under `dir`, configured for
  # keyed verification; answers the key's path.
  defp keyed(dir, opts) do
    cosign = stand_in(dir, opts)
    key = Path.join(dir, "cosign.pub")
    File.write!(key, "-----BEGIN PUBLIC KEY-----\nstand-in\n-----END PUBLIC KEY-----\n")

    Application.put_env(:cyfr, :sigstore,
      verification: :keyed,
      key_path: key,
      cosign_path: cosign
    )

    key
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp invoked?(dir), do: File.exists?(Path.join(dir, "args"))

  defp invoked_args(dir),
    do: dir |> Path.join("args") |> File.read!() |> String.split("\n", trim: true)

  defp entry(digest) do
    %{
      "critical" => %{
        "identity" => %{"docker-reference" => "registry.example.com/test/repo"},
        "image" => %{"docker-manifest-digest" => digest},
        "type" => "cosign container image signature"
      },
      "optional" => %{
        "Subject" => "release@example.com",
        "Issuer" => "https://accounts.google.com"
      }
    }
  end

  defp running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_, _} -> false
    end
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(check, attempts - 1)
    end
  end
end
