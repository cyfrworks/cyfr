# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IdentityFreshnessTest do
  @moduledoc """
  An account's head at this home, against a scripted directory.

  A first read verifies the whole log from its genesis and caches its
  head; past the bound a refresh reads the entries after the cached head,
  verifies them from the cached state and walks them in the cache's
  transaction: a removed key's sessions, clients and certificates retire,
  a recovery retires every binding, and a key removed and added again
  between two refreshes is retired and then admitted afresh at the new
  head, where a binding named at the old head is refused. A log that does
  not hold the cached head, or does not verify, pauses the work. A gone
  account retires everything and is answered gone. A directory that
  cannot be read pauses a public home's work and leaves a local or tailnet
  home on the keys it last read; an account never read is refused in
  every mode.
  """

  # The access mode, the private-egress configuration, the resolver's
  # observer, the directory client's seam and the head cache are
  # process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.{DeviceCertificates, DirectoryHeads, PairedClients, PersonIdentities, SessionStorage}
  alias Arca.Schemas.{DirectoryHead, Session, User}
  alias Sanctum.IdentityFreshness
  alias Sanctum.Test.DirectoryServer
  alias Sanctum.Test.DirectoryServer.Server

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    mode!(:public)
    Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
    end)

    dir = DirectoryServer.start!(tls)
    %{dir: dir, account: DirectoryServer.account!(dir.dir, dir.url)}
  end

  # ---- fixtures ----------------------------------------------------------------

  # How this home is reached, restored after the case.
  defp mode!(mode), do: Prima.Test.Env.put_app_env(:sanctum, :access_mode, mode)

  defp system, do: Prima.Actor.system()

  # A person of this home, made by its row alone.
  defp person! do
    now = DateTime.utc_now()

    %User{}
    |> User.changeset(%{
      id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
      admission: "open",
      first_seen_at: now,
      last_seen_at: now,
      created_at: now,
      updated_at: now
    })
    |> Arca.Repo.insert!()
  end

  # A member of this home by `account`, its head read and cached.
  defp member!(account) do
    person = person!()
    :ok = DirectoryServer.account_person!(person.id, account)
    person
  end

  defp cached(identifier), do: Arca.Repo.get(DirectoryHead, identifier)

  # The cached head's last verification moved `seconds` before the database's clock.
  defp aged!(identifier, seconds \\ 3_600) do
    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -seconds, :second)]
      )

    :ok
  end

  defp issuance(user_id),
    do: [lock: %{user_id: user_id, athanor_id: nil, source: nil}, verify: fn _rows -> :ok end]

  defp session(user_id, kid, head) do
    hash = :crypto.strong_rand_bytes(32)

    case SessionStorage.create_session(
           hash,
           %{
             user_id: user_id,
             provider: "cyfr",
             kid: kid,
             head: head,
             expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
           },
           issuance(user_id)
         ) do
      :ok -> {:ok, hash}
      refused -> refused
    end
  end

  defp sessions(user_id),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))

  # A device of the account paired here, at `head`, with its certificate.
  defp device!(person, account, {pub, _priv}, head) do
    athanor = Prima.Actor.in_athanor("ath_if_#{System.unique_integer([:positive])}")
    kid = Prima.Identity.Key.kid(pub)

    {:ok, client} =
      PairedClients.record(athanor, %{
        user_id: person.id,
        source_kind: "device_cert",
        source_id: "req_#{System.unique_integer([:positive])}",
        device_public_key: pub,
        kid: kid,
        head: head
      })

    now = DateTime.utc_now()

    {:ok, certificate} =
      DeviceCertificates.record(athanor, %{
        paired_client_id: client.id,
        user_id: person.id,
        identifier: account.identifier,
        kid: kid,
        head: head,
        device_public_key: pub,
        issuing_home: "https://home.example",
        audience_home: "https://home.example",
        not_before: now,
        expires_at: DateTime.add(now, 3600, :second),
        certificate: "cert-#{System.unique_integer()}",
        digest: Prima.Digest.sha256("cert-#{System.unique_integer()}")
      })

    %{athanor: athanor, client: client, certificate: certificate}
  end

  defp flush_resolved do
    receive do
      {:resolved, _name} -> flush_resolved()
    after
      0 -> :ok
    end
  end

  defp standing(%{athanor: athanor, client: client, certificate: certificate}) do
    {:ok, clients} = PairedClients.list(athanor, standing: :active)
    {:ok, row} = DeviceCertificates.get(athanor, certificate.id)
    {Enum.any?(clients, &(&1.id == client.id)), row.status}
  end

  # ---- reading an account ------------------------------------------------------

  describe "a first read" do
    test "verifies the whole log from its genesis and caches its head", %{
      dir: dir,
      account: alice
    } do
      assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
      assert {:refused, :identity_stale} = IdentityFreshness.fresh!(alice.identifier)
      assert DirectoryServer.requests() == []

      assert {:ok, head} = IdentityFreshness.fresh!(alice.identifier, directory: dir.url)
      assert head.head_hash == DirectoryServer.head(alice)
      assert head.directory_url == dir.url
      assert head.genesis == Prima.Identity.canonical(hd(alice.log))
      assert {:ok, state} = IdentityFreshness.state(head)
      assert [%{kid: kid}] = state.keys
      assert kid == DirectoryServer.kid(hd(alice.devices))

      # Within the bound the cache answers, with no request.
      _requests = DirectoryServer.requests()
      assert {:ok, ^head} = IdentityFreshness.fresh?(alice.identifier)
      assert DirectoryServer.requests() == []
    end

    test "a log read at another directory than its genesis names caches nothing", %{
      tls: tls,
      account: alice,
      dir: dir
    } do
      elsewhere = DirectoryServer.start!(tls, "dir-b.test")

      DirectoryServer.publish(
        elsewhere.dir,
        alice.identifier,
        DirectoryServer.log(dir.dir, alice.identifier)
      )

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh!(alice.identifier, directory: elsewhere.url)
      end)

      assert cached(alice.identifier) == nil
    end

    test "an account never read is refused in every mode, whatever the directory", %{
      dir: dir,
      account: alice
    } do
      Server.stop(dir.server)

      for mode <- [:public, :local, :tailnet] do
        mode!(mode)

        capture_log(fn ->
          assert {:refused, :identity_stale} =
                   IdentityFreshness.fresh!(alice.identifier, directory: dir.url),
                 "#{mode}"

          assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
        end)
      end

      assert cached(alice.identifier) == nil
    end
  end

  # ---- the walk ----------------------------------------------------------------

  describe "a refresh" do
    test "reads after the cached head, and walks a removed key's bindings out with the head", %{
      dir: dir,
      account: alice
    } do
      person = member!(alice)
      old = DirectoryServer.head(alice)
      [removed] = alice.devices
      alice = DirectoryServer.add_device!(dir.dir, alice)
      [_, kept] = alice.devices

      # Bound at the head this home holds: the removed key's and the kept one's.
      {:ok, gone_session} = session(person.id, DirectoryServer.kid(removed), old)
      gone_device = device!(person, alice, removed, old)

      _ = DirectoryServer.requests()
      alice = DirectoryServer.remove_key!(dir.dir, alice, DirectoryServer.kid(removed))
      aged!(alice.identifier)

      assert {:ok, head} = IdentityFreshness.fresh?(alice.identifier)
      assert head.head_hash == DirectoryServer.head(alice)

      assert [%{target: target}] = DirectoryServer.requests()
      assert target == "/directory/v1/#{alice.identifier}/from/#{old}"

      refute gone_session in sessions(person.id)
      assert standing(gone_device) == {false, "revoked"}
      assert {:ok, %{head_hash: new}} = PersonIdentities.get(system(), person.id)
      assert new == head.head_hash

      # The key the walk kept binds at the new head.
      assert {:ok, _hash} = session(person.id, DirectoryServer.kid(kept), new)
    end

    test "a key removed and added again between two refreshes is retired, then admitted afresh",
         %{dir: dir, account: alice} do
      person = member!(alice)
      old = DirectoryServer.head(alice)
      [device] = alice.devices
      kid = DirectoryServer.kid(device)
      {:ok, bound} = session(person.id, kid, old)
      paired = device!(person, alice, device, old)

      # Removed and added back by the recovery key, both after the cached head.
      alice = DirectoryServer.remove_key!(dir.dir, alice, kid)
      {pub, _} = device
      {:ok, key} = Prima.Identity.Key.new(alg: :ed25519, kind: :device, pub: pub)
      alice = DirectoryServer.extend!(alice, kind: :add_key, key: key)
      DirectoryServer.publish(dir.dir, alice.identifier, alice.log)
      aged!(alice.identifier)

      assert {:ok, %{head_hash: new}} = IdentityFreshness.fresh?(alice.identifier)
      assert new == DirectoryServer.head(alice)

      assert {:ok, state} =
               IdentityFreshness.state(cached(alice.identifier) |> Arca.Data.project())

      assert Enum.map(state.keys, & &1.kid) == [kid]

      # Retired, not kept: the session and the device bound at the old head are gone.
      refute bound in sessions(person.id)
      assert standing(paired) == {false, "revoked"}

      # The fence: what was verified at the old head binds nothing now.
      assert {:error, :stale_head} = session(person.id, kid, old)

      # Admitted afresh at the new head.
      assert {:ok, _hash} = session(person.id, kid, new)
      readmitted = device!(person, alice, device, new)
      assert standing(readmitted) == {true, "active"}
    end

    test "a recovery retires every binding of the account", %{dir: dir, account: alice} do
      person = member!(alice)
      old = DirectoryServer.head(alice)
      [device] = alice.devices
      {:ok, bound} = session(person.id, DirectoryServer.kid(device), old)
      paired = device!(person, alice, device, old)

      alice = DirectoryServer.recover!(dir.dir, alice)
      aged!(alice.identifier)

      assert {:ok, %{head_hash: new}} = IdentityFreshness.fresh?(alice.identifier)
      assert new == DirectoryServer.head(alice)
      refute bound in sessions(person.id)
      assert standing(paired) == {false, "revoked"}
    end

    test "an unchanged log moves verified_at alone", %{dir: dir, account: alice} do
      member!(alice)
      aged!(alice.identifier)
      head = DirectoryServer.head(alice)

      assert {:ok, %{head_hash: ^head}} = IdentityFreshness.fresh?(alice.identifier)
      assert {:ok, %{fresh: true}} = DirectoryHeads.fresh(system(), alice.identifier, 300)
      assert [%{target: "/directory/v1/" <> _}] = Enum.take(DirectoryServer.requests(), -1)
      assert DirectoryServer.log(dir.dir, alice.identifier) == alice.log
    end

    test "a log that does not hold the cached head, or does not verify, pauses the work in every mode",
         %{dir: dir, account: alice} do
      member!(alice)
      held = cached(alice.identifier)

      # Another history under the identifier: the cached head is not in it.
      other = DirectoryServer.add_device!(dir.dir, %{alice | log: [hd(alice.log)], devices: []})
      DirectoryServer.publish(dir.dir, alice.identifier, other.log)
      aged!(alice.identifier)

      for mode <- [:public, :local] do
        mode!(mode)

        log =
          capture_log(fn ->
            assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
          end)

        assert log =~ "not_descendant", "#{mode}"
      end

      assert cached(alice.identifier).head_hash == held.head_hash

      # An entry after the cached head signed by no key the log lists.
      {_pub, stranger} = :crypto.generate_key(:eddsa, :ed25519)

      next =
        DirectoryServer.extend!(alice,
          kind: :remove_key,
          kid: DirectoryServer.kid(hd(alice.devices))
        )

      forged = Prima.Identity.sign(%{List.last(next.log) | sig: nil}, stranger)
      DirectoryServer.publish(dir.dir, alice.identifier, alice.log ++ [forged])

      for mode <- [:public, :local] do
        mode!(mode)

        log =
          capture_log(fn ->
            assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
          end)

        assert log =~ "unverified", "#{mode}"
      end

      assert cached(alice.identifier).head_hash == held.head_hash
    end
  end

  # ---- gone --------------------------------------------------------------------

  describe "the keys a log lists" do
    # Apple Passwords' AAGUID.
    @apple "fbfc3007-154e-4ecc-8c0b-6e020557d7bd"

    test "keep when each was added and a passkey's maker, through a first read, a refresh and a recovery",
         %{dir: dir, account: alice} do
      first = DirectoryServer.cached!(alice)
      [device] = alice.devices
      device_added = Enum.at(alice.log, 1)

      assert {:ok, [%{key: %{kid: kid}, added_at: added_at, aaguid: nil}]} =
               IdentityFreshness.keys(first)

      assert {kid, added_at} == {DirectoryServer.kid(device), device_added.at}

      alice = DirectoryServer.add_passkey!(dir.dir, alice, aaguid: @apple)
      alice = DirectoryServer.add_device!(dir.dir, alice)
      alice = DirectoryServer.remove_key!(dir.dir, alice, kid)
      aged!(alice.identifier)

      assert {:ok, head} = IdentityFreshness.fresh?(alice.identifier)
      [_genesis, _device, passkey_added, second_added, _removed] = alice.log
      assert {:ok, keys} = IdentityFreshness.keys(head)

      assert Enum.map(keys, &{&1.key.kid, &1.added_at, &1.aaguid}) == [
               {passkey_added.key.kid, passkey_added.at, @apple},
               {second_added.key.kid, second_added.at, nil}
             ]

      # A first read of the same log keeps the same.
      Arca.Repo.delete_all(from(h in DirectoryHead, where: h.identifier == ^alice.identifier))
      assert {:ok, reread} = IdentityFreshness.fresh!(alice.identifier, directory: dir.url)
      assert IdentityFreshness.keys(reread) == {:ok, keys}

      # A recovery lists its keys from its own time, their makers unknown.
      alice = DirectoryServer.recover!(dir.dir, alice)
      aged!(alice.identifier)
      assert {:ok, recovered} = IdentityFreshness.fresh?(alice.identifier)
      recover = List.last(alice.log)

      assert {:ok, [%{key: %{kid: recovered_kid}, added_at: recovered_at, aaguid: nil}]} =
               IdentityFreshness.keys(recovered)

      assert {recovered_kid, recovered_at} == {hd(recover.keys).kid, recover.at}

      # Notes that do not name the state's keys are no cache to answer from.
      assert IdentityFreshness.keys(%{recovered | keys_added: "{}"}) == {:error, :corrupt}
    end
  end

  describe "an account gone at its directory" do
    test "retires every binding and is answered gone from then on, with no request", %{
      dir: dir,
      account: alice
    } do
      person = member!(alice)
      head = DirectoryServer.head(alice)
      [device] = alice.devices
      {:ok, bound} = session(person.id, DirectoryServer.kid(device), head)
      paired = device!(person, alice, device, head)

      DirectoryServer.tombstone(dir.dir, alice.identifier)

      capture_log(fn ->
        assert {:refused, :identity_gone} = IdentityFreshness.fresh!(alice.identifier)
      end)

      refute bound in sessions(person.id)
      assert standing(paired) == {false, "revoked"}
      assert %DateTime{} = cached(alice.identifier).gone_at

      _ = DirectoryServer.requests()
      assert {:refused, :identity_gone} = IdentityFreshness.fresh?(alice.identifier)
      assert {:refused, :identity_gone} = IdentityFreshness.fresh!(alice.identifier)
      assert DirectoryServer.requests() == []
      assert {:error, :stale_head} = session(person.id, DirectoryServer.kid(device), head)
    end

    test "an account never read and gone is answered gone, with nothing cached", %{
      dir: dir,
      account: alice
    } do
      DirectoryServer.tombstone(dir.dir, alice.identifier)

      assert {:refused, :identity_gone} =
               IdentityFreshness.fresh!(alice.identifier, directory: dir.url)

      assert cached(alice.identifier) == nil
    end
  end

  # ---- an unreachable directory ------------------------------------------------

  describe "an unreachable directory, past the bound" do
    test "a public home pauses the work; a local or tailnet one answers the keys it last read",
         %{dir: dir, account: alice} do
      member!(alice)
      head = DirectoryServer.head(alice)
      aged!(alice.identifier)
      Server.stop(dir.server)

      log =
        capture_log(fn ->
          assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
        end)

      assert log =~ "freshness bound"

      for mode <- [:local, :tailnet] do
        mode!(mode)
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())

        assert {:ok, %{head_hash: ^head}} = IdentityFreshness.fresh?(alice.identifier), "#{mode}"
        assert {:ok, %{head_hash: ^head}} = IdentityFreshness.fresh!(alice.identifier), "#{mode}"
      end
    end

    test "only a directory that did not answer is an outage: a transport failure, a 5xx or a 429",
         %{dir: dir, account: alice} do
      member!(alice)
      head = DirectoryServer.head(alice)
      mode!(:local)

      outages = [
        {503, [], ~s({"error":"unavailable"})},
        {503, [], ~s({"error":"capacity"})},
        {502, [], ""},
        {429, [{"retry-after", "1"}], ~s({"error":"rate_limited"})}
      ]

      for answer <- outages do
        DirectoryServer.answer_reads(dir.dir, alice.identifier, answer)
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
        aged!(alice.identifier)

        capture_log(fn ->
          assert {:ok, %{head_hash: ^head}} = IdentityFreshness.fresh?(alice.identifier),
                 inspect(answer)
        end)
      end

      # An answering directory that served no log this home can verify
      # pauses the work in a local home too.
      answered = [
        {500, [], ~s({"error":"corrupt"})},
        {200, [], "not a page"},
        {302, [{"location", "https://elsewhere.test/"}], ""},
        {400, [], ~s({"error":"bad_request"})}
      ]

      for answer <- answered do
        DirectoryServer.answer_reads(dir.dir, alice.identifier, answer)
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
        aged!(alice.identifier)

        capture_log(fn ->
          assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier),
                 inspect(answer)
        end)
      end

      assert cached(alice.identifier).head_hash == head
    end

    test "a member that found it unreachable reads nothing for 15 seconds", %{
      dir: dir,
      account: alice
    } do
      member!(alice)
      aged!(alice.identifier)
      Server.stop(dir.server)
      flush_resolved()

      capture_log(fn ->
        assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
      end)

      assert_received {:resolved, "dir-a.test"}
      assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
      refute_received {:resolved, _}

      mode!(:local)
      head = DirectoryServer.head(alice)
      assert {:ok, %{head_hash: ^head}} = IdentityFreshness.fresh?(alice.identifier)
      refute_received {:resolved, _}
    end

    test "inside a transaction nothing is read: the mode decides on what is cached", %{
      account: alice
    } do
      member!(alice)
      aged!(alice.identifier)
      head = DirectoryServer.head(alice)
      _ = DirectoryServer.requests()

      Arca.Repo.transaction(fn ->
        capture_log(fn ->
          assert {:refused, :identity_stale} = IdentityFreshness.fresh?(alice.identifier)
        end)

        mode!(:tailnet)
        assert {:ok, %{head_hash: ^head}} = IdentityFreshness.fresh?(alice.identifier)
      end)

      assert DirectoryServer.requests() == []
    end
  end

  test "only the directory client's options are taken", %{account: alice} do
    assert_raise ArgumentError, ~r/does not take/, fn ->
      IdentityFreshness.fresh?(alice.identifier, directory: "https://dir-a.test")
    end

    assert_raise ArgumentError, ~r/does not take/, fn ->
      IdentityFreshness.fresh!(alice.identifier, genesis: "{}")
    end
  end
end
