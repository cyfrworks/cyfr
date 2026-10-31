# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.ShareTest do
  @moduledoc """
  The `share` tool through the gate: what each action declares, on which
  plane each is reached, what the owner's verbs answer, and what the
  people a share is offered to read. Terry shares one of his own
  attach-only entries; Alice sits with him in the Traders group.
  """

  use ExUnit.Case, async: false

  alias Prima.Test.AuthorityFixtures
  alias Sanctum.TestContext

  @reads ~w(list usage offered)
  @writes ~w(create set_audience set_caps revoke)

  @destination %{
    "hosts" => ["api.example.com"],
    "methods" => ["GET"],
    "paths" => ["/v1/"],
    "scheme" => "https"
  }

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    terry = person!("Terry")
    alice = person!("Alice")
    traders = Arca.Test.Shares.group!([terry.user.id, alice.user.id], %{name: "Traders"})

    entry =
      Arca.Test.Shares.entry!(Sanctum.Context.actor(terry.ctx), %{
        field_names: Jason.encode!(["API_KEY"])
      })

    {:ok, terry: terry, alice: alice, traders: traders, entry: entry}
  end

  # A person signed in at this CYFR with their own athanor, and their
  # session's context there.
  defp person!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "local|local|share-#{String.downcase(name)}-#{n}",
        provider: "local",
        name: name
      })

    own = Sanctum.Test.People.athanor!(user)

    %{
      user: user,
      athanor: own,
      ctx: %{TestContext.local(:prism) | user_id: user.id, athanor_id: own.id}
    }
  end

  defp call(ctx, args), do: Sanctum.Gate.call_external("share", ctx, args)

  defp operation(action) do
    {:ok, {_module, tool}} = Sanctum.Catalog.lookup("share")
    Enum.find(tool.operations, &(&1.action == action)) || flunk("share.#{action}")
  end

  # The repeat after the proof is the same request.
  defp share!(owner, entry, over \\ %{}) do
    args =
      Map.merge(%{"action" => "create", "entry_id" => entry.id, "audience" => "everyone"}, over)

    assert {:ok, %{share: share}} = TestContext.confirming(owner.ctx, &call(&1, args))
    share
  end

  defp stored(owner) do
    {:ok, shares} = Arca.Shares.list(Sanctum.Context.actor(owner.ctx))
    shares
  end

  defp leave!(group, person) do
    {:ok, _} =
      Arca.SecurityTransitions.leave_athanor(Prima.Actor.in_athanor(group.id), person.user.id,
        verify: fn _ -> :ok end
      )

    :ok
  end

  # A chain authority whose ingress edge grants exactly `tools`.
  defp granting(tools) do
    source = AuthorityFixtures.formula_ref()

    {:ok, blob} =
      AuthorityFixtures.graph_map()
      |> put_in(["nodes", source, "edges", "@ingress", "tools"], Enum.sort(tools))
      |> Prima.Authority.Blob.parse()

    {:ok, authority} =
      Prima.Authority.root(AuthorityFixtures.profile(), blob,
        ceiling: AuthorityFixtures.ceiling()
      )

    authority
  end

  defp in_chain(ctx, args, authority) do
    lineage =
      ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

    Sanctum.Gate.call_in_chain("share", Sanctum.Context.enter_guest(ctx), args, authority,
      lineage: lineage
    )
  end

  describe "the declaration" do
    test "list, usage and offered are reads on both planes; every write is the owner's, " <>
           "interactive and external alone" do
      for action <- @reads do
        op = operation(action)

        assert {op.kind, op.planes, op.consent, op.scope} ==
                 {:read, [:external, :in_chain], nil, nil}

        assert Sanctum.Catalog.in_chain_reachable?("share", action), action
      end

      for action <- @writes do
        op = operation(action)
        assert {op.planes, op.consent, op.scope} == {[:external], :interactive, nil}, action
        refute Sanctum.Catalog.in_chain_reachable?("share", action), action
      end

      assert operation("list").args == [] and operation("offered").args == []
      assert operation("revoke").kind == :destructive

      # Revoking takes authority away and gives none; nothing else here does.
      assert for(a <- @reads ++ @writes, Sanctum.Catalog.reduces_authority?("share.#{a}"), do: a) ==
               ["revoke"]

      # A read of the owner's own rows carries nothing; another person's
      # names, providers and destinations are outside the athanor.
      assert {operation("list").sources, operation("usage").sources, operation("offered").sources} ==
               {[], [:outside], [:outside]}

      assert Enum.sort(Enum.map(operation("create").args, & &1.name)) ==
               Enum.sort(~w(entry_id audience group_id person_daily total_daily))

      for action <- ~w(create set_caps), name <- ~w(person_daily total_daily) do
        cap = Enum.find(operation(action).args, &(&1.name == name))

        assert {cap.required, cap.nullable, cap.min, cap.max} ==
                 {false, true, 0, Arca.Shares.max_cap()},
               "#{action}.#{name}"
      end

      audience = Enum.find(operation("create").args, &(&1.name == "audience"))
      assert {audience.required, audience.enum} == {true, ~w(everyone group)}

      args = Map.new(operation("set_audience").args, &{&1.name, &1})
      assert Enum.sort(Map.keys(args)) == ~w(audience expected group_id share_id)
      assert {:record, fields} = args["expected"].type
      assert args["expected"].required
      assert Enum.sort(Enum.map(fields, & &1.name)) == ~w(audience group_id)

      days = Enum.find(operation("usage").args, &(&1.name == "days"))
      assert {days.required, days.min, days.max} == {true, 1, Arca.ShareUsage.kept_days()}
    end

    test "an audience or a cap the declaration refuses is refused before a handler, and " <>
           "nothing is written",
         %{terry: terry, entry: entry} do
      for over <- [
            %{"audience" => "anyone"},
            %{"audience" => nil},
            %{"person_daily" => -1},
            %{"total_daily" => "5"},
            %{"person_daily" => 1.5}
          ] do
        args =
          Map.merge(
            %{"action" => "create", "entry_id" => entry.id, "audience" => "everyone"},
            over
          )

        assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
                 call(terry.ctx, args),
               inspect(over)
      end

      assert stored(terry) == []
    end
  end

  describe "the owner" do
    test "creates, lists, caps, moves and revokes a share through the gate, and no answer " <>
           "carries a value",
         %{terry: terry, traders: traders, entry: entry} do
      create = %{
        "action" => "create",
        "entry_id" => entry.id,
        "audience" => "group",
        "group_id" => traders.id,
        "person_daily" => 5
      }

      # Sharing a key offers it to more people: the person confirms it.
      assert {:error, {:confirmation_required, %{operation: "share.create"}}} =
               call(terry.ctx, create)

      assert stored(terry) == []

      assert {:ok, %{share: share} = answer} =
               TestContext.confirming(terry.ctx, &call(&1, create))

      assert "shr_" <> _ = share.id

      assert Map.take(share, [
               :entry_id,
               :audience,
               :group_id,
               :person_daily,
               :total_daily,
               :status
             ]) ==
               %{
                 entry_id: entry.id,
                 audience: "group",
                 group_id: traders.id,
                 person_daily: 5,
                 total_daily: nil,
                 status: "active"
               }

      assert {:ok, %{shares: [listed]} = listing} = call(terry.ctx, %{"action" => "list"})
      assert {listed.id, listed.used_today} == {share.id, 0}

      # Both caps are written: the one omitted is no limit.
      caps = %{"action" => "set_caps", "share_id" => share.id, "total_daily" => 10}
      assert {:ok, %{status: "updated", changed: true}} = call(terry.ctx, caps)
      assert [%{person_daily: nil, total_daily: 10}] = stored(terry)
      assert {:ok, %{changed: false}} = call(terry.ctx, caps)

      # Widening to everyone asks the confirmation; narrowing back does not.
      widen = %{
        "action" => "set_audience",
        "share_id" => share.id,
        "audience" => "everyone",
        "expected" => %{"audience" => "group", "group_id" => traders.id}
      }

      assert {:error, {:confirmation_required, %{operation: "share.set_audience"}}} =
               call(terry.ctx, widen)

      assert {:ok, %{changed: true}} = TestContext.confirming(terry.ctx, &call(&1, widen))
      assert [%{audience: "everyone", group_id: nil}] = stored(terry)

      narrow = %{
        "action" => "set_audience",
        "share_id" => share.id,
        "audience" => "group",
        "group_id" => traders.id,
        "expected" => %{"audience" => "everyone"}
      }

      assert {:ok, %{changed: true}} = call(terry.ctx, narrow)

      # Decided against an audience that moved since: a conflict, and the
      # stored audience stands.
      assert {:error,
              {:conflict, "The audience changed since it was shown, so nothing was saved."}} =
               call(terry.ctx, narrow)

      assert [%{audience: "group"}] = stored(terry)

      assert {:ok, %{status: "revoked", share_id: id} = revoked} =
               call(terry.ctx, %{"action" => "revoke", "share_id" => share.id})

      assert id == share.id
      assert Map.keys(revoked) |> Enum.sort() == [:share_id, :status]
      assert [%{status: "revoked"}] = stored(terry)

      refute inspect([answer, listing, revoked]) =~ "sealed-bytes"
    end

    test "a key is shared, and its shares read, from the person's own athanor alone",
         %{terry: terry, alice: alice, traders: traders, entry: entry} do
      in_group = %{terry.ctx | athanor_id: traders.id}

      for args <- [
            %{"action" => "create", "entry_id" => entry.id, "audience" => "everyone"},
            %{"action" => "list"}
          ] do
        assert {:error, {:invalid_argument, "not_own_athanor: " <> _}} = call(in_group, args),
               args["action"]
      end

      # Alice's own athanor holds no entry of Terry's.
      assert {:error, :not_found} =
               call(alice.ctx, %{
                 "action" => "create",
                 "entry_id" => entry.id,
                 "audience" => "everyone"
               })

      assert stored(terry) == []
    end
  end

  describe "the people a share is offered to" do
    test "Alice, in the group Terry shared with, sees his share with its owner, and after " <>
           "she leaves the group the same read omits it",
         %{terry: terry, alice: alice, traders: traders, entry: entry} do
      share = share!(terry, entry, %{"audience" => "group", "group_id" => traders.id})

      assert {:ok, %{shares: [offer]}} = call(alice.ctx, %{"action" => "offered"})

      assert Map.take(offer, [
               :id,
               :owner,
               :provider_hint,
               :field_names,
               :destination,
               :used_today
             ]) ==
               %{
                 id: share.id,
                 owner: "Terry",
                 provider_hint: "example.com",
                 field_names: ["API_KEY"],
                 destination: @destination,
                 used_today: 0
               }

      refute inspect(offer) =~ "sealed-bytes"
      refute Map.has_key?(offer, :name)

      # A share is never offered to its own owner.
      assert {:ok, %{shares: []}} = call(terry.ctx, %{"action" => "offered"})

      :ok = leave!(traders, alice)
      assert {:ok, %{shares: []}} = call(alice.ctx, %{"action" => "offered"})
    end

    test "Terry's usage names Alice and her count, and Alice reads her own count alone",
         %{terry: terry, alice: alice, entry: entry} do
      share = share!(terry, entry)
      owner = Sanctum.Context.actor(terry.ctx)

      for _ <- 1..2,
          do: assert({:ok, _} = Arca.ShareUsage.claim(owner, share.id, alice.user.id))

      today = DateTime.to_date(Arca.ServerMetaStorage.now!())

      assert {:ok, %{share_id: id, people: people, totals: totals}} =
               call(terry.ctx, %{"action" => "usage", "share_id" => share.id, "days" => 1})

      assert id == share.id

      assert people == [
               %{user_id: alice.user.id, display_name: "Alice", day: today, count: 2}
             ]

      assert totals == [%{day: today, count: 2}]

      assert {:ok, %{shares: [%{id: ^id, used_today: 2}]}} =
               call(alice.ctx, %{"action" => "offered"})

      # Another person's share is not Alice's to read the use of.
      assert {:error, :not_found} =
               call(alice.ctx, %{"action" => "usage", "share_id" => share.id, "days" => 1})
    end

    test "the assistant reads share.offered in a chain and cannot create a share there",
         %{terry: terry, alice: alice, entry: entry} do
      share = share!(terry, entry)
      authority = granting(["share.offered", "share.create"])

      assert {:ok, %{shares: [%{id: id, owner: "Terry"}]}} =
               in_chain(alice.ctx, %{"action" => "offered"}, authority)

      assert id == share.id

      alice_entry = Arca.Test.Shares.entry!(Sanctum.Context.actor(alice.ctx))

      assert {:error, %Prima.Refusal{stage: :admission, message: message}} =
               in_chain(
                 alice.ctx,
                 %{"action" => "create", "entry_id" => alice_entry.id, "audience" => "everyone"},
                 authority
               )

      assert message =~ "not reachable from a running chain"
      assert stored(alice) == []
    end
  end
end
