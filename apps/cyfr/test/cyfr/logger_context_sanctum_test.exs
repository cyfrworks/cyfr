# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerContextSanctumTest do
  use ExUnit.Case, async: true

  alias Cyfr.LoggerContext

  test "set_from_context/1 sets Logger metadata from a Sanctum.Context" do
    ctx =
      Sanctum.Context.build(
        user_id: "user_123",
        athanor_id: "ath_abc",
        permissions: [:execute],
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    LoggerContext.set_from_context(ctx)

    metadata = Logger.metadata()
    assert metadata[:user_id] == "user_123"
    assert metadata[:athanor_id] == "ath_abc"
    assert metadata[:auth_method] == :oidc
  end
end
