# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.CyfrDoorTest do
  @moduledoc """
  The `cyfr` door at a relying home, against a scripted directory that
  speaks HTTPS under a test authority on loopback, and the person's own
  home played by the test with their live key.

  A carry is verified under the head read fresh from the directory the
  person's genesis names, before which a carry for another home, a
  genesis that does not hash to its identifier, and a sign-in whose
  request the browser lost make no request; the
  challenge is held in the browser's cookie and the browser goes back to
  the carry's signed return URL; the assertion is verified under the
  current live key, for this home, this challenge and this carry, and the
  door judges the identity by its identifier. A first-time person is made
  by the remote admission (`Sanctum.Newcomer`), a known one unlocked: a
  remote person here, with no key and no athanor of their own; their
  session records the head's `key_epoch` and commits with its login
  receipt, and a retried login resumes it. Every carry that reaches a
  directory read is counted against the installation's 200 a minute
  first, on this member and then in the cell: past it no directory is
  read, and past this member's own count no database is asked.

  The challenge copies the request's attempt and invitation. A challenge
  carrying an invitation's hash admits by it: a known person is checked
  against the door's deny, redeemed, seated and allowed, then unlocked; a
  first-time one is admitted by the remote admission with it; an
  invitation that can no longer be used signs in only a person the door
  admits anyway, and the allow it wrote admits later sign-ins without it.
  """

  # The resolver's observer, the directory seam, the private-egress
  # listing, the rate counters and the slot are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{PersonIdentity, RequestRateWindow, Session}
  alias Sanctum.Auth.CyfrDoor
  alias Sanctum.Door.Store
  alias Sanctum.Test.DirectoryServer

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
    end)

    directory = DirectoryServer.start!(tls)

    # An installation already set up: a remote newcomer is admitted only
    # where a person exists (`Sanctum.Newcomer`).
    {:ok, _} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|cyfr-door-installation",
        provider: "github"
      })

    %{directory: directory, home: Sanctum.Person.home()}
  end

  defp identity!(%{directory: directory}),
    do: DirectoryServer.identity!(directory.dir, directory.url)

  defp allow!(identity), do: {:ok, _} = Store.allow("identifier", identity.identifier, nil)

  defp carry(identity, home, opts \\ []),
    do: DirectoryServer.carry_fragment(identity, home, opts)

  defp challenge!(identity, home, opts \\ []) do
    {invitation, opts} = Keyword.pop(opts, :invitation)
    %{fragment: fragment} = carry(identity, home, opts)
    {:ok, held} = CyfrDoor.challenge(fragment, request(invitation))
    held
  end

  # The request a start keeps in the browser's session: a fresh attempt,
  # and the invitation's hash or none.
  defp request(invitation \\ nil),
    do: %{
      "attempt" => "att_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "invitation" => invitation
    }

  defp assertion(identity, held, home, opts \\ []),
    do: DirectoryServer.assertion_fragment(identity, held, home, opts)

  defp sessions(user_id),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id))

  defp person_of(identifier),
    do: Arca.Repo.one(from(p in PersonIdentity, where: p.identifier == ^identifier))

  defp drain, do: DirectoryServer.requests()

  # `n` carries counted in the cell's installation window, as members
  # before this one counted them.
  defp spend!(n) do
    for _ <- 1..n,
        do:
          :ok =
            Arca.RequestRateWindows.claim(
              Prima.Actor.system(),
              :cyfr_carry_installation,
              "installation",
              200,
              60_000
            )
  end

  defp installation_window do
    hash = Prima.Digest.sha256("installation")

    Arca.Repo.one(
      from(w in RequestRateWindow,
        where: w.bucket == "cyfr_carry_installation" and w.key_hash == ^hash
      )
    )
  end

  # The tables this process's statements read or write from here on.
  defp watch_sources! do
    handler = "cyfr-door-sources-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == parent and is_binary(meta[:source]),
            do: send(parent, {:source, meta[:source]})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp sources(acc \\ []) do
    receive do
      {:source, source} -> sources([source | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.uniq()
    end
  end

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

  describe "challenge/2" do
    test "verifies the carry under the fresh head and holds a challenge for it", context do
      identity = identity!(context)
      %{fragment: fragment, action_id: action_id} = carry(identity, context.home)

      assert {:ok, held} = CyfrDoor.challenge(fragment, request())
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
      assert {:error, :wrong_destination} = CyfrDoor.challenge(fragment, request())

      %{fragment: forged} =
        carry(identity, context.home, payload: %{"genesis" => DirectoryServer.genesis_map(other)})

      assert {:error, :invalid_carry} = CyfrDoor.challenge(forged, request())
      assert {:error, :invalid_carry} = CyfrDoor.challenge("not a fragment", request())

      assert {:error, :invalid_carry} =
               CyfrDoor.challenge(String.duplicate("A", 20_000), request())

      assert drain() == []
      refute_received {:resolved, _}
      refute_received :connected

      # Nor does it cost the installation's bound anything.
      assert installation_window() == nil
    end

    test "a sign-in whose request the browser lost is refused before anything else",
         context do
      identity = identity!(context)
      %{fragment: fragment} = carry(identity, context.home)
      watch_sources!()

      assert {:error, :no_request} = CyfrDoor.challenge(fragment, :lost)
      # Before the carry is even read.
      assert {:error, :no_request} = CyfrDoor.challenge("not a fragment", :lost)

      assert drain() == []
      assert sources() == []
      assert installation_window() == nil
    end

    test "copies the request's attempt and invitation into the challenge", context do
      identity = identity!(context)
      %{fragment: fragment} = carry(identity, context.home)
      hash = Prima.Digest.sha256_hex("an invitation")

      ordinary = request()
      assert {:ok, held} = CyfrDoor.challenge(fragment, ordinary)
      assert Map.fetch!(held, "attempt") == ordinary["attempt"]
      assert Map.fetch(held, "invitation") == {:ok, nil}

      invited = request(hash)
      %{fragment: fragment} = carry(identity, context.home)
      assert {:ok, held} = CyfrDoor.challenge(fragment, invited)
      assert {held["attempt"], held["invitation"]} == {invited["attempt"], hash}
    end

    test "a request with no attempt id, or an invitation that is no hash, is no request",
         context do
      identity = identity!(context)
      %{fragment: fragment} = carry(identity, context.home)
      watch_sources!()

      for request <- [
            %{},
            %{"invitation" => nil},
            %{"attempt" => "", "invitation" => nil},
            %{"attempt" => nil, "invitation" => nil},
            %{request() | "invitation" => "an invitation code"},
            %{request() | "invitation" => String.upcase(Prima.Digest.sha256_hex("x"))}
          ] do
        assert {:error, :no_request} = CyfrDoor.challenge(fragment, request)
      end

      assert drain() == []
      assert sources() == []
    end

    test "a sign-in names no identity: a carry of any identity proceeds", context do
      for identity <- [identity!(context), identity!(context)] do
        %{fragment: fragment} = carry(identity, context.home)
        assert {:ok, held} = CyfrDoor.challenge(fragment, request())
        assert held["identifier"] == identity.identifier
      end
    end

    test "an envelope the directory's head does not vouch for is refused", context do
      identity = identity!(context)
      {_public, forger} = :crypto.generate_key(:eddsa, :ed25519)

      %{fragment: forged} = carry(identity, context.home, live: forger)
      assert {:error, {:refused, :bad_signature}} = CyfrDoor.challenge(forged, request())

      # Signed under the key a rotation since replaced.
      %{fragment: old} = carry(identity, context.home)
      rotated = DirectoryServer.rotate!(context.directory.dir, identity)
      assert {:error, {:refused, :stale_key_epoch}} = CyfrDoor.challenge(old, request())

      # Issued long before it arrived.
      %{fragment: stale} =
        carry(rotated, context.home, issued_at: System.os_time(:millisecond) - 3_600_000)

      assert {:error, {:refused, :stale}} = CyfrDoor.challenge(stale, request())
    end

    test "a directory that cannot be read admits nothing from a cache", context do
      # A genesis naming a directory on a port nothing listens on.
      identity =
        DirectoryServer.identity!(context.directory.dir, "https://dir-b.test:1")

      %{fragment: fragment} = carry(identity, context.home)

      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment, request())
    end

    test "a genesis naming a metadata or unlisted loopback directory reaches no address",
         context do
      metadata = DirectoryServer.identity!(context.directory.dir, "https://metadata.test")
      %{fragment: fragment} = carry(metadata, context.home)
      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment, request())

      loopback = DirectoryServer.identity!(context.directory.dir, "https://loopback.test")
      %{fragment: fragment} = carry(loopback, context.home)
      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment, request())

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
      assert {:error, :identity_stale} = CyfrDoor.challenge(fragment, request())

      # It asked the one directory once, and never the address it named.
      assert [_one] = drain()
      refute_received {:resolved, "metadata.test"}
    end
  end

  # ---------------------------------------------------------------------------
  # The installation's bound
  # ---------------------------------------------------------------------------

  describe "the installation's bound on carries" do
    test "200 a minute reach a directory, counted alike by every member: past them none does",
         context do
      identity = identity!(context)

      # Every other member counted all but one of the minute's carries.
      spend!(199)
      %{fragment: last} = carry(identity, context.home)
      assert {:ok, _held} = CyfrDoor.challenge(last, request())
      assert [_read] = drain()

      %{fragment: past} = carry(identity, context.home)
      assert {:error, {:rate_limited, retry_after_ms}} = CyfrDoor.challenge(past, request())
      assert retry_after_ms in 1..60_000
      assert drain() == []

      # Another member: its own count is fresh, the cell's is not.
      Prima.Test.RateLimiter.reset!()
      assert {:error, {:rate_limited, _}} = CyfrDoor.challenge(past, request())
      assert drain() == []

      # Nothing was counted past the cap.
      assert %{count: 200} = installation_window()
    end

    test "past this member's own count a carry asks no database and reads no directory",
         context do
      identity = identity!(context)
      spend!(200)
      %{fragment: fragment} = carry(identity, context.home)

      # Refused by the cell's count, each still counted on this member.
      for _ <- 1..200, do: {:error, {:rate_limited, _}} = CyfrDoor.challenge(fragment, request())

      watch_sources!()
      assert {:error, {:rate_limited, retry_after_ms}} = CyfrDoor.challenge(fragment, request())
      assert retry_after_ms in 1..60_000
      assert sources() == []
      assert drain() == []
      assert %{count: 200} = installation_window()
    end

    test "a sign-in whose challenge was held before the bound was spent still completes",
         context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)

      spend!(199)
      %{fragment: past} = carry(identity, context.home)
      assert {:error, {:rate_limited, _}} = CyfrDoor.challenge(past, request())

      assert {:ok, %{resumed: false}} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)

      assert person_of(identity.identifier).provenance == "remote"
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

    test "a held challenge without its attempt or its invitation key is no challenge", context do
      identity = identity!(context)
      allow!(identity)
      held = challenge!(identity, context.home)
      fragment = assertion(identity, held, context.home)

      assert {:error, :no_challenge} = CyfrDoor.callback(fragment, Map.delete(held, "attempt"))
      assert {:error, :no_challenge} = CyfrDoor.callback(fragment, Map.delete(held, "invitation"))
      refute person_of(identity.identifier)
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

  describe "an invitation for an existing identity" do
    setup %{tls: _tls} do
      {:ok, issuer} =
        Sanctum.Tenancy.Users.get_by_identity("github|https://github.com|cyfr-door-installation")

      {:ok, group} = Sanctum.Tenancy.Athanors.create_group(issuer.id, "Invited at the door")
      %{issuer: issuer, group: group}
    end

    defp invitation!(%{issuer: issuer, group: group}) do
      ctx = Sanctum.TestContext.session!(issuer.id)
      {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, group.id)
      {:ok, hash} = Sanctum.Invitations.code_hash(code)
      {invitation, hash}
    end

    defp door(identifier), do: Enum.filter(Store.list(), &(&1.value == identifier))

    # A remote person this home knows, signed in once under an allow that
    # was then removed: known here, and unallowed.
    defp known_unallowed!(context, identity) do
      {:ok, allow} = Store.allow("identifier", identity.identifier, nil)
      held = challenge!(identity, context.home)
      {:ok, _} = CyfrDoor.callback(assertion(identity, held, context.home), held)
      :ok = Store.remove(allow.id)
      user_id = person_of(identity.identifier).user_id
      assert {:error, :not_allowed} = Sanctum.Door.admit_person(%{id: user_id})
      user_id
    end

    test "a known, unallowed person with an invitation is admitted, seated and allowed",
         context do
      identity = identity!(context)
      user_id = known_unallowed!(context, identity)
      {invitation, hash} = invitation!(context)

      held = challenge!(identity, context.home, invitation: hash)

      assert {:ok, %{invitation: :redeemed, resumed: false}} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)

      assert Sanctum.Tenancy.Members.member?(user_id, context.group.id)
      note = "invitation " <> invitation.id
      assert [%{effect: "allow", status: "allowed", note: ^note}] = door(identity.identifier)

      assert Arca.Repo.get!(Arca.Schemas.Invitation, invitation.id).redeemed_by == user_id
    end

    test "a first-time person with an invitation is admitted by it, with no allow before",
         context do
      identity = identity!(context)
      {_invitation, hash} = invitation!(context)
      held = challenge!(identity, context.home, invitation: hash)

      assert {:ok, %{invitation: :redeemed}} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)

      user_id = person_of(identity.identifier).user_id
      assert Sanctum.Tenancy.Members.member?(user_id, context.group.id)
      assert [%{effect: "allow"}] = door(identity.identifier)
    end

    test "a retry of the same completed sign-in resumes it and redeems nothing again", context do
      identity = identity!(context)
      {invitation, hash} = invitation!(context)
      held = challenge!(identity, context.home, invitation: hash)
      fragment = assertion(identity, held, context.home)

      {:ok, first} = CyfrDoor.callback(fragment, held)

      assert {:ok, %{resumed: true, invitation: :none} = again} =
               CyfrDoor.callback(fragment, held)

      assert again.session_token == first.session_token
      assert Arca.Repo.get!(Arca.Schemas.Invitation, invitation.id).redeemed_at
      assert length(door(identity.identifier)) == 1
    end

    test "a denied person or identifier cannot redeem, and the invitation stays unspent",
         context do
      identity = identity!(context)
      user_id = known_unallowed!(context, identity)
      other = identity!(context)
      {invitation, hash} = invitation!(context)
      {:ok, _} = Store.deny("person", user_id, nil)
      {:ok, _} = Store.deny("identifier", other.identifier, nil)

      for who <- [identity, other] do
        held = challenge!(who, context.home, invitation: hash)

        assert {:error, {:door, :denied}} =
                 CyfrDoor.callback(assertion(who, held, context.home), held)
      end

      assert %{redeemed_at: nil} = Arca.Repo.get!(Arca.Schemas.Invitation, invitation.id)
      refute Sanctum.Tenancy.Members.member?(user_id, context.group.id)
      refute person_of(other.identifier)
    end

    test "a spent invitation signs in a person the door admits, and refuses anyone else, writing nothing",
         context do
      allowed = identity!(context)
      {:ok, _} = Store.allow("identifier", allowed.identifier, nil)
      stranger = identity!(context)
      known = identity!(context)
      known_id = known_unallowed!(context, known)
      {_invitation, hash} = invitation!(context)
      {:ok, _} = Arca.Invitations.redeem(Prima.Actor.system(), hash, person_of_any!())

      held = challenge!(allowed, context.home, invitation: hash)

      assert {:ok, %{invitation: :unusable}} =
               CyfrDoor.callback(assertion(allowed, held, context.home), held)

      for who <- [stranger, known] do
        held = challenge!(who, context.home, invitation: hash)

        assert {:error, :invitation_invalid} =
                 CyfrDoor.callback(assertion(who, held, context.home), held)
      end

      refute person_of(stranger.identifier)
      refute Sanctum.Tenancy.Members.member?(known_id, context.group.id)
      assert door(stranger.identifier) == []
      assert door(known.identifier) == []

      assert Enum.filter(Store.requests(), &(&1.value in [stranger.identifier, known.identifier])) ==
               []
    end

    test "a failure after the redemption leaves a plain sign-in that admits", context do
      identity = identity!(context)
      user_id = known_unallowed!(context, identity)
      {invitation, hash} = invitation!(context)

      # The redemption committed, and nothing of the sign-in reached the
      # browser after it.
      assert {:ok, _} = Sanctum.Invitations.redeem_for(hash, user_id)

      held = challenge!(identity, context.home)

      assert {:ok, %{invitation: :none}} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)

      assert Sanctum.Tenancy.Members.member?(user_id, context.group.id)
      assert Arca.Repo.get!(Arca.Schemas.Invitation, invitation.id).redeemed_by == user_id

      # The same invitation again is spent, and the allow still admits.
      held = challenge!(identity, context.home, invitation: hash)

      assert {:ok, %{invitation: :unusable}} =
               CyfrDoor.callback(assertion(identity, held, context.home), held)
    end

    defp person_of_any! do
      {:ok, person} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|cyfr-door-spent-#{System.unique_integer([:positive])}",
          provider: "github"
        })

      person.id
    end
  end
end
