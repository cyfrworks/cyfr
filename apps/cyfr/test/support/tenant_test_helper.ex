# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantTestHelper do
  @moduledoc false

  alias Sanctum.Context

  @doc "Returns two contexts working in different athanors."
  def two_contexts do
    ctx_a =
      Context.build(
        user_id: "user_a",
        namespace: "user_a",
        athanor_id: "ath_a",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    ctx_b =
      Context.build(
        user_id: "user_b",
        namespace: "user_b",
        athanor_id: "ath_b",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {ctx_a, ctx_b}
  end
end
