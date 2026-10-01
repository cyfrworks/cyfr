# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.CyfrDoorTest do
  @moduledoc """
  The `cyfr` door at a relying home, against a scripted directory that
  speaks HTTPS under a test authority on loopback, and the person's own
  home played by the test with their live key.

  A carry is verified under the head read fresh from the directory the
  person's genesis names, before which a carry for another home or a
  genesis that does not hash to its identifier makes no request; the
  challenge is held in the browser's cookie and the browser goes back to
  the carry's signed return URL; the assertion is verified under the
  current live key, for this home, this challenge and this carry, and the
  door judges the identity by its identifier. An admitted person is a
  remote person here, with no key and no athanor of their own; their
  session records the head's `key_epoch` and commits with its login
  receipt, and a retried login resumes it.
  """

  # The resolver's observer, the directory seam, the private-egress
  # listing, the rate counters and the slot are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{PersonIdentity, Session}
  alias Sanctum.Auth.CyfrDoor
  alias Sanctum.Door.Store
  alias Sanctum.Test.DirectoryServer

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.RateLimiter.reset()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)

    on_exit(fn ->
      Prima.RateLimiter.reset()
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
    end)

    directory = DirectoryServer.start!(tls)
    %{directory: directory, home: Sanctum.Person.home()}
  end

  defp identity!(%{directory: directory}),
    do: DirectoryServer.identity!(directory.dir, directory.url)

  defp allow!(identity), do: {:ok, _} = Store.allow("identifier", identity.identifier, nil)

  defp carry(identity, home, opts \\ []),
    do: DirectoryServer.carry_fragment(identity, home, opts)

  defp challenge!(identity, home, opts \\ []) do
    %{fragment: fragment} = carry(identity, home, opts)
    {:ok, held} = CyfrDoor.challenge(fragment)
    held
  end

  defp assertion(identity, held, home, opts \\ []),
    do: DirectoryServer.assertion_fragment(identity, held, home, opts)

  defp sessions(user_id),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id))

  defp person_of(identifier),
    do: Arca.Repo.one(from(p in PersonIdentity, where: p.identifier == ^identifier))

  defp drain, do: DirectoryServer.requests()

  # ---------------------------------------------------------------------------
  # The signing home
  # ---------------------------------------------------------------------------

  describe "signing_home/1" do
    test "sends the person to their home's /carry, naming this home in the fragment",
         %{home: home} do
      assert {:ok, url} = CyfrDoor.signing_home("A.Example")
      assert url == "https://a.example/carry#" <> URI.encode_query(%{"destination" => home})

      # Nothing in the query: a redirect through that home's sign-in keeps
      # the fragment and drops the query.
      assert %URI{query: nil, path: "/carry", fragment: fragment} = URI.parse(url)
      assert URI.decode_query(fragment) == %{"destination" => home}

      assert {:ok, "https://a.example:8443/carry#" <> _} =
               CyfrDoor.signing_home(" https://a.example:8443/some/path ")
    end

    test "refuses no home's address, and this home's own", %{home: home} do
      assert {:error, :invalid_home} = CyfrDoor.signing_home("not a home")
      assert {:error, :invalid_home} = CyfrDoor.signing_home("ftp://a.example")
      assert {:error, :this_home} = CyfrDoor.signing_home(home)
    end
  end

  # ---------------------------------------------------------------------------
  # The challenge
  # ---------------------------------------------------------------------------

  describe "challenge/1" do
    test "verifies the carry under the fresh head and holds a challenge for it", context do
      identity = identity!(context)
      %{fragment: fragment, action_id: action_id} = carry(identity, context.home)

      assert {:ok, held} = CyfrDoor.challenge(fragment)
      assert held["action_id"] == action_id
      assert held["identifier"] == identity.identifier
      assert held["source"] == "https://a.example"
      assert held["return_url"] == "https://a.example/carry"
      assert held["key_epoch"] == DirectoryServer.key_epoch(identity)
      assert {:ok, _} = Prima.Identity.Encoding.unb64(held["challenge"], 32)
      assert is_binary(held["browser_secret"])
      assert held["expires_at"] > System.os_time(:millisecond)

      # The head was read fresh from the person's directory.
      assert [%{target: "/directory/v1/" <> _} | _] = drain()

      # The browser goes back to the signed return URL with the challenge.
      "https://a.example/carry#" <> back = CyfrDoor.redirect_url(held)
      {:ok, object} = Prima.Carry.decode_object(back)

      assert object == %{
               "protocol" => Prima.Carry.protocol(),
               "action_id" => action_id,
               "audience" => context.home,
               "challenge" => held["challenge"]
             }
    end

    test "a carry for another home, or a genesis that is not its identifier's, makes no request",
         context do
      identity = identity!(context)
      other = identity!(context)
      %{fragment: fragment} = carry(identity, "https://elsewhere.example")
      assert {:error, :wrong_destination} = CyfrDoor.challenge(fragment)

      %{fragment: forged} =
        carry(identity, context.home, payload: %{"genesis" => DirectoryServer.genesis_map(other)})

      assert {:error, :invalid_carry} = CyfrDoor.challenge(forged)
      assert {:error, :invalid_carry} = CyfrDoor.challenge("not a fragment")
      assert {:error, :invalid_carry} = CyfrDoor.challenge(String.duplicate("A", 20_000))

      assert drain() == []
      refute_received {:resolved, _}
      refute_received :connected
    end

    test "an envelope the directory's head does not vouch for is refused", context do
      identity = identity!(context)
      {_public, forger} = :crypto.generate_key(:eddsa, :ed25519)

      %{fragment: forged} = carry(identity, context.home, live: forger)
      assert {:error, {:refused, :bad_signature}} = CyfrDoor.challenge(forged)

      # Signed under the key a rotation since replaced.
      %{fragment: old} = carry(identity, context.home)
      rotated = DirectoryServer.rotate!(context.directory.dir, identity)
      assert {:error, {:refused, :stale_key_epoch}} = CyfrDoor.challenge(old)

      # Issued long before it arrived.
      %{fragment: stale} =
        carry(rotated, context.home, issued_at: System.os_time(:millisecond) - 3_600_000)

      assert {:error, {:refused, :stale}} = CyfrDoor.challenge(stale)
    end

    test "a directory that cannot be read admits nothing from a cache", context do
      # A genesis naming a directory on a port nothing listens on.
      identity =
        DirectoryServer.identity!(context.directory.dir, "https://dir-b.test:1")

      %{fragment: fragment} = carry(identity, context.home)

      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment)
    end

    test "a genesis naming a metadata or unlisted loopback directory reaches no address",
         context do
      metadata = DirectoryServer.identity!(context.directory.dir, "https://metadata.test")
      %{fragment: fragment} = carry(metadata, context.home)
      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment)

      loopback = DirectoryServer.identity!(context.directory.dir, "https://loopback.test")
      %{fragment: fragment} = carry(loopback, context.home)
      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment)

      refute_received :connected
      assert drain() == []
    end

    test "a directory that redirects is not followed, and admits nothing", context do
      redirecting =
        DirectoryServer.Server.start(
          context.tls[:server_config],
          fn _request -> {302, [{"location", "https://metadata.test/directory/v1"}], ""} end,
          self()
        )

      on_exit(fn -> DirectoryServer.Server.stop(redirecting) end)

      identity =
        DirectoryServer.identity!(
          context.directory.dir,
          "https://dir-b.test:#{redirecting.port}"
        )

      %{fragment: fragment} = carry(identity, context.home)
      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment)

      # It asked the one directory once, and never the address it named.
      assert [_one] = drain()
      refute_received {:resolved, "metadata.test"}
    end
  end

  # ---------------------------------------------------------------------------
  # The callback
  # ---------------------------------------------------------------------------

  describe "callback/2" do
    test "admits a person the door allows by identifier, as a remote person with no keys",
         context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)

      assert {:ok, admitted} = CyfrDoor.callback(assertion(identity, held, context.home), held)
      assert admitted.resumed == false
      assert admitted.action_id == held["action_id"]
      assert admitted.return_url == "https://a.example/carry"
      assert admitted.session_token == CyfrDoor.session_token(held)

      row = person_of(identity.identifier)
      assert row.provenance == "remote"
      assert row.directory_url == identity.url
      assert is_nil(row.live_key_sealed) and is_nil(row.operational_key_sealed)

      # Their door identity is the identifier at its directory.
      assert {:ok, user} =
               Sanctum.Tenancy.Users.get_by_identity(
                 Sanctum.Auth.Identity.cyfr_key(identity.url, identity.identifier)
               )

      assert user.id == row.user_id

      # No athanor of their own is minted: they hold here only what a
      # membership gives them, and this one gives none.
      assert Sanctum.Tenancy.Users.personal_athanor_id(user.id) == :none

      # The session records the fresh head's key_epoch, with its receipt.
      assert [%{provider: "cyfr", athanor_id: nil, identity_key_epoch: epoch}] =
               sessions(user.id)

      assert epoch == DirectoryServer.key_epoch(identity)

      assert {:ok, receipt} =
               Arca.CarryActions.receipt(
                 Prima.Actor.system(),
                 context.home,
                 held["challenge_id"]
               )

      assert receipt.user_id == user.id
      assert receipt.action_id == held["action_id"]
      assert receipt.key_epoch == epoch
    end

    test "a retried login resumes the session it minted, and never mints a second", context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)
      fragment = assertion(identity, held, context.home)

      {:ok, first} = CyfrDoor.callback(fragment, held)
      assert {:ok, again} = CyfrDoor.callback(fragment, held)
      assert again.resumed
      assert again.session_token == first.session_token
      user_id = person_of(identity.identifier).user_id
      assert [_one] = sessions(user_id)

      # A cookie with another browser secret is not the browser that signed
      # in under that challenge.
      assert {:error, :receipt_conflict} =
               CyfrDoor.callback(fragment, %{held | "browser_secret" => "another"})

      # A session ended since is not minted again under the same challenge.
      Sanctum.Session.destroy(first.session_token)
      assert {:error, :session_ended} = CyfrDoor.callback(fragment, held)
    end

    test "the same identifier admitted twice is one person here", context do
      identity = identity!(context)
      allow!(identity)

      for _ <- 1..2 do
        held = challenge!(identity, context.home)
        assert {:ok, _} = CyfrDoor.callback(assertion(identity, held, context.home), held)
      end

      assert [row] =
               Arca.Repo.all(
                 from(p in PersonIdentity, where: p.identifier == ^identity.identifier)
               )

      assert length(sessions(row.user_id)) == 2
    end

    test "an assertion for another audience, challenge or carry is refused", context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)

      for {opts, reason} <- [
            {[audience: "https://elsewhere.example"], :wrong_audience},
            {[challenge: :crypto.strong_rand_bytes(32)], :wrong_challenge},
            {[action_id: "car_another"], :wrong_action},
            {[expires_at: System.os_time(:millisecond) - 1], :expired}
          ] do
        assert {:error, {:refused, ^reason}} =
                 CyfrDoor.callback(assertion(identity, held, context.home, opts), held),
               inspect(reason)
      end

      # Another person's identity, against this challenge's.
      other = identity!(context)

      assert {:error, {:refused, :wrong_identifier}} =
               CyfrDoor.callback(assertion(other, held, context.home), held)

      refute person_of(identity.identifier)
    end

    test "an assertion under a live key the directory no longer names is refused: the head is read fresh",
         context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)
      fragment = assertion(identity, held, context.home)

      # The key rotates between the proof and its consumption.
      DirectoryServer.rotate!(context.directory.dir, identity)

      assert {:error, {:refused, :stale_key_epoch}} = CyfrDoor.callback(fragment, held)
      refute person_of(identity.identifier)
    end

    test "a directory unreachable at the callback admits no one", context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)
      DirectoryServer.Server.stop(context.directory.server)

      assert {:error, :identity_stale} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)

      refute person_of(identity.identifier)
    end

    test "an identifier the door does not admit is refused, and waits as an identifier request",
         context do
      identity = identity!(context)
      held = challenge!(identity, context.home)
      fragment = assertion(identity, held, context.home)

      assert {:error, {:door, :not_allowed}} = CyfrDoor.callback(fragment, held)
      refute person_of(identity.identifier)

      assert [%{kind: "identifier", value: value, status: "requested"}] =
               Enum.filter(Store.requests(), &(&1.value == identity.identifier))

      assert value == identity.identifier

      # Allowed by its identifier, it is admitted.
      [request] = Enum.filter(Store.requests(), &(&1.value == identity.identifier))
      {:ok, _} = Store.resolve(request.id, :allow, nil)
      assert {:ok, _} = CyfrDoor.callback(fragment, held)

      # Denied by its identifier, it is not, `*` notwithstanding.
      {:ok, _} = Store.allow("wildcard", "*", nil)
      {:ok, _} = Store.deny("identifier", identity.identifier, nil)
      held = challenge!(identity, context.home)

      assert {:error, {:door, :denied}} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)
    end

    test "a challenge past its expiry, or none, admits nothing", context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)
      fragment = assertion(identity, held, context.home)

      assert {:error, :expired} =
               CyfrDoor.callback(fragment, %{held | "expires_at" => System.os_time(:millisecond)})

      assert {:error, :no_challenge} = CyfrDoor.callback(fragment, nil)
      assert {:error, :no_challenge} = CyfrDoor.callback(fragment, %{"challenge" => "x"})
      assert {:error, :invalid_carry} = CyfrDoor.callback("not a transport", held)
    end

    test "two people on two directories, neither this home's own, are each resolved at theirs",
         context do
      second = DirectoryServer.start!(context.tls, "dir-b.test")
      previous = Application.fetch_env(:sanctum, :directory_url)
      Application.put_env(:sanctum, :directory_url, "https://enrollment.example")

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:sanctum, :directory_url, value)
          :error -> Application.delete_env(:sanctum, :directory_url)
        end
      end)

      one = identity!(context)
      two = DirectoryServer.identity!(second.dir, second.url)

      for identity <- [one, two] do
        allow!(identity)
        held = challenge!(identity, context.home)
        assert {:ok, _} = CyfrDoor.callback(assertion(identity, held, context.home), held)
        assert person_of(identity.identifier).directory_url == identity.url
      end
    end
  end

  # ---------------------------------------------------------------------------
  # After admission
  # ---------------------------------------------------------------------------

  describe "a remote person's session" do
    test "is retired at the next fresh head once a rotation moves the key epoch, and the next sign-in records the new one",
         context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)

      {:ok, %{session_token: token}} =
        CyfrDoor.callback(assertion(identity, held, context.home), held)

      user_id = person_of(identity.identifier).user_id

      rotated = DirectoryServer.rotate!(context.directory.dir, identity)

      assert {:ok, _} = Sanctum.IdentityFreshness.fresh!(identity.identifier)
      assert {:error, :invalid_session} = Sanctum.Session.get(token)

      held = challenge!(rotated, context.home)
      {:ok, _} = CyfrDoor.callback(assertion(rotated, held, context.home), held)
      assert [%{identity_key_epoch: epoch}] = sessions(user_id)
      assert epoch == DirectoryServer.key_epoch(rotated)
    end

    test "is retired by a recovery too", context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)

      {:ok, %{session_token: token}} =
        CyfrDoor.callback(assertion(identity, held, context.home), held)

      recovered = DirectoryServer.recover!(context.directory.dir, identity)
      assert {:ok, %{key_epoch: epoch}} = Sanctum.IdentityFreshness.fresh!(identity.identifier)
      assert epoch == DirectoryServer.key_epoch(recovered)
      assert {:error, :invalid_session} = Sanctum.Session.get(token)
    end

    test "a login receipt names the key epoch its assertion was verified under: a moved one mints nothing",
         context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)
      {:ok, _} = CyfrDoor.callback(assertion(identity, held, context.home), held)
      user_id = person_of(identity.identifier).user_id

      ctx =
        Sanctum.Context.build(
          user_id: user_id,
          provider: "cyfr",
          athanor_id: nil,
          permissions: Sanctum.Context.person_permissions()
        )

      {:ok, ctx} = Sanctum.Tenancy.resolve_status(ctx, force: true)

      receipt = %{
        action_id: "car_moved",
        destination_home: context.home,
        challenge_id: "chl_moved",
        source_home: "https://a.example",
        key_epoch: Prima.Digest.sha256("an epoch the head no longer names"),
        browser_binding_digest: Prima.Digest.sha256("browser"),
        assertion_digest: Prima.Digest.sha256("assertion"),
        outcome: "admitted"
      }

      assert {:error, :stale_key_epoch} =
               Sanctum.Session.create(ctx,
                 login_receipt: %{token: "moved-token", receipt: receipt}
               )

      assert {:error, :not_found} =
               Arca.CarryActions.receipt(Prima.Actor.system(), context.home, "chl_moved")
    end
  end
end
