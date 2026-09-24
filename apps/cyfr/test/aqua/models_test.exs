# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ModelsTest do
  @moduledoc """
  The assistant's door for callers outside it, and the model listing's
  refusals: the root answers exactly its delegating functions, the
  listing reads the estate's catalysts through the component domain's
  facade and refuses as it refuses, and a model status needs a context.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  test "the root answers exactly its six delegating functions" do
    exported =
      Aqua.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == [
             consent_state: 1,
             consent_state: 2,
             model_capabilities: 5,
             model_status: 2,
             models: 1,
             stale_consent_refs: 1
           ]
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

  test "an estate whose component index is behind answers unavailable, not an empty listing" do
    n = System.unique_integer([:positive])
    user = "local|idp|models-#{n}"
    {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Models #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(estate)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}

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
