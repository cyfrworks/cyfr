# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SharesTest do
  @moduledoc """
  Sharing a key (`Sanctum.Shares`): the owner's verbs from their own
  athanor and the confirmations they ask, the caps and the usage the
  owner reads, discovery of a share by an audience read at use and by the
  standing of the person and of the owner, and the one resolution of an
  attached request, which refuses in its order and counts a use and
  unseals the owner's entry, under the owner's athanor, only once every
  check before it passed. Every write announces itself once; a refused or
  unchanged write announces nothing.
  """

  # The company sign-in's settings are the application's environment, and
  # the cases attach to the shares' own announcements.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Context
  alias Sanctum.Shares
  alias Sanctum.Tenancy.{Athanors, Members, Users}
  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.TestContext

  @secret "sk-market-material"
  @destination %{"hosts" => ["api.example.com"], "methods" => ["GET"], "paths" => ["/v1/"]}
  @inside "https://api.example.com/v1/quotes"
  @take {:field, "MARKET_KEY", "KEY"}
  @source "catalyst:local.stock-watcher"
  @issuer "https://idp.example.com"
  @oidc ~s(["oidc","https://idp.example.com","cid"])
  @everyone %{audience: "everyone", group_id: nil}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    test = self()
    handler = "shares-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach_many(
        handler,
        for(kind <- Prima.ShareKinds.all(), do: [:cyfr, :sanctum, :share, kind]),
        fn [:cyfr, :sanctum, :share, kind], _measurements, metadata, _config ->
          send(test, {:share, kind, metadata})
        end,
        nil
      )

    {:ok, terry: person!("Terry"), alice: person!("Alice")}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  # A person signed in under the display name `name`, in their own
  # athanor: the context a session of theirs carries there.
  defp person!(name) do
    n = uniq()

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "local|local|shares-#{n}", provider: "local", name: name})

    Context.build(
      user_id: user.id,
      provider: "local",
      namespace: "shares#{n}",
      athanor_id: Sanctum.Test.People.athanor!(user).id,
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # A group `creator` made, with `members` seated in it by them.
  defp group!(creator, members \\ []) do
    {:ok, group} = Athanors.create_group(creator.user_id, "Traders #{uniq()}")

    for member <- members,
        do: {:ok, :added} = Members.add(group, [user_id: member.user_id], creator.user_id)

    group
  end

  # An attach-only key of the owner's own athanor whose destination names
  # its methods and paths, made through the vault; answers its row.
  defp key!(owner, over \\ %{}) do
    {:ok, view} =
      TestContext.create_vault(
        owner,
        Map.merge(
          %{
            name: "market-#{uniq()}",
            kind: "api_key",
            provider_hint: "example.com",
            fields: %{"KEY" => @secret},
            destination: @destination
          },
          over
        )
      )

    {:ok, entry} = Arca.VaultStorage.get(Context.actor(owner), view.id)
    entry
  end

  # The owner shares `entry` with the audience `over` names, everyone
  # unless it says otherwise, under the proof the creation asks. The one
  # announcement the creation makes is taken here.
  defp share!(owner, entry, over \\ %{}) do
    params = Map.merge(%{entry_id: entry.id, audience: "everyone"}, over)
    {:ok, share} = TestContext.confirming(owner, &Shares.create(&1, params))
    id = share.id
    assert_received {:share, :created, %{share_id: ^id}}
    share
  end

  defp revoke!(owner, share) do
    {:ok, _blocked} = Shares.revoke(owner, share.id)
    id = share.id
    assert_received {:share, :revoked, %{share_id: ^id}}
    :ok
  end

  defp digest!(entry) do
    {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)
    digest
  end

  defp request(url \\ @inside, method \\ "GET"), do: %{uri: URI.parse(url), method: method}

  defp resolve(ctx, share, digest, request \\ request()),
    do: Shares.resolve(ctx, share.id, digest, request, @take)

  # The share's day rows as its owner's athanor holds them, over today and
  # yesterday, so a case that crosses midnight still reads its own.
  defp usage!(owner, share) do
    {:ok, usage} = Arca.ShareUsage.usage(Context.actor(owner), share.id, 2)
    usage
  end

  # Each person's count of the share, and its total, over the same days.
  defp counts(owner, share) do
    %{people: people, totals: totals} = usage!(owner, share)

    by_person =
      Enum.reduce(people, %{}, fn row, acc ->
        Map.update(acc, row.user_id, row.count, &(&1 + row.count))
      end)

    %{people: by_person, total: totals |> Enum.map(& &1.count) |> Enum.sum()}
  end

  defp last_used(owner, entry) do
    {:ok, row} = Arca.VaultStorage.get(Context.actor(owner), entry.id)
    row.last_used_at
  end

  # The entry's last use cleared, so the next unseal shows.
  defp forget_use!(entry) do
    {1, _} =
      Arca.Repo.update_all(from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
        set: [last_used_at: nil]
      )

    :ok
  end

  # What a refusal leaves: no day row of the share, and the source never
  # unsealed, so its last use is still unset.
  defp untouched!(owner, share, entry) do
    assert usage!(owner, share) == %{people: [], totals: []}
    assert last_used(owner, entry) == nil
  end

  # A profile of the recipient whose head binds `share` at `digest`: their
  # grant, in their own athanor. Answers the profile's id.
  defp grant!(recipient, share, digest) do
    profile_id = "prof-share-#{uniq()}"
    key = Prima.Authority.Blob.binding_key(@source, Prima.Authority.Blob.ingress_key(), nil)

    :ok =
      ConsentFixtures.seed_head!(
        recipient,
        %{id: profile_id, source_ref: @source, kind: :owner, label: profile_id},
        %{
          id: Prima.UUID7.generate_id("cons"),
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape-#{profile_id}",
          commit_digest: "sha256:commit-#{profile_id}",
          resolved_policy: "{}",
          activation: %{},
          vault_refs: [
            %{
              binding_key: key,
              share_id: share.id,
              binding_digest: digest,
              admitted: %{audience: share.audience, group_id: share.group_id}
            }
          ]
        }
      )

    profile_id
  end

  defp profile_status(ctx, profile_id) do
    {:ok, profile} = Arca.ProfileStorage.get(Context.actor(ctx), profile_id)
    profile.status
  end

  defp stored_share(owner, share) do
    {:ok, row} = Arca.Shares.get(Context.actor(owner), share.id)
    row
  end

  defp caps(owner, share) do
    row = stored_share(owner, share)
    {row.person_daily, row.total_daily}
  end

  # The person denied through the transition the door's deny runs.
  defp deny!(ctx) do
    {:ok, user} = Users.get(ctx.user_id)
    {:ok, _denied} = Users.deny(user)
    :ok
  end

  defp confirmation!(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id))
    row
  end

  # The company sign-in this CYFR requires under `mode`, through the
  # issuer and client a binding names; every setting's restore is
  # registered before it changes.
  defp require_company_login!(mode, days) do
    Prima.Test.Env.put_app_env(:sanctum, :oidc_issuer, @issuer)

    Prima.Test.Env.put_app_env(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc, issuer: :cyfr_oidc, client_id: "cid", client_secret: "csec"}
      ]
    )

    Prima.Test.Env.put_app_env(:sanctum, :company_login, %{mode: mode, days: days, issuer: :oidc})
  end

  # The person's company sign-in given now: a first one, or a renewal.
  defp company_sign_in!(ctx) do
    {:ok, _bound_or_refreshed} =
      Arca.Test.CompanyLogin.bind(ctx.user_id, @oidc, "sub-" <> ctx.user_id)

    :ok
  end

  # The person's company sign-in given `seconds` ago.
  defp lapse!(ctx, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)
    user_id = ctx.user_id

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.CompanyAuthorization, where: c.user_id == ^user_id),
        set: [authorized_at: at]
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # resolve/5
  # ---------------------------------------------------------------------------

  describe "resolve/5" do
    test "answers the one field the projection maps, counts one use for the person and the " <>
           "total, and marks the entry used",
         %{terry: terry, alice: alice} do
      entry = key!(terry, %{fields: %{"KEY" => @secret, "ORG" => "org-1"}})
      share = share!(terry, entry)
      assert last_used(terry, entry) == nil

      assert {:ok, @secret} = resolve(alice, share, digest!(entry))

      assert counts(terry, share) == %{people: %{alice.user_id => 1}, total: 1}
      assert %DateTime{} = last_used(terry, entry)

      # Another projection reads another field, and one the material lacks
      # is refused by the component's own name.
      assert {:ok, "org-1"} =
               Shares.resolve(alice, share.id, digest!(entry), request(), {:field, "ORG", "ORG"})

      assert {:error, {:missing_field, "SECRET"}} =
               Shares.resolve(alice, share.id, digest!(entry), request(), {:field, "SECRET", "X"})
    end

    # The material is the owner's sealed document, cut short: it opens and
    # does not decode. The refusal is this module's own and carries none
    # of what opened, the field the projection maps or any other.
    test "material that opens and does not decode is refused unseal_failed, carrying none of " <>
           "it, and the use stands counted for the person",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      plaintext = ~s({"v":3,"fields":{"KEY":"#{@secret}","OTHER":"sk-unmapped-canary")
      aad = Sanctum.CipherAAD.vault_entry(terry.athanor_id, entry.id, entry.provider_hint)
      {:ok, sealed} = Sanctum.Cipher.encrypt(plaintext, aad)

      {1, _} =
        Arca.Repo.update_all(
          from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
          set: [sealed_payload: sealed]
        )

      assert {:error, :unseal_failed} = refusal = resolve(alice, share, digest!(entry))
      refute inspect(refusal) =~ "sk-"
      refute inspect(refusal) =~ plaintext
      assert counts(terry, share) == %{people: %{alice.user_id => 1}, total: 1}
      assert last_used(terry, entry) == nil
    end

    test "a person who does not stand is refused, with nothing counted or unsealed",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)

      assert {:error, :anonymous_denied} =
               resolve(%{alice | anonymous: true}, share, digest!(entry))

      :ok = deny!(alice)

      assert {:error, :denied} = resolve(alice, share, digest!(entry))
      untouched!(terry, share, entry)
    end

    test "a share revoked, absent, to a group the person is not in, or their own is not " <>
           "offered, with nothing counted or unsealed",
         %{terry: terry, alice: alice} do
      traders = group!(terry)
      grouped = key!(terry)
      to_traders = share!(terry, grouped, %{audience: "group", group_id: traders.id})
      revoked_entry = key!(terry)
      revoked = share!(terry, revoked_entry)
      :ok = revoke!(terry, revoked)
      own_entry = key!(terry)
      own = share!(terry, own_entry)

      for {ctx, share, entry} <- [
            {alice, revoked, revoked_entry},
            {alice, to_traders, grouped},
            {terry, own, own_entry}
          ] do
        assert {:error, :not_offered} = resolve(ctx, share, digest!(entry)), share.id
        untouched!(terry, share, entry)
      end

      absent = %{id: Prima.UUID7.generate_id("shr")}
      assert {:error, :not_offered} = resolve(alice, absent, digest!(grouped))
      assert last_used(terry, grouped) == nil
    end

    test "a source no longer active is refused with its status, with nothing counted or unsealed",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      {:ok, _} = Arca.VaultStorage.set_status(Context.actor(terry), entry.id, "needs_reauth")

      assert {:error, {:entry_unavailable, "needs_reauth"}} =
               resolve(alice, share, digest!(entry))

      untouched!(terry, share, entry)
    end

    test "a digest other than the one the consent approved is stale, with nothing counted or " <>
           "unsealed",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)

      assert {:error, :binding_went_stale} = resolve(alice, share, "sha256:approved-elsewhere")
      untouched!(terry, share, entry)
    end

    test "a request off the destination is refused by scheme, host, port, method or path, " <>
           "with nothing counted or unsealed",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)

      for {url, method} <- [
            {"http://api.example.com/v1/quotes", "GET"},
            {"https://other.example.com/v1/quotes", "GET"},
            {"https://api.example.com:8443/v1/quotes", "GET"},
            {"https://api.example.com/v1/quotes", "POST"},
            {"https://api.example.com/v2/quotes", "GET"}
          ] do
        assert {:error, :destination_mismatch} =
                 resolve(alice, share, digest!(entry), request(url, method)),
               "#{method} #{url}"
      end

      untouched!(terry, share, entry)
    end

    test "a cap that is reached refuses with the next midnight, with nothing more counted or " <>
           "unsealed",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry, %{person_daily: 1})

      assert {:ok, @secret} = resolve(alice, share, digest!(entry))
      :ok = forget_use!(entry)

      assert {:error, {:connection_cap, %DateTime{} = reset_at}} =
               resolve(alice, share, digest!(entry))

      assert reset_at.time_zone == "Etc/UTC"
      assert DateTime.to_time(reset_at) == ~T[00:00:00.000000]
      assert DateTime.compare(reset_at, DateTime.utc_now()) == :gt
      assert counts(terry, share) == %{people: %{alice.user_id => 1}, total: 1}
      assert last_used(terry, entry) == nil
    end

    test "the first check that refuses answers, whatever a later one would",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry, %{person_daily: 0})
      off = request("https://other.example.com/v1/quotes")

      assert {:error, {:connection_cap, _}} = resolve(alice, share, digest!(entry))
      assert {:error, :destination_mismatch} = resolve(alice, share, digest!(entry), off)
      assert {:error, :binding_went_stale} = resolve(alice, share, "sha256:elsewhere", off)

      {:ok, _} = Arca.VaultStorage.set_status(Context.actor(terry), entry.id, "needs_reauth")

      assert {:error, {:entry_unavailable, "needs_reauth"}} =
               resolve(alice, share, "sha256:elsewhere", off)

      assert {:error, :not_offered} = resolve(terry, share, "sha256:elsewhere", off)
      untouched!(terry, share, entry)
    end
  end

  # ---------------------------------------------------------------------------
  # The caps
  # ---------------------------------------------------------------------------

  describe "the caps" do
    test "absent caps are no limit: every use is admitted, and each is counted",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      entry = key!(terry)
      share = share!(terry, entry)
      assert caps(terry, share) == {nil, nil}

      for _ <- 1..5, do: assert({:ok, @secret} = resolve(alice, share, digest!(entry)))
      for _ <- 1..3, do: assert({:ok, @secret} = resolve(bob, share, digest!(entry)))

      assert counts(terry, share) == %{
               people: %{alice.user_id => 5, bob.user_id => 3},
               total: 8
             }
    end

    test "a cap of 0, per person or in total, admits no use and counts nothing",
         %{terry: terry, alice: alice} do
      for cap <- [%{person_daily: 0}, %{total_daily: 0}] do
        entry = key!(terry)
        share = share!(terry, entry, cap)

        assert {:error, {:connection_cap, %DateTime{}}} = resolve(alice, share, digest!(entry)),
               inspect(cap)

        untouched!(terry, share, entry)
      end
    end

    test "a cap per person of N admits N uses a day for each person, one apart from another",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      entry = key!(terry)
      share = share!(terry, entry, %{person_daily: 2})

      for _ <- 1..2, do: assert({:ok, @secret} = resolve(alice, share, digest!(entry)))
      assert {:error, {:connection_cap, _}} = resolve(alice, share, digest!(entry))

      for _ <- 1..2, do: assert({:ok, @secret} = resolve(bob, share, digest!(entry)))
      assert {:error, {:connection_cap, _}} = resolve(bob, share, digest!(entry))

      assert counts(terry, share) == %{
               people: %{alice.user_id => 2, bob.user_id => 2},
               total: 4
             }
    end

    test "a total cap of N admits N uses a day between everyone, and holds beside a person's",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      entry = key!(terry)
      share = share!(terry, entry, %{person_daily: 2, total_daily: 3})

      for _ <- 1..2, do: assert({:ok, @secret} = resolve(alice, share, digest!(entry)))

      # Alice's own cap refuses her; the total still admits Bob, once.
      assert {:error, {:connection_cap, _}} = resolve(alice, share, digest!(entry))
      assert {:ok, @secret} = resolve(bob, share, digest!(entry))
      assert {:error, {:connection_cap, _}} = resolve(bob, share, digest!(entry))

      assert counts(terry, share) == %{
               people: %{alice.user_id => 2, bob.user_id => 1},
               total: 3
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Standing
  # ---------------------------------------------------------------------------

  describe "the owner's standing" do
    test "while the owner's company sign-in has lapsed their share is refused and offered to " <>
           "no one, with nothing written, and it resumes when they sign in again",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      id = share.id
      digest = digest!(entry)

      require_company_login!(:renew, 30)
      :ok = company_sign_in!(terry)
      :ok = company_sign_in!(alice)

      assert {:ok, @secret} = resolve(alice, share, digest)
      assert {:ok, [%{id: ^id}]} = Shares.offered(alice)
      before = stored_share(terry, share)
      :ok = forget_use!(entry)

      :ok = lapse!(terry, 31 * 86_400)

      assert {:error, :owner_not_standing} = Shares.binding(alice, share.id)
      assert {:error, :owner_not_standing} = resolve(alice, share, digest)
      assert {:ok, []} = Shares.offered(alice)
      assert counts(terry, share) == %{people: %{alice.user_id => 1}, total: 1}
      assert last_used(terry, entry) == nil
      assert stored_share(terry, share) == before
      refute_received {:share, _, _}

      :ok = company_sign_in!(terry)

      assert {:ok, %{id: ^id, owner: "Terry"}} = Shares.binding(alice, share.id)
      assert {:ok, @secret} = resolve(alice, share, digest)
      assert counts(terry, share) == %{people: %{alice.user_id => 2}, total: 2}

      # The recipient's own lapse refuses them, before the share is read.
      :ok = lapse!(alice, 31 * 86_400)
      assert {:error, :denied} = resolve(alice, share, digest)
      assert {:error, :denied} = Shares.binding(alice, share.id)
      assert counts(terry, share) == %{people: %{alice.user_id => 2}, total: 2}
    end

    test "a denied owner's shares are revoked with them, so none is offered any more",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      :ok = deny!(terry)

      assert stored_share(terry, share).status == "revoked"
      assert {:error, :not_offered} = Shares.binding(alice, share.id)
      assert {:error, :not_offered} = resolve(alice, share, digest!(entry))
      assert {:ok, []} = Shares.offered(alice)
      untouched!(terry, share, entry)
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  describe "discovery" do
    test "a member of the group is offered the share by its owner's name; leaving ends it and " <>
           "joining begins it, with nothing written to the share",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      traders = group!(terry, [alice])
      entry = key!(terry)
      share = share!(terry, entry, %{audience: "group", group_id: traders.id})
      id = share.id

      assert {:ok, %{id: ^id, owner: "Terry"} = view} = Shares.binding(alice, share.id)
      assert {:ok, [^view]} = Shares.offered(alice)
      assert {:error, :not_offered} = Shares.binding(bob, share.id)
      assert {:ok, []} = Shares.offered(bob)
      before = stored_share(terry, share)

      :ok = Members.remove_member(traders, user_id: alice.user_id)

      assert {:error, :not_offered} = Shares.binding(alice, share.id)
      assert {:ok, []} = Shares.offered(alice)
      assert {:error, :not_offered} = resolve(alice, share, digest!(entry))
      untouched!(terry, share, entry)

      {:ok, :added} = Members.add(traders, [user_id: bob.user_id], terry.user_id)

      assert {:ok, [%{id: ^id, owner: "Terry"}]} = Shares.offered(bob)
      assert stored_share(terry, share) == before
    end

    test "a share to everyone is offered to every active person and never to its owner",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      share = share!(terry, key!(terry))
      id = share.id

      for ctx <- [alice, bob] do
        assert {:ok, [%{id: ^id, owner: "Terry"}]} = Shares.offered(ctx)
        assert {:ok, %{id: ^id}} = Shares.binding(ctx, share.id)
      end

      assert {:ok, []} = Shares.offered(terry)
      assert {:error, :not_offered} = Shares.binding(terry, share.id)

      :ok = deny!(bob)
      assert {:error, :denied} = Shares.offered(bob)
      assert {:error, :denied} = Shares.binding(bob, share.id)
    end

    test "binding/2 answers the source's facts and the digest derived from them, never a name " <>
           "or material",
         %{terry: terry, alice: alice} do
      entry = key!(terry, %{fields: %{"KEY" => @secret, "ORG" => "org-1"}})
      share = share!(terry, entry)
      derived = digest!(entry)

      # The stored digest is a cache: a column that drifted is not what a
      # consent is held to.
      {1, _} =
        Arca.Repo.update_all(from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
          set: [binding_digest: "sha256:drifted-cache"]
        )

      assert {:ok, view} = Shares.binding(alice, share.id)

      assert view == %{
               id: share.id,
               owner: "Terry",
               audience: "everyone",
               group_id: nil,
               kind: "api_key",
               provider_hint: "example.com",
               field_names: ["KEY", "ORG"],
               destination: Jason.decode!(entry.destination),
               binding_digest: derived,
               status: "active",
               attach_only: true
             }

      refute inspect(view) =~ entry.name
      refute inspect(view) =~ @secret
      assert {:ok, [^view]} = Shares.offered(alice)
      assert last_used(terry, entry) == nil
    end

    test "offered_with_use answers each share with the person's own count today, and no one " <>
           "else's",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      entry = key!(terry)
      share = share!(terry, entry)

      for _ <- 1..2, do: {:ok, @secret} = resolve(alice, share, digest!(entry))
      {:ok, @secret} = resolve(bob, share, digest!(entry))

      {:ok, view} = Shares.binding(alice, share.id)
      assert {:ok, [Map.put(view, :used_today, 2)]} == Shares.offered_with_use(alice)
      assert {:ok, [Map.put(view, :used_today, 1)]} == Shares.offered_with_use(bob)
    end

    test "an anonymous caller, and one no person row names, is offered nothing and binds and " <>
           "resolves nothing",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      anonymous = %{alice | anonymous: true}
      stranger = %{alice | user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix())}

      for {ctx, refusal} <- [{anonymous, :anonymous_denied}, {stranger, :denied}] do
        assert {:error, ^refusal} = Shares.offered(ctx)
        assert {:error, ^refusal} = Shares.offered_with_use(ctx)
        assert {:error, ^refusal} = Shares.binding(ctx, share.id)
        assert {:error, ^refusal} = resolve(ctx, share, digest!(entry))
      end

      untouched!(terry, share, entry)
    end
  end

  describe "binding_facts/1" do
    test "answers an active share's source facts, naming no person, and refuses a revoked or " <>
           "absent share",
         %{terry: terry} do
      entry = key!(terry, %{fields: %{"KEY" => @secret, "ORG" => "org-1"}})
      share = share!(terry, entry)

      assert Shares.binding_facts(share.id) ==
               {:ok,
                %{
                  audience: "everyone",
                  group_id: nil,
                  kind: "api_key",
                  provider_hint: "example.com",
                  field_names: ["KEY", "ORG"],
                  status: "active",
                  binding_digest: digest!(entry),
                  attach_only: true
                }}

      :ok = revoke!(terry, share)
      assert {:error, :not_offered} = Shares.binding_facts(share.id)
      assert {:error, :not_offered} = Shares.binding_facts(Prima.UUID7.generate_id("shr"))
    end
  end

  describe "administrator_shares/1" do
    test "the platform administrator's active shares to everyone, newest first: never a " <>
           "member's, a group's, a revoked one or the person's own",
         %{terry: terry} do
      admin = person!("Admin")
      {:ok, _seat} = TestContext.ensure_platform(admin.user_id)
      newcomer = person!("Newcomer")
      staff = group!(admin)

      first = share!(admin, key!(admin))
      second = share!(admin, key!(admin))
      _to_staff = share!(admin, key!(admin), %{audience: "group", group_id: staff.id})
      revoked = share!(admin, key!(admin))
      :ok = revoke!(admin, revoked)
      _members = share!(terry, key!(terry))

      assert {:ok, candidates} = Shares.administrator_shares(newcomer)

      assert Enum.map(candidates, &{&1.id, &1.owner}) == [
               {second.id, "Admin"},
               {first.id, "Admin"}
             ]

      for candidate <- candidates,
          do: assert({:ok, ^candidate} = Shares.binding(newcomer, candidate.id))

      assert {:ok, []} = Shares.administrator_shares(admin)
    end
  end

  # ---------------------------------------------------------------------------
  # The unseal
  # ---------------------------------------------------------------------------

  describe "the unseal" do
    test "runs under the owner's athanor: the recipient's own context never reads the source",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      digest = digest!(entry)

      for entry_id <- [entry.id, share.id] do
        assert {:error, :not_found} =
                 Sanctum.VaultReader.load_and_unseal(alice, %{
                   entry_id: entry_id,
                   binding_digest: digest
                 })
      end

      assert last_used(terry, entry) == nil
      assert {:ok, @secret} = resolve(alice, share, digest)
    end
  end

  # ---------------------------------------------------------------------------
  # A damaged source
  # ---------------------------------------------------------------------------

  describe "a damaged source" do
    # No write makes one: a share is made only of an attach-only entry of a
    # shareable kind, and a shared entry is never rebound disclosed. So the
    # row is damaged in the store itself.
    test "of a kind no share offers, or disclosed, is offered to no one and refused where it " <>
           "would be bound or resolved, with nothing counted or unsealed",
         %{terry: terry, alice: alice} do
      for damage <- [[kind: "oauth"], [attach_only: false]] do
        entry = key!(terry)
        share = share!(terry, entry)
        digest = digest!(entry)

        {1, _} =
          Arca.Repo.update_all(from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
            set: damage
          )

        assert {:ok, []} = Shares.offered(alice), inspect(damage)
        assert {:error, :corrupt} = Shares.binding(alice, share.id)
        assert {:error, :corrupt} = Shares.binding_facts(share.id)
        assert {:error, :corrupt} = resolve(alice, share, digest)
        untouched!(terry, share, entry)
      end
    end

    @tag :capture_log
    test "a field-name column that does not decode reads as none, and a use under the digest " <>
           "approved before is stale",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      approved = digest!(entry)
      assert {:ok, %{field_names: ["KEY"]}} = Shares.binding(alice, share.id)

      for damaged <- ["not json", ~s({"KEY":true}), ~s("KEY")] do
        {1, _} =
          Arca.Repo.update_all(from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
            set: [field_names: damaged]
          )

        assert {:ok, %{field_names: [], binding_digest: moved}} = Shares.binding(alice, share.id),
               damaged

        refute moved == approved
        assert {:ok, [%{field_names: []}]} = Shares.offered(alice)
        assert {:ok, %{field_names: []}} = Shares.binding_facts(share.id)
        assert {:error, :binding_went_stale} = resolve(alice, share, approved)
      end

      untouched!(terry, share, entry)
    end
  end

  # ---------------------------------------------------------------------------
  # The owner's verbs
  # ---------------------------------------------------------------------------

  describe "the owner's verbs" do
    test "are made from the owner's own athanor alone, with nothing written",
         %{terry: terry, alice: alice} do
      traders = group!(terry, [alice])
      entry = key!(terry)
      share = share!(terry, entry)
      in_group = %{terry | athanor_id: traders.id}
      ids = %{share_id: share.id}

      for answer <- [
            Shares.create(in_group, %{entry_id: entry.id, audience: "everyone"}),
            Shares.list(in_group),
            Shares.usage(in_group, share.id, 1),
            Shares.set_audience(
              in_group,
              Map.merge(ids, %{audience: "everyone", expected: @everyone})
            ),
            Shares.set_caps(in_group, Map.put(ids, :person_daily, 1)),
            Shares.revoke(in_group, share.id)
          ] do
        assert answer == {:error, :not_own_athanor}
      end

      assert {:ok, [%{id: id, status: "active", person_daily: nil}]} = Shares.list(terry)
      assert id == share.id
      refute_received {:share, _, _}
    end

    test "a creation asks the credential_sharing confirmation, writes nothing without its " <>
           "proof, and the share exists with it",
         %{terry: terry} do
      entry = key!(terry)
      params = %{entry_id: entry.id, audience: "everyone", person_daily: 5}

      assert {:error, {:confirmation_required, %{id: id, operation: "share.create"}}} =
               Shares.create(terry, params)

      record = confirmation!(terry, id)
      assert {record.operation, record.action} == {"share.create", "credential_sharing"}
      assert {:ok, []} = Shares.list(terry)
      refute_received {:share, _, _}

      assert {:ok, share} = TestContext.confirming(terry, &Shares.create(&1, params))
      assert {:ok, [listed]} = Shares.list(terry)

      assert listed == %{
               id: share.id,
               entry_id: entry.id,
               audience: "everyone",
               group_id: nil,
               person_daily: 5,
               total_daily: nil,
               status: "active",
               used_today: 0,
               created_at: listed.created_at
             }

      assert %DateTime{} = listed.created_at
    end

    test "an entry no share may offer, and a second share to one audience, are refused before " <>
           "any confirmation is asked, with nothing written",
         %{terry: terry, alice: alice} do
      disclosed = key!(terry, %{disclose: true})

      oauth =
        key!(terry, %{
          kind: "oauth",
          provider_hint: "google",
          fields: %{},
          oauth: %{"access_token" => "ya29.share"},
          oauth_scopes: ["scope.a"]
        })

      incomplete =
        key!(terry, %{destination: %{"hosts" => ["api.example.com"], "methods" => ["GET"]}})

      shared = key!(terry)
      first = share!(terry, shared)

      for {entry, refusal} <- [
            {disclosed, :disclosed_not_shareable},
            {oauth, :kind_not_shareable},
            {incomplete, :destination_incomplete},
            {shared, :already_shared}
          ] do
        assert {:error, ^refusal} =
                 Shares.create(terry, %{entry_id: entry.id, audience: "everyone"}),
               inspect(refusal)
      end

      # An entry the owner's athanor does not hold is not found, as early.
      for entry_id <- [key!(alice).id, Prima.UUID7.generate_id("vlt")] do
        assert {:error, :not_found} =
                 Shares.create(terry, %{entry_id: entry_id, audience: "everyone"})
      end

      assert {:ok, [%{id: id}]} = Shares.list(terry)
      assert id == first.id
      refute_received {:share, _, _}
    end

    test "set_audience compares the audience its caller saw, and a widening alone asks the " <>
           "confirmation",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      traders = group!(terry, [alice])
      desk = group!(terry, [bob])
      share = share!(terry, key!(terry), %{audience: "group", group_id: traders.id})
      id = share.id
      to_traders = %{audience: "group", group_id: traders.id}
      to_desk = %{audience: "group", group_id: desk.id}

      move = fn ctx, to, expected ->
        Shares.set_audience(ctx, Map.merge(%{share_id: id, expected: expected}, to))
      end

      # The caller saw another audience: a conflict, nothing asked or written.
      assert {:error, {:conflict, _sentence}} = move.(terry, @everyone, @everyone)
      assert {:ok, :unchanged} = move.(terry, to_traders, to_traders)
      refute_received {:share, _, _}

      # Group to everyone, and group to another group, widen: each asks.
      for to <- [@everyone, to_desk] do
        assert {:error, {:confirmation_required, %{id: secret, operation: "share.set_audience"}}} =
                 move.(terry, to, to_traders)

        assert confirmation!(terry, secret).action == "credential_sharing"
      end

      assert %{audience: "group", group_id: group_id} = stored_share(terry, share)
      assert group_id == traders.id
      refute_received {:share, _, _}

      assert {:ok, :changed} = TestContext.confirming(terry, &move.(&1, to_desk, to_traders))
      assert_received {:share, :audience, %{share_id: ^id}}
      assert {:ok, [%{id: ^id}]} = Shares.offered(bob)
      assert {:ok, []} = Shares.offered(alice)

      assert {:ok, :changed} = TestContext.confirming(terry, &move.(&1, @everyone, to_desk))
      assert_received {:share, :audience, %{share_id: ^id}}
      assert {:ok, [%{id: ^id}]} = Shares.offered(alice)

      # Everyone to a group narrows: the session alone.
      assert {:ok, :changed} = move.(terry, to_traders, @everyone)
      assert_received {:share, :audience, %{share_id: ^id}}
      assert {:ok, []} = Shares.offered(bob)
      assert {:ok, [%{id: ^id}]} = Shares.offered(alice)
    end

    # What a person reads before proving a sharing is the sharing itself,
    # never a value: the entry it offers or the share it moves, the
    # audience it becomes and the caps it sets.
    test "a credential_sharing confirmation's preview names the sharing it confirms, never a " <>
           "value or a person",
         %{terry: terry, alice: alice} do
      traders = group!(terry, [alice])
      entry = key!(terry)
      to_traders = %{audience: "group", group_id: traders.id}

      assert {:error, {:confirmation_required, %{id: created}}} =
               Shares.create(terry, Map.merge(%{entry_id: entry.id, person_daily: 5}, to_traders))

      share = share!(terry, key!(terry), to_traders)

      assert {:error, {:confirmation_required, %{id: widened}}} =
               Shares.set_audience(terry, %{
                 share_id: share.id,
                 audience: "everyone",
                 group_id: nil,
                 expected: to_traders
               })

      for {secret, resource, details} <- [
            {created, entry.name,
             %{"audience" => "group", "person_daily" => "5", "total_daily" => "no limit"}},
            {widened, share.id, %{"audience" => "everyone"}}
          ] do
        record = confirmation!(terry, secret)
        assert record.action == "credential_sharing"
        preview = Jason.decode!(record.preview)
        assert {preview["resource"], preview["details"]} == {resource, details}
        refute record.preview =~ @secret
        refute record.preview =~ alice.user_id
      end

      refute_received {:share, _, _}
    end

    test "a widening proven over one audience is a conflict at its repeat once the audience " <>
           "moved, with nothing more written and the proof not spent",
         %{terry: terry, alice: alice} do
      traders = group!(terry, [alice])
      desk = group!(terry)
      to_traders = %{audience: "group", group_id: traders.id}
      to_desk = %{audience: "group", group_id: desk.id}
      share = share!(terry, key!(terry), to_traders)
      widening = %{share_id: share.id, audience: "everyone", group_id: nil, expected: to_traders}

      # Before the proof's repeat, another of the owner's sessions moves the
      # share to another group. The repeat is the proven request itself,
      # the audience it was decided against included.
      answer =
        TestContext.confirming(terry, fn ctx ->
          if ctx.confirmation_id do
            send(self(), {:proof, ctx.confirmation_id})

            {:ok, _moved} =
              Arca.Shares.set_audience(Context.actor(terry), share.id, to_traders, to_desk)
          end

          Shares.set_audience(ctx, widening)
        end)

      assert {:error, {:conflict, _sentence}} = answer
      assert %{audience: "group", group_id: group_id} = stored_share(terry, share)
      assert group_id == desk.id
      refute_received {:share, :audience, _}

      # The conflict came before the proof was asked for: it is not spent on
      # a change that was not made.
      assert_received {:proof, secret}
      assert confirmation!(terry, secret).state == "confirmed"
    end

    test "set_audience without the audience its caller saw, or with one that does not read, " <>
           "is refused before the share is read, with nothing written",
         %{terry: terry} do
      share = share!(terry, key!(terry))
      absent = Prima.UUID7.generate_id("shr")

      for id <- [share.id, absent],
          expected <- [
            :absent,
            nil,
            "everyone",
            [audience: "everyone", group_id: nil],
            %{},
            %{audience: "anyone", group_id: nil},
            %{audience: "group", group_id: nil},
            %{audience: "everyone", group_id: "ath_other"}
          ] do
        params = %{share_id: id, audience: "everyone", group_id: nil}
        params = if expected == :absent, do: params, else: Map.put(params, :expected, expected)

        assert {:error, :invalid_expected} = Shares.set_audience(terry, params),
               inspect({id, expected})
      end

      assert %{audience: "everyone", group_id: nil} = stored_share(terry, share)
      refute_received {:share, _, _}
    end

    test "set_caps writes both caps together, each absent for no limit",
         %{terry: terry} do
      share = share!(terry, key!(terry))
      id = share.id

      assert {:ok, :changed} =
               Shares.set_caps(terry, %{share_id: id, person_daily: 2, total_daily: 5})

      assert caps(terry, share) == {2, 5}

      assert {:ok, :changed} = Shares.set_caps(terry, %{share_id: id, person_daily: 3})
      assert caps(terry, share) == {3, nil}

      assert {:ok, :unchanged} =
               Shares.set_caps(terry, %{share_id: id, person_daily: 3, total_daily: nil})

      assert {:ok, :changed} = Shares.set_caps(terry, %{share_id: id})
      assert caps(terry, share) == {nil, nil}

      for bad <- [-1, "1", 1.0, Arca.Schemas.Share.max_cap() + 1] do
        assert {:error, :invalid_caps} = Shares.set_caps(terry, %{share_id: id, total_daily: bad})
      end

      assert {:ok, [%{person_daily: nil, total_daily: nil}]} = Shares.list(terry)

      for _ <- 1..3, do: assert_received({:share, :caps, %{share_id: ^id}})
      refute_received {:share, _, _}
    end

    test "a revoke blocks the profile that binds the share in the recipient's athanor, and " <>
           "the next use is refused",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      digest = digest!(entry)
      profile = grant!(alice, share, digest)
      assert {:ok, @secret} = resolve(alice, share, digest)

      assert {:ok, %{affected: affected}} = Shares.revoke(terry, share.id)
      assert affected == [{alice.athanor_id, profile}]
      assert profile_status(alice, profile) == "needs_consent"

      assert {:error, :not_offered} = resolve(alice, share, digest)
      assert counts(terry, share) == %{people: %{alice.user_id => 1}, total: 1}
      assert {:ok, [%{id: id, status: "revoked"}]} = Shares.list(terry)
      assert id == share.id
    end

    test "list shows each share with today's total, and usage names each person who used it " <>
           "with their count",
         %{terry: terry, alice: alice} do
      bob = person!("Bob")
      entry = key!(terry)
      share = share!(terry, entry)
      other = share!(terry, key!(terry))

      for _ <- 1..2, do: {:ok, @secret} = resolve(alice, share, digest!(entry))
      {:ok, @secret} = resolve(bob, share, digest!(entry))

      assert {:ok, listed} = Shares.list(terry)
      assert Enum.map(listed, &{&1.id, &1.used_today}) == [{share.id, 3}, {other.id, 0}]

      assert {:ok, %{people: people, totals: [%{day: day, count: 3}]}} =
               Shares.usage(terry, share.id, 1)

      assert Enum.sort_by(people, & &1.user_id) ==
               Enum.sort_by(
                 [
                   %{user_id: alice.user_id, display_name: "Alice", day: day, count: 2},
                   %{user_id: bob.user_id, display_name: "Bob", day: day, count: 1}
                 ],
                 & &1.user_id
               )

      assert {:ok, %{people: [], totals: []}} = Shares.usage(terry, other.id, 1)
    end

    test "usage refuses days outside the kept window, and a share of another athanor",
         %{terry: terry, alice: alice} do
      share = share!(terry, key!(terry))

      for days <- [0, -1, Arca.ShareUsage.kept_days() + 1, "1", nil] do
        assert {:error, :invalid_days} = Shares.usage(terry, share.id, days), inspect(days)
      end

      assert {:ok, %{people: [], totals: []}} =
               Shares.usage(terry, share.id, Arca.ShareUsage.kept_days())

      assert {:error, :not_found} = Shares.usage(alice, share.id, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # The owner's rebind
  # ---------------------------------------------------------------------------

  describe "the owner's rebind" do
    test "blocks the recipient's profile, and a use under the digest it approved is stale " <>
           "with nothing counted",
         %{terry: terry, alice: alice} do
      entry = key!(terry)
      share = share!(terry, entry)
      approved = digest!(entry)
      profile = grant!(alice, share, approved)
      assert profile_status(alice, profile) == "active"
      before = stored_share(terry, share)

      assert {:ok, %{binding_digest: moved}} =
               TestContext.confirming(
                 terry,
                 &Sanctum.Vault.rebind(&1, %{
                   id: entry.id,
                   destination: %{
                     "hosts" => ["api.example.com"],
                     "methods" => ["GET"],
                     "paths" => ["/v2/"]
                   }
                 })
               )

      assert moved != approved
      assert profile_status(alice, profile) == "needs_consent"

      for url <- [@inside, "https://api.example.com/v2/quotes"] do
        assert {:error, :binding_went_stale} = resolve(alice, share, approved, request(url))
      end

      untouched!(terry, share, entry)
      assert stored_share(terry, share) == before
      assert {:ok, %{binding_digest: ^moved}} = Shares.binding(alice, share.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Announcements
  # ---------------------------------------------------------------------------

  describe "announcements" do
    test "each write announces once its share, its kind and who acted; a refused or " <>
           "unchanged write announces nothing",
         %{terry: terry, alice: alice} do
      traders = group!(terry, [alice])
      entry = key!(terry)
      params = %{entry_id: entry.id, audience: "everyone"}
      {:ok, share} = TestContext.confirming(terry, &Shares.create(&1, params))
      id = share.id

      assert {:ok, :changed} = Shares.set_caps(terry, %{share_id: id, person_daily: 1})

      assert {:ok, :changed} =
               Shares.set_audience(terry, %{
                 share_id: id,
                 audience: "group",
                 group_id: traders.id,
                 expected: @everyone
               })

      assert {:ok, _blocked} = Shares.revoke(terry, id)

      for kind <- [:created, :caps, :audience, :revoked] do
        assert_received {:share, ^kind, metadata}
        assert metadata == %{share_id: id, kind: kind, user_id: terry.user_id}
      end

      refute_received {:share, _, _}

      # A refused or an unchanged write says nothing.
      live_entry = key!(terry)
      live = share!(terry, live_entry)
      seen = %{share_id: live.id, audience: "everyone", group_id: nil, expected: @everyone}
      to_traders = %{audience: "group", group_id: traders.id}

      assert {:error, :already_shared} =
               TestContext.confirming(
                 terry,
                 &Shares.create(&1, %{params | entry_id: live_entry.id})
               )

      assert {:error, {:confirmation_required, _}} =
               Shares.create(terry, %{params | entry_id: key!(terry).id})

      assert {:ok, :unchanged} = Shares.set_caps(terry, %{share_id: live.id})
      assert {:ok, :unchanged} = Shares.set_audience(terry, seen)
      assert {:error, {:conflict, _}} = Shares.set_audience(terry, %{seen | expected: to_traders})

      assert {:error, {:share_unavailable, "revoked"}} =
               Shares.set_caps(terry, %{share_id: id, person_daily: 2})

      refute_received {:share, _, _}
    end
  end
end
