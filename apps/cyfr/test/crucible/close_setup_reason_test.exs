# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.CloseSetupReasonTest do
  @moduledoc """
  What a failed close writes into `executions.error_message`: a vault setup
  refusal by its shape, the detail it carries never; a component's own
  error in its own words, bounded, and as redacted JSON when it is not a
  string.
  """

  use ExUnit.Case, async: true

  alias Crucible.Close

  test "named shapes keep their sentence" do
    assert Close.setup_reason({:entry_unavailable, "revoked"}) == "vault_entry_revoked"
    assert Close.setup_reason({:selection_unbound, "work"}) == "vault_selection_unbound"
    assert Close.setup_reason(:consent_moved) == "consent_moved"
    assert Close.setup_reason(:unseal_failed) == :unseal_failed
  end

  test "a reason carrying detail is recorded by its tag, and anything else by a fixed word" do
    payload = %{"api_key" => "sk-canary-0123456789"}

    assert Close.setup_reason({:invalid_payload, payload}) == :invalid_payload
    refute inspect(Close.setup_reason({:invalid_payload, payload})) =~ "sk-canary"
    assert Close.setup_reason("free text from somewhere") == :vault_refused
    assert Close.setup_reason(%{"raw" => "sk-canary-0123456789"}) == :vault_refused
  end

  describe "a component's own error" do
    test "a string is its own words" do
      assert Close.application_error(%{"error" => "quota exhausted"}) == "quota exhausted"

      assert Close.application_error(%{"error" => %{"message" => "no such city", "code" => 4}}) ==
               "no such city"

      assert Close.application_error(%{"result" => 1}) == nil
      assert Close.application_error("not a map") == nil
    end

    test "anything else is its JSON with sensitive values redacted, never an Elixir rendering" do
      rendered =
        Close.application_error(%{
          "error" => %{"kind" => "upstream", "api_key" => "sk-canary-0123456789"}
        })

      assert Jason.decode!(rendered) == %{"kind" => "upstream", "api_key" => "[REDACTED]"}
      refute rendered =~ "sk-canary"
      refute rendered =~ "%{"

      assert Close.application_error(%{"error" => %{"message" => %{"token" => "t0k3n"}}}) ==
               ~s({"token":"[REDACTED]"})
    end

    test "is bounded at 1 024 bytes on a character boundary" do
      long = String.duplicate("é", 2_000)
      rendered = Close.application_error(%{"error" => long})

      assert byte_size(rendered) <= 1_024
      assert String.valid?(rendered)
      assert String.ends_with?(rendered, "…")

      map = %{"error" => %{"detail" => String.duplicate("x", 5_000)}}
      assert byte_size(Close.application_error(map)) <= 1_024
    end
  end
end
