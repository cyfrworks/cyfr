# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyMCPTest do
  @moduledoc """
  The `athanor` tool — the verb that reads and patches the caller's own
  athanor, and that nothing calls through the tool surface.

  `Sanctum.Tenancy.Athanors` is well covered, but the ARGUMENT MAPPING
  between the wire and it — which athanor an action resolves to, who may
  name it, and what each refusal turns into — lives only here.

  What that mapping owes its callers, and what this file pins:

  - An athanor the caller holds no seat in is answered as a missing one,
    an operator's included, and the refusal reads nothing the athanor
    holds.
  - An archived athanor is a hard stop on every path except the read that
    asks for it by name, and that is its person's.
  - The person-only verbs refuse an API key with a sentence, before doing
    anything.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Provider
  alias Sanctum.Tenancy.Athanors

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|tenancy_#{n}",
        provider: "github",
        email: "tenancy#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        namespace: "tenancyns",
        athanor_id: athanor.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, ctx: ctx, user: user, athanor: athanor}
  end

  describe "athanor.get" do
    test "the caller's athanor is readable by id", %{ctx: ctx, athanor: athanor} do
      assert {:ok, fetched} =
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => athanor.id})

      assert fetched.id == athanor.id
    end

    test "an unknown action names itself rather than falling through", %{ctx: ctx} do
      assert {:error, {:unknown_action, "athanor.explode"}} =
               Provider.handle("athanor", ctx, %{"action" => "explode"})
    end
  end

  describe "resolve/3 — which athanor an action gets to name" do
    test "an athanor the caller does not belong to is refused, an operator's read included",
         %{ctx: ctx} do
      n = System.unique_integer([:positive])

      {:ok, theirs} =
        Athanors.create(%{
          name: "Not Yours #{n}",
          slug: "not-yours-#{n}",
          owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          created_by: "system"
        })

      # Answered as a missing athanor is: the refusal tells the caller
      # nothing of whether it exists.
      id = theirs.id

      assert {:error, {:not_found, "Athanor", ^id}} =
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => id})

      # An operator holds no seat there either: athanor.get answers a
      # seatless administrator as it answers for a missing athanor.
      test = self()
      handler = "tenancy-mcp-facts-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and is_binary(meta[:source]),
              do: send(test, {:read, meta[:source]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, {:not_found, "Athanor", ^id}} =
               Provider.handle("athanor", %{ctx | platform_admin: true}, %{
                 "action" => "get",
                 "athanor" => id
               })

      :telemetry.detach(handler)

      # The row and the seat check, and nothing the athanor holds: no
      # thread, file, vault or member list is read for the refusal.
      assert Enum.reject(reads(), &(&1 in ["athanors", "memberships"])) == []
    end

    test "an archived athanor is a hard stop except where the action asks for it",
         %{ctx: ctx, athanor: athanor} do
      {:ok, _} = Athanors.archive(athanor, force: true)

      # The read passes `include_archived: true` and still works.
      assert {:ok, %{status: "archived"}} =
               Provider.handle("athanor", ctx, %{"action" => "get", "athanor" => athanor.id})

      # What would change it does not.
      assert {:error, {:invalid_argument, "That athanor is archived"}} =
               Provider.handle("athanor", ctx, %{
                 "action" => "settings",
                 "athanor" => athanor.id,
                 "settings" => %{"x" => 1}
               })
    end
  end

  describe "the person-only verbs and an API key" do
    test "an API key is refused with a sentence, before the athanor is even resolved", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      for action <- ["settings", "provision"] do
        assert {:error, {:invalid_argument, message}} =
                 Provider.handle("athanor", key_ctx, %{
                   "action" => action,
                   "athanor" => "ath_does_not_exist",
                   "settings" => %{}
                 })

        assert message == "athanor.#{action} is a person's act — sign in; an API key cannot do it",
               "athanor.#{action} let an API key through"
      end

      # A read is not a person's act, so the key still gets it.
      assert {:ok, _} = Provider.handle("athanor", key_ctx, %{"action" => "get"})
    end
  end

  # The tables a case's own statements read, in order.
  defp reads(acc \\ []) do
    receive do
      {:read, source} -> reads([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
