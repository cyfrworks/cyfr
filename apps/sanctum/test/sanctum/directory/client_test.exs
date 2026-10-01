# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.ClientTest do
  @moduledoc """
  The home's client for any directory, against scripted directories that
  speak HTTPS under a test authority on loopback, named by a test resolver.

  The directory is the one the genesis names, and a genesis that does not
  hash to the identifier makes no request; the transport is HTTPS, pinned
  under the operator's private-address policy, never redirected, never
  unverified; a resolution verifies every linked page and the whole chain
  before it caches anything, and moves the cache only along the chain.
  """

  # The private-egress configuration, the resolver's observer, this
  # member's rate counters and the head cache are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.DirectoryHead
  alias Prima.Identity
  alias Prima.Identity.{Entry, RecoverRequest}
  alias Sanctum.Directory.Client
  alias Sanctum.Test.DirectoryServer
  alias Sanctum.Test.DirectoryServer.{Resolver, Server}

  @hosts ~w(dir-a.test dir-b.test loopback.test metadata.test)

  setup_all do
    %{tls: DirectoryServer.tls(@hosts)}
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    targets = Application.fetch_env(:sanctum, :private_egress_targets)

    # The test directories are on loopback, which the operator lists by
    # name, as a deployment names a directory on its own network.
    Application.put_env(:sanctum, :private_egress_targets, [
      "dir-a.test",
      "dir-b.test",
      "metadata.test"
    ])

    :persistent_term.put({Resolver, :observer}, self())

    on_exit(fn ->
      case targets do
        {:ok, value} -> Application.put_env(:sanctum, :private_egress_targets, value)
        :error -> Application.delete_env(:sanctum, :private_egress_targets)
      end

      :persistent_term.erase({Resolver, :observer})
      Prima.RateLimiter.reset()
    end)

    # The logs the scripted directories serve, by identifier.
    {:ok, logs} = Agent.start_link(fn -> %{} end)
    %{logs: logs}
  end

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp directory(%{tls: tls}, host, handler) do
    server = Server.start(tls[:server_config], handler, self())
    on_exit(fn -> Server.stop(server) end)
    url = "https://#{host}:#{server.port}"
    %{url: url, origin: url, server: server}
  end

  defp opts(%{tls: tls}), do: [resolver: Resolver, cacerts: tls[:client_config][:cacerts]]

  defp person(url) do
    {live, _} = keypair()
    {op_pub, op_priv} = keypair()
    {rec_pub, rec_priv} = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: op_pub,
        recovery_keys: [rec_pub],
        directory: url
      )

    genesis = Identity.sign(genesis, op_priv)

    %{
      genesis: genesis,
      identifier: Identity.identifier(genesis),
      operational: op_priv,
      recovery: rec_priv,
      url: url,
      log: [Entry.encode(genesis)],
      head: Identity.hash(genesis)
    }
  end

  defp rotation(person, prev \\ nil) do
    {live, _} = keypair()
    {:ok, entry} = Entry.rotate(prev || person.head, live)
    Identity.sign(entry, person.operational)
  end

  defp rotated(person, count) do
    Enum.reduce(1..count, person, fn _, person ->
      entry = rotation(person)
      %{person | log: person.log ++ [Entry.encode(entry)], head: Identity.hash(entry)}
    end)
  end

  defp request(person, request_id \\ "req_1") do
    {live, _} = keypair()
    {op, _} = keypair()

    {:ok, request} =
      RecoverRequest.new(
        identifier: person.identifier,
        directory: person.url,
        live_key: live,
        operational_key: op,
        expected_revision: 0,
        request_id: request_id
      )

    Identity.sign(request, person.recovery)
  end

  defp genesis(person), do: Entry.encode(person.genesis)

  defp json(status, body, headers \\ []),
    do: {status, [{"content-type", "application/json"} | headers], Jason.encode!(body)}

  # Publish what a scripted directory serves for `person`: their log, and
  # how it is tampered with (`:truncate` stops one entry short of the head
  # and length it names, `:reorder` swaps two entries, `:unlinked` names a
  # `next` past its page's last entry).
  defp publish(%{logs: logs}, person, tamper \\ nil) do
    Agent.update(logs, &Map.put(&1, person.identifier, {person.log, tamper}))
    person
  end

  # A directory serving the published logs in pages of 100, as the
  # directory does.
  defp serving(%{logs: logs}) do
    fn %{method: "GET", target: target} ->
      %URI{path: path, query: query} = URI.parse(target)
      identifier = path |> String.split("/") |> List.last()
      after_seq = String.to_integer(URI.decode_query(query || "")["after"])

      case Agent.get(logs, &Map.get(&1, identifier)) do
        nil ->
          json(404, %{"error" => "not_found"})

        {log, tamper} ->
          served = tampered(log, tamper)
          page = served |> Enum.drop(after_seq + 1) |> Enum.take(100)
          last = after_seq + length(page)
          next = if last < length(served) - 1, do: last, else: nil
          next = if tamper == :unlinked and next, do: next + 1, else: next
          {:ok, head} = log |> List.last() |> Entry.decode()

          json(200, %{
            "identifier" => identifier,
            "from" => after_seq + 1,
            "entries" => page,
            "next" => next,
            "head" => Identity.hash(head),
            "length" => length(log)
          })
      end
    end
  end

  defp tampered(log, :truncate), do: Enum.drop(log, -1)
  defp tampered([genesis, first, second | rest], :reorder), do: [genesis, second, first | rest]
  defp tampered(log, _tamper), do: log

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  defp cached_row(identifier), do: Arca.Repo.get(DirectoryHead, identifier)

  # ---- before any request ------------------------------------------------------

  describe "the directory is the one the genesis names" do
    test "a genesis that does not hash to the identifier makes no request", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> flunk("no request is made") end)
      alice = person(dir.url)
      bob = person(dir.url)

      assert {:error, :identifier_mismatch} =
               Client.resolve(bob.identifier, genesis(alice), opts(ctx))

      assert {:error, :identifier_mismatch} =
               Client.register(bob.identifier, genesis(alice), opts(ctx))

      assert {:error, :identifier_mismatch} =
               Client.append(bob.identifier, genesis(alice), rotation(alice), opts(ctx))

      assert {:error, :identifier_mismatch} =
               Client.recover(bob.identifier, genesis(alice), request(alice), opts(ctx))

      assert {:error, :identifier_mismatch} =
               Client.outcome(bob.identifier, genesis(alice), "req_1", opts(ctx))

      refute_received {:resolved, _}
      assert requests() == []
    end

    test "an oversize or malformed genesis makes no request", ctx do
      alice = person("https://dir-a.test")

      assert {:error, :too_large} =
               Client.resolve(alice.identifier, String.duplicate(" ", 16_385), opts(ctx))

      assert {:error, :invalid_json} = Client.resolve(alice.identifier, "not json", opts(ctx))
      refute_received {:resolved, _}
    end

    test "a directory spoken to over plain HTTP is refused before any lookup", ctx do
      alice = person("http://dir-a.test")

      assert {:error, :insecure_directory} =
               Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      refute_received {:resolved, _}
    end

    test "the options are the resolver and the trusted certificates, and nothing else", ctx do
      alice = person("https://dir-a.test")

      assert_raise ArgumentError, fn ->
        Client.resolve(alice.identifier, genesis(alice), [verify: :verify_none] ++ opts(ctx))
      end

      assert_raise ArgumentError, fn ->
        Client.resolve(alice.identifier, genesis(alice), private_policy: :allow_all)
      end

      refute_received {:resolved, _}
    end

    test "a recovery for another identifier or directory is refused before any request", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> flunk("no request is made") end)
      alice = person(dir.url)
      bob = person(dir.url)

      assert {:error, :wrong_identifier} =
               Client.recover(bob.identifier, genesis(bob), request(alice), opts(ctx))

      moved = request(%{alice | url: "https://dir-b.test"})

      assert {:error, :directory_changed} =
               Client.recover(alice.identifier, genesis(alice), moved, opts(ctx))

      assert requests() == []
    end
  end

  # ---- the transport -----------------------------------------------------------

  describe "the transport" do
    test "a loopback address the operator did not list is refused before connecting", ctx do
      dir = directory(ctx, "loopback.test", fn _ -> flunk("no connection is made") end)
      alice = person(dir.url)

      log =
        capture_log(fn ->
          assert {:error, :egress_refused} =
                   Client.resolve(alice.identifier, genesis(alice), opts(ctx))
        end)

      assert log =~ "private IP 127.0.0.1 blocked"
      assert_received {:resolved, "loopback.test"}
      assert requests() == []
    end

    test "a metadata address is refused even when the operator lists its name", ctx do
      alice = person("https://metadata.test")

      log =
        capture_log(fn ->
          assert {:error, :egress_refused} =
                   Client.resolve(alice.identifier, genesis(alice), opts(ctx))
        end)

      assert log =~ "metadata IP 169.254.169.254 blocked"
      assert_received {:resolved, "metadata.test"}
    end

    test "a redirect is refused, and never followed", ctx do
      elsewhere = directory(ctx, "dir-b.test", fn _ -> flunk("a redirect is never followed") end)

      dir =
        directory(ctx, "dir-a.test", fn _ ->
          {302, [{"location", elsewhere.url <> "/directory/v1/x"}], ""}
        end)

      alice = person(dir.url)

      assert {:error, :redirected} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))
      assert [%{target: "/directory/v1/" <> _}] = requests()
      refute_received {:resolved, "dir-b.test"}
      assert cached_row(alice.identifier) == nil
    end

    test "a certificate the home does not trust is refused: verification is not optional",
         ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url))

      log =
        capture_log(fn ->
          assert {:error, :unreachable} =
                   Client.resolve(alice.identifier, genesis(alice), resolver: Resolver)
        end)

      assert log =~ "unknown_ca"
      assert requests() == []
      assert cached_row(alice.identifier) == nil
    end

    test "sends the canonical genesis with no credential, and names itself", ctx do
      dir =
        directory(ctx, "dir-a.test", fn %{body: body} ->
          {:ok, entry} = body |> Jason.decode!() |> Entry.decode()

          json(200, %{
            "identifier" => Identity.identifier(entry),
            "seq" => 0,
            "entry_hash" => Identity.hash(entry)
          })
        end)

      alice = person(dir.url)

      assert {:ok, %{identifier: id, seq: 0, entry_hash: hash}} =
               Client.register(alice.identifier, genesis(alice), opts(ctx))

      assert id == alice.identifier and hash == alice.head

      assert [%{method: "POST", target: "/directory/v1/genesis", headers: headers, body: body}] =
               requests()

      assert body == Identity.canonical(alice.genesis)
      refute Enum.any?(headers, fn {name, _} -> Prima.Network.credential_header?(name) end)
      assert {"user-agent", "CYFR/" <> _} = List.keyfind(headers, "user-agent", 0)
    end

    test "this member sheds its own requests to one directory past 300 a minute", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> flunk("a shed request is never sent") end)
      alice = person(dir.url)

      for _ <- 1..300, do: :ok = Prima.RateLimiter.check({Client, dir.origin}, 300, 60_000)

      assert {:error, {:rate_limited, seconds}} =
               Client.register(alice.identifier, genesis(alice), opts(ctx))

      assert seconds in 1..60
      assert requests() == []
    end

    @tag timeout: 60_000
    test "a directory that never answers is abandoned at the request's bound", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> :hang end)
      alice = person(dir.url)
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 9_000 and elapsed < 15_000
      assert cached_row(alice.identifier) == nil
    end
  end

  # ---- resolution --------------------------------------------------------------

  describe "resolve/3" do
    test "a caller passing no options reaches a directory only through the suite's seam", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url))

      # With no seam, the system's resolver knows no test directory.
      assert {:error, :unreachable} = Client.resolve(alice.identifier, genesis(alice))

      DirectoryServer.seam!(ctx.tls)

      assert {:ok, %{state: %{identifier: identifier}}} =
               Client.resolve(alice.identifier, genesis(alice))

      assert identifier == alice.identifier
    end

    test "reads every linked page, verifies the whole chain and caches its head", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = ctx |> publish(person(dir.url) |> rotated(149))

      assert {:ok, %{state: state, head: row, retired: retired}} =
               Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      assert state.length == 150
      assert state.head == alice.head
      assert state.identifier == alice.identifier
      assert row.head_hash == alice.head and row.key_epoch == state.key_epoch
      assert row.directory_url == dir.url
      assert row.genesis == Identity.canonical(alice.genesis)
      assert Enum.all?(Map.values(retired), &(&1 == []))

      assert Enum.map(requests(), & &1.target) == [
               "/directory/v1/#{alice.identifier}?after=-1",
               "/directory/v1/#{alice.identifier}?after=99"
             ]

      assert {:ok, %{state: ^state}} = Client.cached(alice.identifier)
    end

    test "the same head again is touched; a longer log advances the cache", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url) |> rotated(2))

      assert {:ok, %{head: first}} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))
      assert {:ok, %{head: again}} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))
      assert again.head_hash == first.head_hash and again.revision == first.revision
      assert DateTime.compare(again.verified_at, first.verified_at) in [:gt, :eq]

      alice = publish(ctx, rotated(alice, 1))

      assert {:ok, %{state: state, head: moved, retired: retired}} =
               Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      assert moved.head_hash == alice.head and state.head == alice.head
      assert moved.key_epoch != first.key_epoch
      # An ordinary rotation leaves the recovery epoch: the genesis's.
      assert moved.recovery_epoch == first.recovery_epoch
      assert moved.recovery_epoch == Identity.hash(alice.genesis)
      assert moved.revision == first.revision + 1

      assert %{session_hashes: [], passkey_ids: [], certificate_ids: [], confirmation_ids: []} =
               retired
    end

    test "a log that does not contain the cached head is refused, and the cache stays", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url) |> rotated(1))
      assert {:ok, %{head: cached}} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      # Another rotation after the genesis: a history that forks from the
      # one this home verified.
      [genesis_map, _first] = alice.log
      fork = rotation(alice, Identity.hash(alice.genesis))

      publish(ctx, %{alice | log: [genesis_map, Entry.encode(fork)], head: Identity.hash(fork)})

      log =
        capture_log(fn ->
          assert {:error, :not_descendant} =
                   Client.resolve(alice.identifier, genesis(alice), opts(ctx))
        end)

      assert log =~ "does not contain the head this home verified"
      assert cached_row(alice.identifier).head_hash == cached.head_hash
    end

    test "a truncated log caches no head", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url) |> rotated(120), :truncate)

      assert {:error, :truncated} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))
      assert cached_row(alice.identifier) == nil
    end

    test "a reordered log caches no head", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url) |> rotated(3), :reorder)

      assert {:error, {:unverified, :broken_link}} =
               Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      assert cached_row(alice.identifier) == nil
    end

    test "a page whose next does not link to its own last entry caches no head", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url) |> rotated(120), :unlinked)

      assert {:error, :invalid_page} =
               Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      assert cached_row(alice.identifier) == nil
    end

    test "two people on different directories resolve independently, each at their own", ctx do
      a = directory(ctx, "dir-a.test", serving(ctx))
      b = directory(ctx, "dir-b.test", serving(ctx))
      alice = publish(ctx, person(a.url) |> rotated(1))
      bob = publish(ctx, person(b.url) |> rotated(2))

      assert {:ok, %{head: %{directory_url: a_url}}} =
               Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      assert_received {:resolved, "dir-a.test"}
      refute_received {:resolved, "dir-b.test"}

      assert {:ok, %{head: %{directory_url: b_url}}} =
               Client.resolve(bob.identifier, genesis(bob), opts(ctx))

      assert_received {:resolved, "dir-b.test"}
      refute_received {:resolved, "dir-a.test"}
      assert {a_url, b_url} == {a.url, b.url}

      assert [
               %{headers: alice_headers, target: "/directory/v1/" <> alice_path},
               %{headers: bob_headers, target: "/directory/v1/" <> bob_path}
             ] = requests()

      assert String.starts_with?(alice_path, alice.identifier)
      assert String.starts_with?(bob_path, bob.identifier)
      assert {"host", "dir-a.test:" <> _} = List.keyfind(alice_headers, "host", 0)
      assert {"host", "dir-b.test:" <> _} = List.keyfind(bob_headers, "host", 0)
    end
  end

  describe "genesis/3" do
    test "reads the log's first entry and holds it to the identifier and the directory", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = ctx |> publish(person(dir.url) |> rotated(2))

      assert {:ok, bytes} = Client.genesis(alice.identifier, dir.url, opts(ctx))
      assert bytes == Identity.canonical(alice.genesis)
      assert {:ok, _} = Client.resolve(alice.identifier, bytes, opts(ctx))

      assert [%{target: "/directory/v1/" <> rest} | _] = requests()
      assert rest == alice.identifier <> "?after=-1"
    end

    test "a genesis naming another directory than the one given is refused", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      elsewhere = person("https://dir-b.test")
      Agent.update(ctx.logs, &Map.put(&1, elsewhere.identifier, {elsewhere.log, nil}))

      assert {:error, :directory_mismatch} =
               Client.genesis(elsewhere.identifier, dir.url, opts(ctx))
    end

    test "a log whose first entry does not hash to the identifier is refused", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = person(dir.url)
      bob = person(dir.url)
      Agent.update(ctx.logs, &Map.put(&1, alice.identifier, {bob.log, nil}))

      assert {:error, :identifier_mismatch} =
               Client.genesis(alice.identifier, dir.url, opts(ctx))
    end

    test "an unknown identifier is not found, and a malformed locator makes no request", ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = person(dir.url)

      assert {:error, :not_found} = Client.genesis(alice.identifier, dir.url, opts(ctx))

      _ = requests()
      assert {:error, :invalid_locator} = Client.genesis("per_nope", dir.url, opts(ctx))
      assert {:error, :invalid_locator} = Client.genesis(alice.identifier, "ftp://x", opts(ctx))

      assert {:error, :insecure_directory} =
               Client.genesis(alice.identifier, "http://dir-a.test", opts(ctx))

      assert requests() == []
    end
  end

  describe "cached/1" do
    test "decodes the verified state it stored, and refuses one that does not match its row",
         ctx do
      dir = directory(ctx, "dir-a.test", serving(ctx))
      alice = publish(ctx, person(dir.url) |> rotated(1))
      assert {:ok, %{state: state}} = Client.resolve(alice.identifier, genesis(alice), opts(ctx))

      assert {:ok, %{state: ^state, head: %{head_hash: head} = row}} =
               Client.cached(alice.identifier)

      assert head == state.head

      # The cache carries the recovery epoch beside the key epoch, and a
      # row read back as a state names both.
      assert row.recovery_epoch == state.recovery_epoch
      assert row.key_epoch == state.key_epoch
      assert {:ok, ^state} = Client.state(row)

      # A row whose recovery epoch is not its state's does not decode.
      assert {:error, :corrupt} =
               Client.state(%{row | recovery_epoch: "sha256:" <> String.duplicate("1", 64)})

      tampered =
        Jason.encode!(%{
          Prima.Identity.State.encode(state)
          | "head" => "sha256:" <> String.duplicate("0", 64)
        })

      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^alice.identifier),
        set: [state: tampered]
      )

      assert {:error, :corrupt} = Client.cached(alice.identifier)
      assert {:error, :not_found} = Client.cached(person(dir.url).identifier)
    end
  end

  # ---- the writes --------------------------------------------------------------

  describe "the directory's answers" do
    test "each refusal is decoded, with its bound when it is retryable", ctx do
      stale = "sha256:" <> String.duplicate("a", 64)
      recorded = %{"outcome" => "stale_policy", "expected_revision" => 0, "revision" => 1}

      answers = %{
        "/directory/v1/genesis" =>
          json(503, %{"error" => "capacity", "exhausted" => "identities"}, [{"retry-after", "60"}])
      }

      dir =
        directory(ctx, "dir-a.test", fn %{target: target} ->
          case {target, answers[target]} do
            {_, answer} when answer != nil ->
              answer

            {"/directory/v1/" <> rest, nil} ->
              cond do
                String.ends_with?(rest, "/entries") ->
                  json(409, %{"error" => "stale_head", "head" => stale})

                String.ends_with?(rest, "/recover") ->
                  json(409, %{"error" => "stale_policy", "recorded" => recorded})

                true ->
                  json(404, %{"error" => "not_found"})
              end
          end
        end)

      alice = person(dir.url)

      assert {:error, {:capacity, 60}} =
               Client.register(alice.identifier, genesis(alice), opts(ctx))

      assert {:error, {:stale_head, ^stale}} =
               Client.append(alice.identifier, genesis(alice), rotation(alice), opts(ctx))

      assert {:error, {:stale_policy, ^recorded}} =
               Client.recover(alice.identifier, genesis(alice), request(alice), opts(ctx))

      assert {:error, :not_found} =
               Client.outcome(alice.identifier, genesis(alice), "req_9", opts(ctx))
    end

    test "rate limits, mirrors, refusals and an unserved directory are decoded", ctx do
      answers = [
        json(429, %{"error" => "rate_limited", "retry_after" => 7}, [{"retry-after", "7"}]),
        json(405, %{"error" => "read_only"}, [{"allow", "GET"}]),
        json(422, %{"error" => "unverified", "reason" => "wrong_signer"}),
        json(422, %{"error" => "wrong_identifier"}),
        json(422, %{"error" => "invalid", "reason" => "Not A Word!"}),
        json(404, %{"error" => "not_served"}),
        json(503, %{"error" => "busy"}, [{"retry-after", "1"}]),
        json(503, %{"error" => "capacity", "exhausted" => "rotations"}, [
          {"retry-after", "86000"}
        ]),
        json(503, %{"error" => "capacity", "exhausted" => "rotations"}, [
          {"retry-after", "999999"}
        ]),
        {413, [], ~s({"errors":{"detail":"Request Entity Too Large"}})}
      ]

      {:ok, script} = Agent.start_link(fn -> answers end)

      dir =
        directory(ctx, "dir-a.test", fn _ ->
          Agent.get_and_update(script, fn [answer | rest] -> {answer, rest} end)
        end)

      alice = person(dir.url)

      append = fn ->
        Client.append(alice.identifier, genesis(alice), rotation(alice), opts(ctx))
      end

      assert {:error, {:rate_limited, 7}} = append.()
      assert {:error, :read_only} = append.()
      assert {:error, {:refused, :unverified, "wrong_signer"}} = append.()
      assert {:error, {:refused, :wrong_identifier, nil}} = append.()
      assert {:error, {:refused, :invalid, nil}} = append.()
      assert {:error, :not_served} = append.()
      assert {:error, {:busy, 1}} = append.()
      # A day's rotations: the wait is the window's, and never past a day.
      assert {:error, {:capacity, 86_000}} = append.()
      assert {:error, {:capacity, 86_400}} = append.()
      assert {:error, :body_too_large} = append.()
    end

    test "an accepted answer is held to what was sent", ctx do
      {:ok, mode} = Agent.start_link(fn -> :honest end)

      dir =
        directory(ctx, "dir-a.test", fn %{body: body, target: target} ->
          {:ok, request} = body |> Jason.decode!() |> RecoverRequest.decode()
          [_, _, _, identifier | _] = String.split(target, "/")
          prev = "sha256:" <> String.duplicate("b", 64)

          request =
            if Agent.get(mode, & &1) == :swapped,
              do: %{request | request_id: "req_other"},
              else: request

          {:ok, entry} = Entry.recover(prev, request)

          json(200, %{
            "identifier" => identifier,
            "seq" => 1,
            "entry_hash" => Identity.hash(entry),
            "entry" => Entry.encode(entry)
          })
        end)

      alice = person(dir.url)
      sent = request(alice)

      assert {:ok, %{seq: 1, entry: %Entry{kind: :recover, request: ^sent}}} =
               Client.recover(alice.identifier, genesis(alice), sent, opts(ctx))

      Agent.update(mode, fn _ -> :swapped end)

      assert {:error, :invalid_response} =
               Client.recover(alice.identifier, genesis(alice), sent, opts(ctx))
    end

    test "a recorded outcome is decoded, accepted or refused", ctx do
      {:ok, holder} = Agent.start_link(fn -> nil end)

      dir =
        directory(ctx, "dir-a.test", fn %{target: target} ->
          {person, request} = Agent.get(holder, & &1)
          digest = Identity.request_digest(request)

          case String.split(target, "/") |> List.last() do
            "req_1" ->
              {:ok, entry} = Entry.recover(person.head, request)

              json(200, %{
                "identifier" => person.identifier,
                "request_id" => "req_1",
                "request_digest" => digest,
                "outcome" => "accepted",
                "seq" => 1,
                "entry_hash" => Identity.hash(entry),
                "entry" => Entry.encode(entry)
              })

            "req_2" ->
              json(200, %{
                "identifier" => person.identifier,
                "request_id" => "req_2",
                "request_digest" => digest,
                "outcome" => "stale_policy",
                "recorded" => %{"outcome" => "stale_policy"}
              })
          end
        end)

      alice = person(dir.url)
      Agent.update(holder, fn _ -> {alice, request(alice)} end)

      assert {:ok, %{outcome: :accepted, seq: 1, entry: %Entry{kind: :recover}}} =
               Client.outcome(alice.identifier, genesis(alice), "req_1", opts(ctx))

      assert {:ok, %{outcome: :stale_policy, recorded: %{"outcome" => "stale_policy"}}} =
               Client.outcome(alice.identifier, genesis(alice), "req_2", opts(ctx))

      # An accepted record whose entry embeds another request is not taken.
      Agent.update(holder, fn {person, _} -> {person, request(alice, "req_other")} end)

      assert {:error, :invalid_response} =
               Client.outcome(alice.identifier, genesis(alice), "req_1", opts(ctx))
    end
  end
end
