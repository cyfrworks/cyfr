# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.SharedRefusalTest do
  @moduledoc """
  A registry's own error becomes the gate's refusal at the provider's
  edge: classed by the registry's HTTP answer, reason `{:registry, _}`,
  never the Compendium struct.
  """

  use ExUnit.Case, async: true

  alias Compendium.OCI.Errors
  alias Compendium.Providers.Shared

  defp error(status, reason) do
    %Errors{reason: reason, message: "Upstream said no", registry: "cyfr.run", status: status}
  end

  test "each registry answer maps to its class" do
    for {status, reason, class} <- [
          {401, :unauthorized, :unauthenticated},
          {403, :unauthorized, :forbidden},
          {404, :not_found, :not_found},
          {429, :rate_limited, :rate_limited},
          {409, :conflict, :unavailable},
          {503, :registry_unavailable, :unavailable},
          {nil, :registry_unavailable, :unavailable}
        ] do
      assert %Prima.Refusal{class: ^class, reason: {:registry, ^reason}, message: message} =
               Shared.refusal(error(status, reason))

      assert message =~ "Upstream said no"
    end
  end

  test "the sentence carries the actionable hint" do
    assert Shared.refusal(error(401, :unauthorized)).message =~ "cyfr login"
  end

  test "a spent provider token is unauthenticated, and anything else is left to the gate" do
    assert %Prima.Refusal{class: :unauthenticated} = Shared.refusal(:invalid_access_token)
    assert Shared.refusal({:invalid_argument, "x"}) == {:invalid_argument, "x"}
    assert Shared.refusal("a sentence") == "a sentence"
  end
end
