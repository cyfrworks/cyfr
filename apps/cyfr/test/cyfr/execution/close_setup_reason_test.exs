# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.CloseSetupReasonTest do
  @moduledoc "A vault setup refusal is recorded by its shape; the detail it carries is never written."

  use ExUnit.Case, async: true

  alias Cyfr.Execution.Close

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
end
