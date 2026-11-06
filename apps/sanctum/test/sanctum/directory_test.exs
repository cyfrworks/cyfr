# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DirectoryTest do
  @moduledoc """
  The directory's decisions, `cyfr-directory/v2`: a genesis registered
  once, and only when it names the directory this node serves; an entry
  appended against the head it names (`exists` for one already written,
  `stale_head`, `duplicate_key`, any other refusal of the chain
  `unverified`); a log read from a position or after an entry's hash; the
  operator's tombstone, after which the account is gone; a mirror that
  takes no write; and every request admitted to its bounds before any
  signature is checked, with an invalid signature spending nothing of the
  identifier's allowance, a listed key's writes stopping at their day of
  100, and a recovery key's keeping the reserve.
  """

  # The directory setting, this node's public URL and fallback origin,
  # this member's rate counters and the directory's one usage row are
  # process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.{IdentityLogEntry, RequestRateWindow, ServerMeta}
  alias Prima.Identity
  alias Prima.Identity.{Entry, Key}
  alias Sanctum.Directory

  @directory "https://dir.example"
  @policy %{max_identities: 100_000, log_bytes: 1_073_741_824, recovery_reserve_bytes: 10_485_760}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    serve_at(@directory)
    Sanctum.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  # This node's public URL, and so the directory it serves
  # (`Sanctum.origin/0`), restored when the test ends.
  defp serve_at(url), do: put_sanctum_env(:public_url, url)

  # A local home declares no public URL: its origin is the fallback the
  # runtime builds from its port (`Cyfr.RuntimeConfig`).
  defp serve_locally_at(origin) do
    put_sanctum_env(:public_url, nil)
    put_sanctum_env(:fallback_origin, origin)
  end

  # A `:sanctum` setting for the rest of the test, nil unsetting it, its
  # restore registered before it changes.
  defp put_sanctum_env(key, value) do
    previous = Application.fetch_env(:sanctum, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, key, value)
        :error -> Application.delete_env(:sanctum, key)
      end
    end)

    if is_nil(value),
      do: Application.delete_env(:sanctum, key),
      else: Application.put_env(:sanctum, key, value)
  end

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp source, do: "203.0.113.#{rem(System.unique_integer([:positive]), 250) + 1}"
  defp now, do: System.os_time(:millisecond)

  # An account as its pages hold it: the recovery key pair, the signed
  # genesis, its identifier, and the head and position it has reached.
  defp account(opts \\ []) do
    {recovery_pub, recovery_priv} = recovery = keypair()

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: now(),
        signer: Identity.recovery_signer(recovery_pub),
        directory: Keyword.get(opts, :directory, @directory),
        recovery: [recovery_pub | Keyword.get(opts, :more_recovery, [])]
      )

    genesis = Identity.sign(genesis, recovery_priv)

    %{
      genesis: genesis,
      identifier: Identity.identifier(genesis),
      recovery: recovery,
      device: nil,
      head: Identity.hash(genesis),
      seq: 0
    }
  end

  defp register!(account, from \\ source()) do
    assert {:ok, %{seq: 0, result: :created}} =
             Directory.register(%{genesis: Entry.encode(account.genesis), source: from})

    account
  end

  defp device_key(pub) do
    {:ok, key} = Key.new(alg: :ed25519, kind: :device, pub: pub)
    key
  end

  # An entry after the account's head: signed by its recovery key, or with
  # `by:` a device key pair it lists; `sign_with:` signs with another
  # private key under the same signer.
  defp entry(account, fields, opts \\ []) do
    {signer, private} =
      case Keyword.get(opts, :by, :recovery) do
        :recovery ->
          {pub, priv} = account.recovery
          {Identity.recovery_signer(pub), priv}

        {pub, priv} ->
          {Key.kid(pub), priv}
      end

    {:ok, entry} =
      Entry.new(
        [
          prev: Keyword.get(opts, :prev, account.head),
          seq: Keyword.get(opts, :seq, account.seq + 1),
          at: now(),
          signer: signer
        ] ++ fields
      )

    Identity.sign(entry, Keyword.get(opts, :sign_with, private))
  end

  defp append(account, entry, from \\ source()),
    do: Directory.append(account.identifier, %{entry: Entry.encode(entry), source: from})

  defp append!(account, entry) do
    assert {:ok, %{result: :accepted, seq: seq, entry_hash: hash}} = append(account, entry)
    %{account | head: hash, seq: seq}
  end

  # The account with a device key its recovery key added: a key that signs
  # as a listed key.
  defp with_device!(account) do
    {pub, _} = device = keypair()
    account = append!(account, entry(account, kind: :add_key, key: device_key(pub)))
    %{account | device: device}
  end

  # A listed key's write: another device key added by the account's device.
  defp key_entry(account),
    do: entry(account, [kind: :add_key, key: device_key(elem(keypair(), 0))], by: account.device)

  defp key_write!(account), do: append!(account, key_entry(account))

  defp log(identifier) do
    {:ok, rows} = Arca.IdentityLog.entries(Prima.Actor.system(), identifier)
    rows
  end

  defp page(identifier, after_seq \\ -1),
    do: Directory.resolve(%{identifier: identifier, after: after_seq, source: source()})

  defp after_hash(identifier, hash),
    do: Directory.from(%{identifier: identifier, hash: hash, source: source()})

  # Everything a registration writes: every log entry and the directory's
  # usage row.
  defp stored do
    {Arca.Repo.all(from(e in IdentityLogEntry, order_by: [e.identifier, e.seq])),
     Arca.Repo.get(ServerMeta, "directory_usage")}
  end

  # A genesis naming each of `directories` is refused `:wrong_directory`,
  # and nothing is stored.
  defp refuses(directories) do
    before = stored()

    for directory <- directories do
      stranger = account(directory: directory)

      assert {^directory, {:error, :wrong_directory}} =
               {directory,
                Directory.register(%{genesis: Entry.encode(stranger.genesis), source: source()})}

      assert stored() == before
      assert {:error, :not_found} = page(stranger.identifier)
    end
  end

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
      alice = account()

      assert {:error, :not_served} =
               Directory.register(%{genesis: Entry.encode(alice.genesis), source: source()})

      assert {:error, :not_served} = page(alice.identifier)
      assert {:error, :not_served} = after_hash(alice.identifier, alice.head)
      assert {:error, :not_served} = Directory.tombstone(alice.identifier)
    end

    test "a mirror answers read_only to every write, before it counts anything, and serves reads" do
      alice = register!(account())
      Sanctum.Test.Settings.put("directory_serve", "mirror")
      from = "198.51.100.7"

      assert {:error, :read_only} =
               Directory.register(%{genesis: Entry.encode(account().genesis), source: from})

      assert {:error, :read_only} =
               append(
                 alice,
                 entry(alice, kind: :add_key, key: device_key(elem(keypair(), 0))),
                 from
               )

      assert {:error, :read_only} = Directory.tombstone(alice.identifier)
      assert windows(:directory_source, from) == []
      assert {:ok, %{entries: [_genesis], next: nil, length: 1}} = page(alice.identifier)
    end
  end

  # ---- registration ------------------------------------------------------------

  describe "register/1" do
    test "answers the identifier a genesis hashes to, created once and exists after, naming the head" do
      alice = account()
      genesis = Entry.encode(alice.genesis)

      assert {:ok, %{identifier: id, seq: 0, entry_hash: hash, result: :created} = created} =
               Directory.register(%{genesis: genesis, source: source()})

      assert id == alice.identifier
      assert hash == alice.head
      refute Map.has_key?(created, :head)

      alice = with_device!(alice)

      assert {:ok, %{identifier: ^id, seq: 0, entry_hash: ^hash, result: :exists, head: head}} =
               Directory.register(%{genesis: genesis, source: source()})

      assert head == alice.head
      assert [%{seq: 0, entry: stored}, %{seq: 1}] = log(id)
      assert stored == Identity.canonical(alice.genesis)
    end

    test "refuses a genesis whose own signature does not verify, and anything not a genesis" do
      alice = account()
      {_pub, stranger} = keypair()
      forged = Identity.sign(alice.genesis, stranger)

      assert {:error, {:unverified, :wrong_signer}} =
               Directory.register(%{genesis: Entry.encode(forged), source: source()})

      added = entry(alice, kind: :add_key, key: device_key(elem(keypair(), 0)))

      assert {:error, {:invalid, :not_genesis}} =
               Directory.register(%{genesis: Entry.encode(added), source: source()})

      assert {:error, {:invalid, {:missing_field, "protocol"}}} =
               Directory.register(%{genesis: %{}, source: source()})

      assert log(alice.identifier) == []
    end

    test "refuses a genesis naming any directory but the one this node serves, storing nothing" do
      register!(account())

      # Another host; this host on another port or scheme; this host under
      # a path. The directory served is this node's origin and nothing else.
      refuses([
        "https://elsewhere.example",
        "https://dir.example:8443",
        "http://dir.example",
        "https://dir.example/directory"
      ])

      # The served directory is read from the node's origin as it stands.
      serve_at("https://elsewhere.example")
      register!(account(directory: "https://elsewhere.example"))

      assert {:error, :wrong_directory} =
               Directory.register(%{genesis: Entry.encode(account().genesis), source: source()})
    end

    test "a local home on port 80, whose origin is http://localhost:80, registers a genesis " <>
           "naming http://localhost" do
      serve_locally_at("http://localhost:80")
      assert Sanctum.origin() == "http://localhost:80"

      # A genesis cannot name the origin as configured: its directory is
      # in the one spelling, which drops the scheme's default port.
      refute Prima.Identity.Encoding.directory_url?("http://localhost:80")

      register!(account(directory: "http://localhost"))
    end

    test "serves its origin with the scheme's default port dropped, and still refuses another " <>
           "scheme, host, port or path, storing nothing" do
      for {serve, origin, served, others} <- [
            {&serve_locally_at/1, "http://localhost:80", "http://localhost",
             [
               "https://localhost",
               "http://elsewhere.example",
               "http://localhost:4000",
               "http://localhost/directory"
             ]},
            {&serve_at/1, "https://dir.example:443", "https://dir.example",
             [
               "http://dir.example",
               "https://elsewhere.example",
               "https://dir.example:8443",
               "https://dir.example/directory"
             ]}
          ] do
        serve.(origin)
        genesis = Entry.encode(account(directory: served).genesis)

        assert {^origin, {:ok, %{seq: 0}}} =
                 {origin, Directory.register(%{genesis: genesis, source: source()})}

        refuses(others)
      end
    end

    test "serves no directory when its origin is not a home, refusing every genesis" do
      serve_at("https://dir.example/cyfr")
      refuses(["https://dir.example/cyfr", "https://dir.example"])
    end

    test "refuses a new genesis at the identity quota, retryably, and still answers an old one" do
      alice = register!(account())
      Sanctum.Test.Settings.put("directory_max_identities", 1)

      assert {:error, {:capacity, :identities}} =
               Directory.register(%{genesis: Entry.encode(account().genesis), source: source()})

      assert {:ok, %{identifier: id, result: :exists}} =
               Directory.register(%{genesis: Entry.encode(alice.genesis), source: source()})

      assert id == alice.identifier
    end

    test "admits at most 5 registrations a minute from one address, before decoding any" do
      from = "198.51.100.20"

      for _ <- 1..5 do
        assert {:error, {:invalid, _}} = Directory.register(%{genesis: %{}, source: from})
      end

      assert {:error, {:rate_limited, seconds}} =
               Directory.register(%{genesis: Entry.encode(account().genesis), source: from})

      assert seconds in 1..60

      assert {:ok, _} =
               Directory.register(%{genesis: Entry.encode(account().genesis), source: source()})
    end

    test "the installation's bound of 100 a minute holds across members, from many addresses" do
      for n <- 1..100 do
        assert {:error, {:invalid, _}} =
                 Directory.register(%{genesis: %{}, source: "192.0.2.#{n}"})
      end

      alice = account()
      genesis = Entry.encode(alice.genesis)

      assert {:error, {:rate_limited, _}} =
               Directory.register(%{genesis: genesis, source: "198.51.100.101"})

      # A second member counts from nothing: its own counter admits the
      # request, and the window every member shares refuses it.
      Prima.Test.RateLimiter.reset!()

      assert {:error, {:rate_limited, _}} =
               Directory.register(%{genesis: genesis, source: "198.51.100.102"})

      assert log(alice.identifier) == []
    end
  end

  # ---- appends -----------------------------------------------------------------

  describe "append/2" do
    test "appends an entry that extends the head, verified against the head's state" do
      alice = register!(account())
      entry = entry(alice, kind: :add_key, key: device_key(elem(keypair(), 0)))

      assert {:ok, %{seq: 1, entry_hash: hash, result: :accepted}} = append(alice, entry)
      assert hash == Identity.hash(entry)
      assert [%{seq: 0}, %{seq: 1, entry_hash: ^hash}] = log(alice.identifier)
    end

    test "an entry naming a head that is no longer current is stale, with the current head" do
      alice = register!(account()) |> with_device!()
      moved = key_write!(alice)
      late = key_entry(alice)

      assert {:error, {:stale_head, head}} = append(alice, late)
      assert head == moved.head
      assert length(log(alice.identifier)) == 3
    end

    test "an exact retry answers exists with the head, appends nothing and spends nothing" do
      alice = register!(account()) |> with_device!()
      written = key_entry(alice)
      alice = append!(alice, written)
      moved = key_write!(alice)
      before = windows(:directory_writes_daily, alice.identifier)

      assert {:ok, %{result: :exists, seq: 2, entry_hash: hash, head: head}} =
               append(alice, written)

      assert hash == Identity.hash(written)
      assert head == moved.head
      assert length(log(alice.identifier)) == 4
      assert windows(:directory_writes_daily, alice.identifier) == before
    end

    test "a key listed twice is duplicate_key, and a key signing that the log does not list is unverified" do
      alice = register!(account()) |> with_device!()
      {pub, _} = alice.device

      assert {:error, :duplicate_key} =
               append(alice, entry(alice, kind: :add_key, key: device_key(pub)))

      {_pub, stranger} = keypair()

      forged =
        entry(alice, [kind: :add_key, key: device_key(elem(keypair(), 0))],
          by: alice.device,
          sign_with: stranger
        )

      assert {:error, {:unverified, :wrong_signer}} = append(alice, forged)
      assert {:error, {:invalid, :unexpected_genesis}} = append(alice, alice.genesis)
      assert length(log(alice.identifier)) == 2
    end

    test "invalid signatures spend nothing of the identifier's allowance" do
      alice = register!(account())
      {_pub, stranger} = keypair()

      for _ <- 1..60 do
        forged =
          entry(alice, [kind: :add_key, key: device_key(elem(keypair(), 0))], sign_with: stranger)

        assert {:error, {:unverified, :wrong_signer}} = append(alice, forged)
      end

      assert windows(:directory_signed, alice.identifier) == []
      assert windows(:directory_writes_daily, alice.identifier) == []
      alice = with_device!(alice)
      assert [%{count: 1}] = windows(:directory_signed, alice.identifier)
      assert windows(:directory_writes_daily, alice.identifier) == []
      assert %{seq: 2} = key_write!(alice)
      assert [%{count: 1}] = windows(:directory_writes_daily, alice.identifier)
    end

    test "a listed key's writes stop at 100 a day, in a window every member shares, and a recovery key's are exempt" do
      alice =
        register!(account()) |> with_device!() |> key_write!() |> key_write!() |> key_write!()

      assert [%{count: 3, window_ms: 86_400_000}] =
               windows(:directory_writes_daily, alice.identifier)

      # The rest of the day's budget, spent as 97 more writes would.
      for _ <- 1..97 do
        :ok =
          Arca.RequestRateWindows.claim(
            Prima.Actor.system(),
            :directory_writes_daily,
            alice.identifier,
            100,
            86_400_000
          )
      end

      late = key_entry(alice)

      assert {:error, {:capacity, :writes, seconds}} = append(alice, late)
      assert seconds > 86_000 and seconds <= 86_400

      # A second member counts from nothing: its own counter admits the
      # write, and the window every member shares refuses it.
      Prima.Test.RateLimiter.reset!()
      assert {:error, {:capacity, :writes, _}} = append(alice, late)
      assert length(log(alice.identifier)) == 5

      removal = entry(alice, kind: :remove_key, kid: Key.kid(elem(alice.device, 0)))
      assert %{seq: 5} = append!(alice, removal)
    end

    test "a listed key's writes stop at 50 a minute, and a recovery key still has its reserve" do
      alice = register!(account()) |> with_device!()
      alice = Enum.reduce(1..49, alice, fn _, account -> key_write!(account) end)

      assert {:error, {:rate_limited, _}} = append(alice, key_entry(alice))

      removal = entry(alice, kind: :remove_key, kid: Key.kid(elem(alice.device, 0)))
      assert %{seq: 51} = append!(alice, removal)
    end

    test "an unknown identifier is not found, and a malformed one is not found either" do
      alice = account()
      added = entry(alice, kind: :add_key, key: device_key(elem(keypair(), 0)))

      assert {:error, :not_found} = append(alice, added)

      assert {:error, :not_found} =
               Directory.append("per_nope", %{entry: Entry.encode(added), source: source()})
    end

    test "a stored state that no longer decodes is never extended" do
      alice = register!(account())
      bogus = ~s({"not":"an entry"})

      {:ok, _row, :accepted} =
        Arca.IdentityLog.append(
          Prima.Actor.system(),
          alice.identifier,
          %{
            entry: bogus,
            entry_hash: Prima.Digest.sha256(bogus),
            prev_hash: alice.head,
            kind: "add_key",
            state: "{}",
            recovery: true
          },
          @policy
        )

      alice = %{alice | head: Prima.Digest.sha256(bogus), seq: 1}

      log =
        capture_log(fn ->
          assert {:error, :corrupt} =
                   append(
                     alice,
                     entry(alice, kind: :add_key, key: device_key(elem(keypair(), 0)))
                   )
        end)

      assert log =~ "does not verify"
      assert length(log(alice.identifier)) == 2
    end
  end

  # ---- reads -------------------------------------------------------------------

  describe "from/1" do
    test "answers the entries after an entry's hash, none at the head, and not_found for any other hash" do
      alice = register!(account()) |> with_device!()
      at = alice.head
      alice = key_write!(alice)

      assert {:ok, %{from: 2, entries: [entry], next: nil, length: 3, head: head}} =
               after_hash(alice.identifier, at)

      assert head == alice.head
      assert {:ok, %Entry{kind: :add_key}} = entry |> Jason.decode!() |> Entry.decode()

      assert {:ok, %{from: 3, entries: [], next: nil, length: 3}} =
               after_hash(alice.identifier, alice.head)

      assert {:error, :not_found} = after_hash(alice.identifier, Prima.Digest.sha256("elsewhere"))
      assert {:error, :not_found} = after_hash(alice.identifier, "sha256:nope")
      assert {:error, :not_found} = after_hash(account().identifier, at)
    end
  end

  describe "resolve/1" do
    test "pages hold at most 64 KiB of entries, and link by next, head and length" do
      # Each recovery lists 64 device keys, about 9 KiB an entry: the
      # genesis and nine of them make two pages.
      alice = register!(account())

      alice =
        Enum.reduce(1..9, alice, fn _, account ->
          keys = for _ <- 1..64, do: device_key(elem(keypair(), 0))
          {recovery_pub, _} = account.recovery
          append!(account, entry(account, kind: :recover, keys: keys, recovery: [recovery_pub]))
        end)

      assert {:ok, first} = page(alice.identifier)
      assert %{from: 0, length: 10} = first
      assert is_integer(first.next)
      assert first.head == alice.head
      assert Enum.sum(Enum.map(first.entries, &(byte_size(&1) + 1))) <= 65_536 - 1_024

      assert {:ok, second} = page(alice.identifier, first.next)
      assert second.from == first.next + 1
      assert second.next == nil
      assert length(first.entries) + length(second.entries) == 10

      entries = Enum.map(first.entries ++ second.entries, &Jason.decode!/1)
      assert {:ok, %{head: head, seq: 9}} = Identity.verify_chain(entries)
      assert head == alice.head
    end

    test "an unknown identifier is not found, and a position outside the log's range is invalid" do
      assert {:error, :not_found} = page(account().identifier)
      alice = register!(account())
      from = "198.51.100.78"

      for position <- [-2, 2_147_483_648, 99_999_999_999_999_999_999_999] do
        assert {:error, {:invalid, {:invalid_field, "after"}}} =
                 Directory.resolve(%{identifier: alice.identifier, after: position, source: from})
      end

      assert windows(:directory_source, from) == []
      assert {:ok, %{entries: [], next: nil, length: 1}} = page(alice.identifier, 0)
    end
  end

  # ---- the tombstone -----------------------------------------------------------

  describe "tombstone/1" do
    test "a tombstoned account is gone to every read and write, its entries kept" do
      alice = register!(account()) |> with_device!()

      assert :ok = Directory.tombstone(alice.identifier)
      assert :ok = Directory.tombstone(alice.identifier)

      assert {:error, :gone} = page(alice.identifier)
      assert {:error, :gone} = after_hash(alice.identifier, alice.head)
      assert {:error, :gone} = append(alice, key_entry(alice))

      assert {:error, :gone} =
               Directory.register(%{genesis: Entry.encode(alice.genesis), source: source()})

      assert length(log(alice.identifier)) == 2
      assert {:error, :not_found} = Directory.tombstone(account().identifier)
      assert {:error, :not_found} = Directory.tombstone("per_nope")
    end
  end
end
