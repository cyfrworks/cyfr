# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.InstanceEntryTest do
  @moduledoc """
  The `instance_entry` tool through the gate: what each action declares,
  the arguments the declaration refuses before a handler runs, who may
  call which action, and what the handlers answer.
  """

  use ExUnit.Case, async: false

  alias Sanctum.TestContext

  @destination %{
    "hosts" => ["api.openai.com"],
    "methods" => ["GET", "POST"],
    "paths" => ["/v1/chat/completions", "/v1/models"]
  }

  @platform ~w(create rotate rebind set_audience set_component_policy set_caps revoke delete
               list usage people)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    {admin, _user} =
      TestContext.person!(%{TestContext.local() | platform_admin: true})

    {:ok, admin: admin, member: %{admin | platform_admin: false}}
  end

  defp call(ctx, args), do: Grimoire.call_external("instance_entry", ctx, args)

  # A person signed in at this home, whom an audience can list.
  defp person_named(name) do
    Sanctum.Context.build(
      user_id: "local|local|ie-#{name}-#{System.unique_integer([:positive])}",
      provider: "local",
      athanor_id: TestContext.athanor_id(),
      permissions: Sanctum.Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp operation(action) do
    {:ok, {_module, tool}} = Grimoire.lookup("instance_entry")
    Enum.find(tool.operations, &(&1.action == action)) || flunk("instance_entry.#{action}")
  end

  defp create_args(over \\ %{}) do
    Map.merge(
      %{
        "action" => "create",
        "name" => "shared-openai-#{System.unique_integer([:positive])}",
        "kind" => "api_key",
        "provider_hint" => "openai.com",
        "fields" => %{"API_KEY" => "sk-instance"},
        "destination" => @destination,
        "audience" => "everyone"
      },
      over
    )
  end

  # The repeat after the proof must be the same request, name included.
  defp create!(admin, over \\ %{}) do
    args = create_args(over)
    assert {:ok, %{entry: entry}} = TestContext.confirming(admin, &call(&1, args))
    entry
  end

  defp entries do
    {:ok, entries} = Arca.InstanceEntries.list(Prima.Actor.system())
    entries
  end

  describe "the declaration" do
    test "every action but offered is the operator's, interactive and external" do
      for action <- @platform do
        op = operation(action)

        assert {op.scope, op.consent, op.planes} == {:platform, :interactive, [:external]},
               action
      end

      for action <- ~w(revoke delete), do: assert(operation(action).kind == :destructive)

      for action <- ~w(list usage offered people),
          do: assert(operation(action).kind == :read)

      offered = operation("offered")

      assert {offered.scope, offered.consent, offered.planes, offered.args} ==
               {nil, nil, [:external], []}

      assert Enum.map(operation("create").args, & &1.name) |> Enum.sort() ==
               Enum.sort(~w(name kind provider_hint fields destination audience members
                            component_policy person_daily total_daily))

      # An instance entry is an API key or a bundle: nothing can dispense an
      # instance entry's OAuth token, so the door offers no such kind.
      kind = Enum.find(operation("create").args, &(&1.name == "kind"))
      assert kind.enum == ["api_key", "bundle"]

      policy = Enum.find(operation("create").args, &(&1.name == "component_policy"))
      assert {policy.required, policy.nullable, policy.enum} == {false, false, ["any", "shipped"]}

      [entry_id, mutation] = operation("set_component_policy").args
      assert {entry_id.name, entry_id.required} == {"entry_id", true}

      assert {mutation.name, mutation.required, mutation.nullable, mutation.enum,
              mutation.default} ==
               {"component_policy", true, false, ["any", "shipped"], :unset}

      days = Enum.find(operation("usage").args, &(&1.name == "days"))
      assert {days.required, days.min, days.max} == {true, 1, 35}
    end

    test "a create omitting the policy stores any; either word is stored as given", %{
      admin: admin
    } do
      assert create!(admin).component_policy == "any"
      assert create!(admin, %{"component_policy" => "shipped"}).component_policy == "shipped"
      assert create!(admin, %{"component_policy" => "any"}).component_policy == "any"
      assert length(entries()) == 3
    end

    test "explicit null, empty, unknown or collection-valued policy is refused before a handler",
         %{admin: admin} do
      for bad <- [nil, "", "custom", "ANY", ["any"], %{"any" => true}, 1, true] do
        assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
                 call(admin, create_args(%{"component_policy" => bad})),
               inspect(bad)
      end

      # Refused at admission: nothing was written.
      assert entries() == []
    end

    test "an OAuth instance entry is refused at the door and, past it, in the handler's words",
         %{admin: admin} do
      assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
               call(admin, create_args(%{"kind" => "oauth"}))

      assert {:error, {:invalid_argument, "kind_unavailable: " <> why}} =
               Sanctum.Providers.InstanceEntry.handle(admin, create_args(%{"kind" => "oauth"}))

      assert why =~ "athanor's own vault"
      assert entries() == []
    end

    test "a destination without methods or paths is refused before a handler", %{admin: admin} do
      for missing <- ["methods", "paths"] do
        assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
                 call(admin, create_args(%{"destination" => Map.delete(@destination, missing)}))
      end

      assert entries() == []
    end

    test "a policy mutation missing either argument is refused before a handler", %{admin: admin} do
      entry = create!(admin)

      for args <- [
            %{"action" => "set_component_policy", "entry_id" => entry.id},
            %{"action" => "set_component_policy", "component_policy" => "shipped"},
            %{
              "action" => "set_component_policy",
              "entry_id" => entry.id,
              "component_policy" => nil
            }
          ] do
        assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
                 call(admin, args),
               inspect(args)
      end

      assert [%{component_policy: "any"}] = entries()
    end

    test "usage names days within the window the sweep keeps", %{admin: admin} do
      entry = create!(admin)

      for days <- [0, 36, -1] do
        assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
                 call(admin, %{"action" => "usage", "entry_id" => entry.id, "days" => days})
      end

      assert {:ok, %{entry_id: id, totals: [], people: []}} =
               call(admin, %{"action" => "usage", "entry_id" => entry.id, "days" => 35})

      assert id == entry.id
    end
  end

  describe "who may call" do
    test "a member calling any platform verb is refused before its handler", %{
      admin: admin,
      member: member
    } do
      entry = create!(admin)

      calls = [
        create_args(),
        %{
          "action" => "rotate",
          "entry_id" => entry.id,
          "fields" => %{"API_KEY" => "x"},
          "expected_payload_rev" => 0
        },
        %{"action" => "rebind", "entry_id" => entry.id, "destination" => @destination},
        %{"action" => "set_audience", "entry_id" => entry.id, "audience" => "listed"},
        %{
          "action" => "set_component_policy",
          "entry_id" => entry.id,
          "component_policy" => "shipped"
        },
        %{"action" => "set_caps", "entry_id" => entry.id, "person_daily" => 1},
        %{"action" => "revoke", "entry_id" => entry.id},
        %{"action" => "delete", "entry_id" => entry.id},
        %{"action" => "list"},
        %{"action" => "usage", "entry_id" => entry.id, "days" => 1},
        %{"action" => "people"}
      ]

      assert Enum.map(calls, & &1["action"]) |> Enum.sort() == Enum.sort(@platform)

      for args <- calls do
        assert {:error, %Prima.Refusal{class: :forbidden, reason: :platform_admin_required}} =
                 call(member, args),
               args["action"]
      end

      assert [%{status: "active", audience: "everyone", component_policy: "any"}] = entries()
    end

    test "offered is any signed-in person's read, metadata only", %{admin: admin, member: member} do
      entry = create!(admin)

      assert {:ok, %{entries: [offer]}} = call(member, %{"action" => "offered"})
      assert offer.id == entry.id
      assert offer.component_policy == "any"
      assert offer.destination == Map.put(@destination, "scheme", "https")
      refute inspect(offer) =~ "sk-instance"

      # A listed audience that does not name the caller offers them nothing.
      {someone_else, _user} = TestContext.person!(person_named("someone-else"))

      assert {:ok, %{status: "updated", changed: true}} =
               call(admin, %{
                 "action" => "set_audience",
                 "entry_id" => entry.id,
                 "audience" => "listed",
                 "members" => [someone_else.user_id]
               })

      assert {:ok, %{entries: []}} = call(member, %{"action" => "offered"})
    end
  end

  describe "the refusals" do
    test "an over-long name or provider is an invalid argument naming the field", %{
      admin: admin
    } do
      long = String.duplicate("n", 256)

      for field <- ["name", "provider_hint"] do
        assert {:error, {:invalid_argument, message}} =
                 call(admin, create_args(%{field => long}))

        assert message =~ field
        refute message =~ long
      end

      assert entries() == []
    end

    test "an id no person has, a typed email among them, is an invalid argument naming " <>
           "members, and nothing is stored",
         %{admin: admin} do
      typed = "someone-#{System.unique_integer([:positive])}@example.com"

      # At create: refused once the key is proven, and no entry is made.
      args = create_args(%{"audience" => "listed", "members" => [admin.user_id, typed]})

      assert {:error, {:invalid_argument, message}} =
               TestContext.confirming(admin, &call(&1, args))

      assert message =~ "person_unknown"
      assert message =~ "members"
      refute message =~ typed
      assert entries() == []

      # At set_audience: refused, and the stored audience stands.
      entry = create!(admin, %{"audience" => "listed", "members" => [admin.user_id]})

      args = %{
        "action" => "set_audience",
        "entry_id" => entry.id,
        "audience" => "listed",
        "members" => [admin.user_id, typed]
      }

      assert {:error, {:invalid_argument, message}} =
               TestContext.confirming(admin, &call(&1, args))

      assert message =~ "person_unknown"
      refute message =~ typed
      assert [%{audience: "listed", members: [member]}] = entries()
      assert member == admin.user_id
    end

    test "a denied person listed in an audience is an invalid argument naming the person", %{
      admin: admin
    } do
      {denied, _user} = TestContext.person!(person_named("denied"))

      {:ok, _} =
        Arca.SecurityTransitions.deny_user(Prima.Actor.system(), denied.user_id,
          verify: fn _rows -> :ok end
        )

      entry = create!(admin, %{"audience" => "listed", "members" => [admin.user_id]})

      args = %{
        "action" => "set_audience",
        "entry_id" => entry.id,
        "audience" => "listed",
        "members" => [admin.user_id, denied.user_id]
      }

      assert {:error, {:invalid_argument, message}} =
               TestContext.confirming(admin, &call(&1, args))

      assert message =~ "person_denied"
      assert message =~ denied.user_id
      assert [%{audience: "listed", members: [member]}] = entries()
      assert member == admin.user_id
    end
  end

  describe "the handlers" do
    test "list, caps, policy, revoke and delete answer through the gate", %{admin: admin} do
      entry = create!(admin)
      refute inspect(entry) =~ "sk-instance"

      assert {:ok, %{entries: [listed]}} = call(admin, %{"action" => "list"})
      assert {listed.id, listed.members, listed.attach_only} == {entry.id, [], true}

      assert {:ok, %{changed: true}} =
               call(admin, %{"action" => "set_caps", "entry_id" => entry.id, "person_daily" => 5})

      assert {:ok, %{changed: false}} =
               call(admin, %{"action" => "set_caps", "entry_id" => entry.id, "person_daily" => 5})

      # A call naming neither cap asks for nothing and is refused.
      assert {:error, {:invalid_argument, _}} =
               call(admin, %{"action" => "set_caps", "entry_id" => entry.id})

      assert {:ok, %{changed: true}} =
               call(admin, %{
                 "action" => "set_caps",
                 "entry_id" => entry.id,
                 "person_daily" => nil
               })

      assert [%{person_daily: nil}] = entries()

      # Tightening needs the session; widening back asks the confirmation.
      assert {:ok, %{changed: true}} =
               call(admin, %{
                 "action" => "set_component_policy",
                 "entry_id" => entry.id,
                 "component_policy" => "shipped"
               })

      widening = %{
        "action" => "set_component_policy",
        "entry_id" => entry.id,
        "component_policy" => "any"
      }

      assert {:error,
              {:confirmation_required, %{operation: "instance_entry.set_component_policy"}}} =
               call(admin, widening)

      assert {:ok, %{changed: true}} = TestContext.confirming(admin, &call(&1, widening))

      assert {:ok, %{status: "revoked", affected: []}} =
               call(admin, %{"action" => "revoke", "entry_id" => entry.id})

      assert {:ok, %{status: "deleted", affected: []}} =
               call(admin, %{"action" => "delete", "entry_id" => entry.id})

      assert {:ok, %{entries: []}} = call(admin, %{"action" => "list"})

      assert {:error, :not_found} =
               call(admin, %{"action" => "set_caps", "entry_id" => entry.id, "person_daily" => 1})
    end

    test "rotate and rebind answer through the gate", %{admin: admin} do
      entry = create!(admin)

      rotate = %{
        "action" => "rotate",
        "entry_id" => entry.id,
        "fields" => %{"API_KEY" => "sk-rotated"},
        "expected_payload_rev" => 0
      }

      assert {:error, {:confirmation_required, %{operation: "instance_entry.rotate"}}} =
               call(admin, rotate)

      assert {:ok, %{status: "rotated", payload_rev: 1}} =
               TestContext.confirming(admin, &call(&1, rotate))

      assert {:ok, %{status: "rebound", affected: []}} =
               call(admin, %{
                 "action" => "rebind",
                 "entry_id" => entry.id,
                 "destination" => %{@destination | "paths" => ["/v1/models"]}
               })

      assert [%{destination: stored}] = entries()
      assert stored =~ ~s("paths":["/v1/models"])
    end
  end
end
