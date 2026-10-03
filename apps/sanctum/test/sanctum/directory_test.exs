# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DirectoryTest do
  @moduledoc """
  The directory's decisions: a genesis registered once, a rotation against
  the head it names, a recovery against the current policy revision and
  never refused because a rotation moved the head, a request id answered
  with its recorded outcome, a mirror that takes no write, and every
  request admitted to its bounds before any signature is checked, with an
  invalid signature spending nothing of the identifier's allowance and a
  recovery keeping its reserve when rotations have spent theirs.
  """

  # The directory setting, this member's rate counters and the directory's
  # one usage row are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.RequestRateWindow
  alias Prima.Identity
  alias Prima.Identity.{Entry, RecoverRequest}
  alias Sanctum.Directory

  @directory "https://dir.example"
  @policy %{max_identities: 100_000, log_bytes: 1_073_741_824, recovery_reserve_bytes: 10_485_760}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    on_exit(&Prima.RateLimiter.reset/0)
    Sanctum.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp source, do: "203.0.113.#{rem(System.unique_integer([:positive]), 250) + 1}"
  defp request_id, do: "req_#{System.unique_integer([:positive])}"

  # A person's identity as a client holds it: the three key pairs, the
  # signed genesis and its identifier.
  defp person(opts \\ []) do
    {live_pub, _} = keypair()
    {op_pub, op_priv} = operational = keypair()
    {rec_pub, _} = recovery = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: live_pub,
        operational_key: op_pub,
        recovery_keys: [rec_pub | Keyword.get(opts, :more_recovery, [])],
        directory: Keyword.get(opts, :directory, @directory)
      )

    genesis = Identity.sign(genesis, op_priv)

    %{
      genesis: genesis,
      identifier: Identity.identifier(genesis),
      operational: operational,
      recovery: recovery,
      head: Identity.hash(genesis),
      revision: 0
    }
  end

  defp register!(person, from \\ source()) do
    assert {:ok, %{seq: 0}} =
             Directory.register(%{genesis: Entry.encode(person.genesis), source: from})

    person
  end

  defp rotation(person, opts \\ []) do
    {new_live, _} = keypair()
    {_pub, op_priv} = person.operational
    signer = Keyword.get(opts, :signer, op_priv)
    {:ok, entry} = Entry.rotate(Keyword.get(opts, :prev, person.head), new_live)
    Identity.sign(entry, signer)
  end

  defp rotate!(person) do
    entry = rotation(person)

    assert {:ok, %{entry_hash: hash}} =
             Directory.append(person.identifier, %{entry: Entry.encode(entry), source: source()})

    %{person | head: hash}
  end

  defp request(person, opts \\ []) do
    {live, _} = keypair()
    {op_pub, _} = operational = keypair()
    {_pub, rec_priv} = person.recovery

    {:ok, request} =
      RecoverRequest.new(
        identifier: Keyword.get(opts, :identifier, person.identifier),
        directory: Keyword.get(opts, :directory, @directory),
        live_key: live,
        operational_key: op_pub,
        recovery_keys: Keyword.get(opts, :recovery_keys),
        expected_revision: Keyword.get(opts, :revision, person.revision),
        request_id: Keyword.get(opts, :request_id, request_id())
      )

    {Identity.sign(request, Keyword.get(opts, :signer, rec_priv)), operational}
  end

  defp recover(identifier, request),
    do:
      Directory.recover(identifier, %{request: RecoverRequest.encode(request), source: source()})

  defp log(identifier) do
    {:ok, rows} = Arca.IdentityLog.entries(Prima.Actor.system(), identifier)
    rows
  end

  defp page(identifier, after_seq \\ -1),
    do: Directory.resolve(%{identifier: identifier, after: after_seq, source: source()})

  defp windows(bucket, key) do
    Arca.Repo.all(
      from(w in RequestRateWindow,
        where: w.bucket == ^Atom.to_string(bucket) and w.key_hash == ^Prima.Digest.sha256(key)
      )
    )
  end

  # ---- serving -----------------------------------------------------------------

  describe "serving" do
    test "a node that serves no directory answers not_served to every request" do
      Sanctum.Test.Settings.put("directory_serve", "off")
      alice = person()

      assert {:error, :not_served} =
               Directory.register(%{genesis: Entry.encode(alice.genesis), source: source()})

      assert {:error, :not_served} = page(alice.identifier)

      assert {:error, :not_served} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: "req_1",
                 source: source()
               })
    end

    test "a mirror answers read_only to every write, before it counts anything, and serves reads" do
      alice = register!(person())
      Sanctum.Test.Settings.put("directory_serve", "mirror")
      from = "198.51.100.7"

      assert {:error, :read_only} =
               Directory.register(%{genesis: Entry.encode(person().genesis), source: from})

      assert {:error, :read_only} =
               Directory.append(alice.identifier, %{
                 entry: Entry.encode(rotation(alice)),
                 source: from
               })

      {req, _} = request(alice)

      assert {:error, :read_only} =
               Directory.recover(alice.identifier, %{
                 request: RecoverRequest.encode(req),
                 source: from
               })

      assert windows(:directory_source, from) == []
      assert {:ok, %{entries: [_genesis], next: nil, length: 1}} = page(alice.identifier)
    end
  end

  # ---- registration ------------------------------------------------------------

  describe "register/1" do
    test "answers the identifier a genesis hashes to, and the same genesis again is one log" do
      alice = person()
      genesis = Entry.encode(alice.genesis)

      assert {:ok, %{identifier: id, seq: 0, entry_hash: hash}} =
               Directory.register(%{genesis: genesis, source: source()})

      assert id == alice.identifier
      assert hash == alice.head

      assert {:ok, %{identifier: ^id, seq: 0, entry_hash: ^hash}} =
               Directory.register(%{genesis: genesis, source: source()})

      assert [%{seq: 0, entry: stored}] = log(id)
      assert stored == Identity.canonical(alice.genesis)
    end

    test "refuses a genesis whose own signature does not verify, and anything not a genesis" do
      alice = person()
      {_pub, stranger} = keypair()
      forged = Identity.sign(alice.genesis, stranger)

      assert {:error, {:unverified, :wrong_signer}} =
               Directory.register(%{genesis: Entry.encode(forged), source: source()})

      assert {:error, {:invalid, :not_genesis}} =
               Directory.register(%{genesis: Entry.encode(rotation(alice)), source: source()})

      assert {:error, {:invalid, {:missing_field, "protocol"}}} =
               Directory.register(%{genesis: %{}, source: source()})

      assert log(alice.identifier) == []
    end

    test "refuses a new genesis at the identity quota, retryably, and still answers an old one" do
      alice = register!(person())
      Sanctum.Test.Settings.put("directory_max_identities", 1)

      assert {:error, {:capacity, :identities}} =
               Directory.register(%{genesis: Entry.encode(person().genesis), source: source()})

      assert {:ok, %{identifier: id}} =
               Directory.register(%{genesis: Entry.encode(alice.genesis), source: source()})

      assert id == alice.identifier
    end

    test "admits at most 5 registrations a minute from one address, before decoding any" do
      from = "198.51.100.20"

      for _ <- 1..5 do
        assert {:error, {:invalid, _}} = Directory.register(%{genesis: %{}, source: from})
      end

      assert {:error, {:rate_limited, seconds}} =
               Directory.register(%{genesis: Entry.encode(person().genesis), source: from})

      assert seconds in 1..60

      assert {:ok, _} =
               Directory.register(%{genesis: Entry.encode(person().genesis), source: source()})
    end

    test "the installation's bound of 100 a minute holds across members, from many addresses" do
      for n <- 1..100 do
        assert {:error, {:invalid, _}} =
                 Directory.register(%{genesis: %{}, source: "192.0.2.#{n}"})
      end

      alice = person()
      genesis = Entry.encode(alice.genesis)

      assert {:error, {:rate_limited, _}} =
               Directory.register(%{genesis: genesis, source: "198.51.100.101"})

      # A second member counts from nothing: its own counter admits the
      # request, and the window every member shares refuses it.
      Prima.RateLimiter.reset()

      assert {:error, {:rate_limited, _}} =
               Directory.register(%{genesis: genesis, source: "198.51.100.102"})

      assert log(alice.identifier) == []
    end
  end

  # ---- rotation ----------------------------------------------------------------

  describe "append/2" do
    test "appends a rotation that extends the head, verified with the whole chain" do
      alice = register!(person())
      entry = rotation(alice)

      assert {:ok, %{seq: 1, entry_hash: hash}} =
               Directory.append(alice.identifier, %{entry: Entry.encode(entry), source: source()})

      assert hash == Identity.hash(entry)
      assert [%{seq: 0}, %{seq: 1, entry_hash: ^hash}] = log(alice.identifier)
    end

    test "a rotation naming a head that is no longer current is stale, with the current head" do
      alice = register!(person())
      moved = rotate!(alice)
      late = rotation(alice)

      assert {:error, {:stale_head, head}} =
               Directory.append(alice.identifier, %{entry: Entry.encode(late), source: source()})

      assert head == moved.head
      assert length(log(alice.identifier)) == 2
    end

    test "an exact retry of an accepted rotation answers the same, and appends nothing" do
      alice = register!(person())
      entry = Entry.encode(rotation(alice))

      assert {:ok, answer} = Directory.append(alice.identifier, %{entry: entry, source: source()})

      assert {:ok, ^answer} =
               Directory.append(alice.identifier, %{entry: entry, source: source()})

      assert length(log(alice.identifier)) == 2
    end

    test "a rotation not signed by the operational key is refused and writes nothing" do
      alice = register!(person())
      {_pub, stranger} = keypair()

      assert {:error, {:unverified, :wrong_signer}} =
               Directory.append(alice.identifier, %{
                 entry: Entry.encode(rotation(alice, signer: stranger)),
                 source: source()
               })

      assert length(log(alice.identifier)) == 1
    end

    test "invalid signatures spend nothing of the identifier's allowance" do
      alice = register!(person())
      {_pub, stranger} = keypair()

      for _ <- 1..60 do
        assert {:error, {:unverified, :wrong_signer}} =
                 Directory.append(alice.identifier, %{
                   entry: Entry.encode(rotation(alice, signer: stranger)),
                   source: source()
                 })
      end

      assert windows(:directory_signed, alice.identifier) == []
      assert windows(:directory_rotation_daily, alice.identifier) == []
      assert %{head: _} = rotate!(alice)
      assert [%{count: 1}] = windows(:directory_rotation_daily, alice.identifier)
    end

    test "a day's rotations stop at 100, in a window every member shares, and a recovery is exempt" do
      alice = register!(person()) |> rotate!() |> rotate!() |> rotate!()

      assert [%{count: 3, window_ms: 86_400_000}] =
               windows(:directory_rotation_daily, alice.identifier)

      # The rest of the day's budget, spent as 97 more rotations would.
      for _ <- 1..97 do
        :ok =
          Arca.RequestRateWindows.claim(
            Prima.Actor.system(),
            :directory_rotation_daily,
            alice.identifier,
            100,
            86_400_000
          )
      end

      late = Entry.encode(rotation(alice))

      assert {:error, {:capacity, :rotations, seconds}} =
               Directory.append(alice.identifier, %{entry: late, source: source()})

      assert seconds > 86_000 and seconds <= 86_400

      # A second member counts from nothing: its own counter admits the
      # rotation, and the window every member shares refuses it.
      Prima.RateLimiter.reset()

      assert {:error, {:capacity, :rotations, _}} =
               Directory.append(alice.identifier, %{entry: late, source: source()})

      assert length(log(alice.identifier)) == 4

      {req, _} = request(alice)
      assert {:ok, %{seq: 4}} = recover(alice.identifier, req)
    end

    test "rotations stop at 50 a minute, and a valid recovery still has its reserve" do
      alice = register!(person())
      alice = Enum.reduce(1..50, alice, fn _, person -> rotate!(person) end)

      assert {:error, {:rate_limited, _}} =
               Directory.append(alice.identifier, %{
                 entry: Entry.encode(rotation(alice)),
                 source: source()
               })

      {req, _} = request(alice)
      assert {:ok, %{seq: 51}} = recover(alice.identifier, req)
    end

    test "an unknown identifier is not found, and a malformed one is not found either" do
      alice = person()

      assert {:error, :not_found} =
               Directory.append(alice.identifier, %{
                 entry: Entry.encode(rotation(alice)),
                 source: source()
               })

      assert {:error, :not_found} =
               Directory.append("per_nope", %{
                 entry: Entry.encode(rotation(alice)),
                 source: source()
               })
    end

    test "a stored log that no longer verifies is never extended" do
      alice = register!(person())
      bogus = ~s({"not":"an entry"})

      {:ok, _} =
        Arca.IdentityLog.append(
          Prima.Actor.system(),
          alice.identifier,
          %{entry: bogus, entry_hash: Prima.Digest.sha256(bogus), prev_hash: alice.head},
          @policy
        )

      log =
        capture_log(fn ->
          assert {:error, :corrupt} =
                   Directory.append(alice.identifier, %{
                     entry: Entry.encode(rotation(alice, prev: Prima.Digest.sha256(bogus))),
                     source: source()
                   })
        end)

      assert log =~ "does not verify"
      assert length(log(alice.identifier)) == 2
    end
  end

  # ---- recovery ----------------------------------------------------------------

  describe "recover/2" do
    test "commits the request on the current head and replaces both online keys" do
      alice = register!(person()) |> rotate!()
      {req, {new_op, _}} = request(alice)

      assert {:ok, %{seq: 2, entry_hash: hash, entry: bytes}} = recover(alice.identifier, req)

      {:ok, map} = Jason.decode(bytes)
      assert {:ok, %Entry{kind: :recover, prev: prev, request: ^req}} = Entry.decode(map)
      assert prev == alice.head
      assert hash == Prima.Digest.sha256(bytes)

      maps = for row <- log(alice.identifier), do: Jason.decode!(row.entry)

      assert {:ok, %{operational_key: ^new_op, revision: 1, head: ^hash}} =
               Identity.verify_chain(maps)
    end

    test "a lost answer is answered again with the recorded outcome, and nothing is reinstalled" do
      alice = register!(person())
      {req, _} = request(alice)

      assert {:ok, first} = recover(alice.identifier, req)
      assert {:ok, ^first} = recover(alice.identifier, req)
      assert length(log(alice.identifier)) == 2

      assert {:ok, %{outcome: :accepted, seq: 1, entry: entry, request_digest: digest}} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: req.request_id,
                 source: source()
               })

      assert entry == first.entry
      assert digest == Identity.request_digest(req)
    end

    test "a request whose revision is stale is refused, recorded, and answered the same again" do
      alice = register!(person())
      {first, new_operational} = request(alice)
      {late, _} = request(alice)

      assert {:ok, accepted} = recover(alice.identifier, first)
      assert {:error, {:stale_policy, recorded}} = recover(alice.identifier, late)
      assert recorded == %{"outcome" => "stale_policy", "expected_revision" => 0, "revision" => 1}

      # The log moving on changes nothing about the answer.
      alice =
        rotate!(%{alice | head: accepted.entry_hash, operational: new_operational, revision: 1})

      assert {:error, {:stale_policy, ^recorded}} = recover(alice.identifier, late)

      assert {:ok, %{outcome: :stale_policy, recorded: ^recorded}} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: late.request_id,
                 source: source()
               })

      assert length(log(alice.identifier)) == 3
    end

    test "a stale request is recorded only once its signature verifies under that revision's set" do
      alice = register!(person())
      {first, _} = request(alice)
      {_pub, stranger} = keypair()
      {forged, _} = request(alice, signer: stranger)

      assert {:ok, _} = recover(alice.identifier, first)
      assert {:error, {:unverified, :wrong_signer}} = recover(alice.identifier, forged)

      assert {:error, :not_found} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: forged.request_id,
                 source: source()
               })
    end

    test "a request naming another directory is refused and not recorded" do
      alice = register!(person())
      {req, _} = request(alice, directory: "https://elsewhere.example")

      assert {:error, {:unverified, :directory_changed}} = recover(alice.identifier, req)

      assert {:error, :not_found} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: req.request_id,
                 source: source()
               })
    end

    test "a request signed for another identifier is refused on this one" do
      alice = register!(person())
      bob = register!(person())
      {req, _} = request(alice)

      assert {:error, :wrong_identifier} = recover(bob.identifier, req)
      assert length(log(bob.identifier)) == 1
      assert length(log(alice.identifier)) == 1
    end

    test "a key that holds no recovery for the identifier recovers nothing" do
      alice = register!(person())
      {_pub, stranger} = keypair()
      {req, _} = request(alice, signer: stranger)

      assert {:error, {:unverified, :wrong_signer}} = recover(alice.identifier, req)
      assert windows(:directory_signed, alice.identifier) == []
      assert length(log(alice.identifier)) == 1
    end

    test "the same request id with other content is refused" do
      alice = register!(person())
      {first, _} = request(alice, request_id: "req_same")
      {other, _} = request(alice, request_id: "req_same")

      assert {:ok, _} = recover(alice.identifier, first)
      assert {:error, :request_id_reused} = recover(alice.identifier, other)
    end

    test "a request expecting a revision the log has not reached is refused" do
      alice = register!(person())
      {req, _} = request(alice, revision: 3)

      assert {:error, {:unverified, :stale_revision}} = recover(alice.identifier, req)
    end

    test "a rotation landing between a recovery's read and its write re-bases it on the new head" do
      alice = register!(person())
      {req, {new_op, _}} = request(alice)
      pause_log_reads!()

      recovery = Task.async(fn -> paused(1, fn -> recover(alice.identifier, req) end) end)
      rotated = rotate_behind!(alice)

      assert {:ok, %{seq: 2, entry: bytes}} = Task.await(recovery)
      assert {:ok, %Entry{prev: prev, request: ^req}} = bytes |> Jason.decode!() |> Entry.decode()
      assert prev == rotated.head

      maps = for row <- log(alice.identifier), do: Jason.decode!(row.entry)

      assert {:ok, %{operational_key: ^new_op, revision: 1, length: 3}} =
               Identity.verify_chain(maps)
    end

    test "a recovery the head keeps moving under is busy after three re-bases, and retryable" do
      alice = register!(person())
      {req, _} = request(alice)
      pause_log_reads!()

      # The first read and each of the three re-bases' reads.
      recovery = Task.async(fn -> paused(4, fn -> recover(alice.identifier, req) end) end)
      Enum.reduce(1..4, alice, fn _, person -> rotate_behind!(person) end)

      assert {:error, :busy} = Task.await(recovery)
      assert length(log(alice.identifier)) == 5

      assert {:error, :not_found} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: req.request_id,
                 source: source()
               })

      assert {:ok, %{seq: 5}} = recover(alice.identifier, req)
    end
  end

  describe "a forged request" do
    test "is refused on the head's keys alone, without the log being read" do
      alice = register!(person()) |> rotate!() |> rotate!() |> rotate!()
      {_pub, replaced} = alice.operational
      {first, new_operational} = request(alice)
      assert {:ok, %{entry_hash: hash}} = recover(alice.identifier, first)
      alice = rotate!(%{alice | head: hash, operational: new_operational, revision: 1})

      {_pub, stranger} = keypair()
      [%{count: spent}] = windows(:directory_signed, alice.identifier)
      watch_log_reads!()

      # A rotation on the public head signed by any other key, the one the
      # recovery replaced included.
      for signer <- [stranger, replaced] do
        assert {:error, {:unverified, :wrong_signer}} =
                 Directory.append(alice.identifier, %{
                   entry: Entry.encode(rotation(alice, signer: signer)),
                   source: source()
                 })
      end

      {forged, _} = request(alice, signer: stranger)
      assert {:error, {:unverified, :wrong_signer}} = recover(alice.identifier, forged)

      {stale_forged, _} = request(alice, revision: 0, signer: stranger)
      assert {:error, {:unverified, :wrong_signer}} = recover(alice.identifier, stale_forged)

      {elsewhere, _} = request(alice, directory: "https://elsewhere.example")
      assert {:error, {:unverified, :directory_changed}} = recover(alice.identifier, elsewhere)

      {ahead, _} = request(alice, revision: 5)
      assert {:error, {:unverified, :stale_revision}} = recover(alice.identifier, ahead)

      assert log_reads() == []
      assert [%{count: ^spent}] = windows(:directory_signed, alice.identifier)

      # The watch sees the read a valid rotation makes.
      assert %{head: _} = rotate!(alice)
      assert log_reads() != []
    end
  end

  # Every ordered read of a log's entries this process makes from here on:
  # the read `Sanctum.Directory` verifies a whole log from.
  defp watch_log_reads! do
    id = "directory-test-reads-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        id,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          query = meta[:query]

          if self() == test and is_binary(query) and query =~ ~s(FROM "identity_log_entries") and
               query =~ ~s("seq" >),
             do: send(test, {:log_read, query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp log_reads do
    receive do
      {:log_read, query} -> [query | log_reads()]
    after
      0 -> []
    end
  end

  # ---- a write between a read and a write --------------------------------------

  # A process that marked itself `paused(n, …)` stops after each of its
  # next `n` unlocked reads of a log (the ordered entries query
  # `Sanctum.Directory` reads a log whole with), tells the test and waits
  # for it: the point between a decision's read and its write, where no
  # lock is held.
  defp pause_log_reads! do
    id = "directory-test-pause-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, [:arca, :repo, :query], &__MODULE__.pause/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def pause(_event, _measurements, meta, test) do
    pauses = Process.get({__MODULE__, :pauses}, 0)
    query = meta[:query]

    if pauses > 0 and is_binary(query) and query =~ ~s(FROM "identity_log_entries") and
         query =~ ~s("seq" >) do
      Process.put({__MODULE__, :pauses}, pauses - 1)
      send(test, {:paused, self()})

      receive do
        :go -> :ok
      end
    end
  end

  defp paused(count, fun) do
    Process.put({__MODULE__, :pauses}, count)
    fun.()
  end

  # At the next pause, a rotation committed straight to the store, then
  # the paused process let go.
  defp rotate_behind!(person) do
    assert_receive {:paused, reader}, 5_000
    entry = rotation(person)

    {:ok, _row} =
      Arca.IdentityLog.append(
        Prima.Actor.system(),
        person.identifier,
        %{
          entry: Identity.canonical(entry),
          entry_hash: Identity.hash(entry),
          prev_hash: person.head
        },
        @policy
      )

    send(reader, :go)
    %{person | head: Identity.hash(entry)}
  end

  # ---- pages -------------------------------------------------------------------

  describe "resolve/1" do
    test "pages hold at most 64 KiB of entries, and link by next, head and length" do
      # Each recovery names a recovery set of 301 keys, about 14 KiB an
      # entry: the genesis and four of them fill the first page, and the
      # last two make the second.
      alice = register!(person())
      {holder, _} = alice.recovery
      big = fn -> [holder | for(_ <- 1..300, do: elem(keypair(), 0))] end

      alice =
        Enum.reduce(0..5, alice, fn revision, person ->
          {req, _} = request(person, recovery_keys: big.())
          assert {:ok, %{entry_hash: hash}} = recover(person.identifier, req)
          %{person | head: hash, revision: revision + 1}
        end)

      assert {:ok, first} = page(alice.identifier)
      assert %{from: 0, next: 4, length: 7} = first
      assert first.head == alice.head
      assert length(first.entries) == 5
      assert Enum.sum(Enum.map(first.entries, &(byte_size(&1) + 1))) <= 65_536 - 1_024

      assert {:ok, second} = page(alice.identifier, first.next)
      assert %{from: 5, next: nil, length: 7} = second
      assert length(second.entries) == 2

      entries = Enum.map(first.entries ++ second.entries, &Jason.decode!/1)
      assert {:ok, %{head: head, length: 7}} = Identity.verify_chain(entries)
      assert head == alice.head
    end

    test "an unknown identifier is not found, and a position outside the log's range is invalid" do
      assert {:error, :not_found} = page(person().identifier)
      alice = register!(person())
      from = "198.51.100.78"

      for position <- [-2, 2_147_483_648, 99_999_999_999_999_999_999_999] do
        assert {:error, {:invalid, {:invalid_field, "after"}}} =
                 Directory.resolve(%{identifier: alice.identifier, after: position, source: from})
      end

      assert windows(:directory_source, from) == []
      assert {:ok, %{entries: [], next: nil, length: 1}} = page(alice.identifier, 0)
    end

    test "an unknown request is not found" do
      alice = register!(person())

      assert {:error, :not_found} =
               Directory.outcome(%{
                 identifier: alice.identifier,
                 request_id: "req_x",
                 source: source()
               })
    end
  end
end
