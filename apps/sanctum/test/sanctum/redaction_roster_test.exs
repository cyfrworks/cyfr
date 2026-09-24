# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.RedactionRosterTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins Prima.Sanitizer as the one redaction vocabulary.

  Three lists existed: the Sanitizer's, Phoenix `:filter_parameters` (six
  strings, missing `api_key`, `authorization` and twenty more), and a
  private copy in the registry client. The latter two now derive from the
  first — these tests keep a fourth from growing back.
  """

  alias Prima.Sanitizer

  # apps/sanctum/test/sanctum -> umbrella root
  @umbrella_root Path.expand("../../../..", __DIR__)

  test "Phoenix :filter_parameters is fed from the Sanitizer at boot" do
    assert Application.get_env(:phoenix, :filter_parameters) ==
             Sanitizer.filter_parameters()
  end

  test "sensitive request-param keys are redacted" do
    for key <- ~w(api_key authorization code_verifier bearer credential cookie) do
      assert Sanitizer.sensitive_key?(key), "#{key} must be in the roster"

      assert key in Sanitizer.filter_parameters() or
               Enum.any?(Sanitizer.filter_parameters(), &String.contains?(key, &1)),
             "#{key} must be reachable by Phoenix's substring match"
    end
  end

  test "single-use credentials are redacted: proof, state, ticket, code" do
    sanitized =
      Sanitizer.sanitize(%{
        "proof" => "prf_secret",
        "state" => "csrf_binding",
        "ticket" => "device_ticket",
        "code" => "auth_code",
        "name" => "kept"
      })

    assert sanitized == %{
             "proof" => "[REDACTED]",
             "state" => "[REDACTED]",
             "ticket" => "[REDACTED]",
             "code" => "[REDACTED]",
             "name" => "kept"
           }
  end

  test "state and code redact only as whole keys" do
    kept = Sanitizer.sanitize(%{"execution_state" => "running", "error_code" => -32000})
    assert kept == %{"execution_state" => "running", "error_code" => -32000}
  end

  test "the tincture credential query keys are in the one roster too" do
    # `TinctureAuth` scrubs `_t`/`_key`/`_session` out of `conn.query_string`,
    # but the same names arrive again as decoded params, and the Sanitizer
    # tokenizes them to "t"/"key"/"session" — none of which its patterns held.
    # A path that logs a params map rather than the query string wrote a live
    # tincture token in the clear.
    for key <- Sanctum.TinctureAuth.sensitive_query_keys() do
      assert Sanitizer.sensitive_key?(key), "#{key} must be in the roster"
    end

    assert Sanitizer.sanitize(%{"_t" => "tok", "_key" => "cyfr_pk_x", "_session" => "sess"}) ==
             %{"_t" => "[REDACTED]", "_key" => "[REDACTED]", "_session" => "[REDACTED]"}

    # `key` alone is a credential in its own right: it is what `key.validate`
    # is handed, and those arguments were reaching `mcp_logs` in the clear.
    assert Sanitizer.sensitive_key?("key")

    assert Sanitizer.sanitize(%{"action" => "validate", "key" => "cyfr_pk_LIVE"}) ==
             %{"action" => "validate", "key" => "[REDACTED]"}

    # `session` and `t` bare are not credentials — a session object in an
    # error term is worth reading — so only the query spellings redact.
    refute Sanitizer.sensitive_key?("session")
    refute Sanitizer.sensitive_key?("t")

    assert Sanitizer.sanitize(%{"keyboard" => "kept", "session_count" => 3}) ==
             %{"keyboard" => "kept", "session_count" => 3}
  end

  test "no module outside the Sanitizer declares a sensitive-key roster" do
    offenders =
      Prima.Test.SourceTree.files!(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path -> Prima.Test.SourceTree.read(path) =~ "@sensitive_keys" end)
      |> Enum.map(&Path.relative_to(&1, @umbrella_root))
      |> Enum.reject(&(&1 == "apps/prima/lib/prima/sanitizer.ex"))

    assert offenders == [],
           "redaction roster declared outside Prima.Sanitizer: #{inspect(offenders)}"
  end
end
