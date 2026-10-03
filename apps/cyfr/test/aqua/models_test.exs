# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ModelsTest do
  @moduledoc """
  The model listing's refusals: the listing reads the athanor's catalysts
  through the component domain's facade and refuses as it refuses, and a
  model status needs a context. The assistant's root roster is
  `Aqua.FacadeTest`'s.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the listing refuses a caller the component facts refuse, and runs nothing" do
    local = Sanctum.TestContext.local()

    anonymous = %{local | authenticated: false}
    assert {:error, :forbidden} = Aqua.models(anonymous)

    unfocused = %{local | athanor_id: nil, scope: :platform}
    assert {:error, :forbidden} = Aqua.models(unfocused)

    no_read = %{local | permissions: MapSet.new([:execute])}
    assert {:error, :forbidden} = Aqua.models(no_read)

    assert {:error, :forbidden} = Aqua.models(Context.enter_guest(local))
  end

  test "an athanor whose component index is behind answers unavailable, not an empty listing" do
    n = System.unique_integer([:positive])
    user = "local|idp|models-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Models #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}

    assert {:ok, %{"models" => %{}, "refs" => %{}, "errors" => %{}}} = Aqua.models(ctx)

    {:ok, _pending} =
      Arca.StorageProjectionChanges.begin_edit(
        Context.actor(ctx),
        "components",
        "catalysts/local/claude/1.0.0"
      )

    assert {:error, :unavailable} = Aqua.models(ctx)
  end

  test "a model status needs a context" do
    assert Aqua.model_status(nil, [%{"type" => "soul", "catalyst_ref" => "catalyst:local.x"}]) ==
             %{}
  end
end
