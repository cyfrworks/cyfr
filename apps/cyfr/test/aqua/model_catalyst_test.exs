# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ModelCatalystTest do
  use ExUnit.Case, async: true

  alias Aqua.ModelCatalyst

  test "the protocol follows the catalyst's name, whatever its publisher or version" do
    assert {:ok, :claude} = ModelCatalyst.protocol("catalyst:moonmoon69.claude:1.0.0")
    assert {:ok, :claude} = ModelCatalyst.protocol("catalyst:local.claude")
    assert {:ok, :gemini} = ModelCatalyst.protocol("catalyst:acme.gemini:2.3.4")
    assert {:ok, nil} = ModelCatalyst.protocol(nil)
  end

  test "a name the table does not know is a typed refusal, never a guess" do
    # The guest matched `contains("claude")` over the whole reference; a
    # look-alike got a Claude-shaped request with every tool dropped.
    assert {:error, {:unsupported_model_catalyst, "catalyst:local.my-claude"}} =
             ModelCatalyst.protocol("catalyst:local.my-claude")

    assert {:error, {:unsupported_model_catalyst, "not a ref"}} =
             ModelCatalyst.protocol("not a ref")
  end
end
