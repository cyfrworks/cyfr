# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.ClientTest do
  @moduledoc """
  The home's client for any directory, `cyfr-directory/v2`, against
  scripted directories that speak HTTPS under a test authority on
  loopback, named by a test resolver.

  A genesis is registered at the directory it names; an entry, of any kind
  but a genesis, is appended; a log is read from its genesis or after an
  entry's hash, every page linked to the one before it. The transport is
  HTTPS, pinned under the operator's private-address policy, never
  redirected, never unverified. Each answer of the directory is decoded,
  `exists` naming the head and `gone` distinct from `not_found`, and a
  write's answer is held to what was sent.
  """

  # The private-egress configuration, the resolver's observer and this
  # member's rate counters are process-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.Directory.Client
  alias Sanctum.Test.DirectoryServer
  alias Sanctum.Test.DirectoryServer.{Resolver, Server}

  @hosts ~w(dir-a.test dir-b.test loopback.test metadata.test)

  # The bound on one directory request, as this build compiled it
  # (`config/test.exs` shortens it).
  @request_ms Application.compile_env(:sanctum, :directory_request_ms, 10_000)

  setup_all do
    %{tls: DirectoryServer.tls(@hosts)}
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    DirectoryServer.listen!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    :ok
  end

  # ---- fixtures ----------------------------------------------------------------

  defp opts(%{tls: tls}), do: DirectoryServer.opts(tls)

  defp directory(%{tls: tls}, host, handler) do
    server = Server.start(tls[:server_config], handler, self())
    on_exit(fn -> Server.stop(server) end)
    url = "https://#{host}:#{server.port}"
    %{url: url, origin: url, server: server}
  end

  # A scripted directory serving accounts, and one account there.
  defp serving(ctx) do
    dir = DirectoryServer.start!(ctx.tls)
    %{dir: dir, account: DirectoryServer.account!(dir.dir, dir.url)}
  end

  # An account no directory serves: its log composed for `url`.
  defp composed(url) do
    {:ok, agent} = Agent.start_link(fn -> %{logs: %{}, next: %{}, gone: MapSet.new()} end)
    DirectoryServer.account!(agent, url)
  end

  defp genesis(account), do: hd(account.log)
  defp last(account), do: List.last(account.log)

  defp json(status, body, headers \\ []),
    do: {status, [{"content-type", "application/json"} | headers], Jason.encode!(body)}

  defp requests, do: DirectoryServer.requests()

  # ---- before any request ------------------------------------------------------

  describe "before any request" do
    test "register takes a signed genesis and append any other signed entry", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> flunk("no request is made") end)
      alice = composed(dir.url)

      assert {:error, :invalid_entry} = Client.register(last(alice), opts(ctx))

      assert {:error, :invalid_entry} =
               Client.append(alice.identifier, dir.url, genesis(alice), opts(ctx))

      unsigned = %{last(alice) | sig: nil}

      assert {:error, :invalid_entry} =
               Client.append(alice.identifier, dir.url, Entry.encode(unsigned), opts(ctx))

      assert {:error, :invalid_entry} =
               Client.append(alice.identifier, dir.url, "not json", opts(ctx))

      refute_received {:resolved, _}
      assert requests() == []
    end

    test "a malformed identifier, directory or hash makes no request", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> flunk("no request is made") end)
      alice = composed(dir.url)
      head = DirectoryServer.head(alice)

      assert {:error, :invalid_locator} = Client.log("usr_x", dir.url, opts(ctx))
      assert {:error, :invalid_locator} = Client.log(alice.identifier, "dir-a.test", opts(ctx))

      assert {:error, :invalid_locator} =
               Client.entries_after(alice.identifier, dir.url, "sha256:nope", 0, opts(ctx))

      assert {:error, :invalid_locator} =
               Client.entries_after(alice.identifier, dir.url, head, -1, opts(ctx))

      assert {:error, :invalid_locator} =
               Client.append(alice.identifier, dir.url <> "?x=1", last(alice), opts(ctx))

      assert requests() == []
    end

    test "the options are the resolver and the trusted certificates, and nothing else", ctx do
      alice = composed("https://dir-a.test")

      assert_raise ArgumentError, ~r/takes only :resolver and :cacerts/, fn ->
        Client.log(alice.identifier, alice.url, [timeout: 1] ++ opts(ctx))
      end

      assert_raise ArgumentError, ~r/:resolver is a module/, fn ->
        Client.log(alice.identifier, alice.url, resolver: "Resolver")
      end
    end
  end

  describe "the loopback rule" do
    @loopback ~w(http://127.0.0.1 http://127.79.0.1:4702 http://localhost:4000)
    @refused ~w(http://10.0.0.5 http://dir.example http://127.0.0.1.example)

    test "plain HTTP to any other host is insecure_directory, before any lookup or request",
         ctx do
      for url <- @refused do
        alice = composed(url)

        assert {:error, :insecure_directory} = Client.log(alice.identifier, url, opts(ctx)), url
        assert {:error, :insecure_directory} = Client.register(genesis(alice), opts(ctx)), url
      end

      refute_received {:resolved, _}
      assert requests() == []
    end

    # Accepted over HTTP, the address still meets the pinned egress, which
    # refuses a loopback address the operator did not list: the rule opens
    # the scheme alone.
    test "plain HTTP to loopback passes the transport check and meets the egress guard", ctx do
      for url <- @loopback do
        alice = composed(url)

        log =
          capture_log(fn ->
            assert {:error, :egress_refused} =
                     Client.log(alice.identifier, url, cacerts: ctx.tls[:client_config][:cacerts]),
                   url
          end)

        assert log =~ "private IP 127.", url
      end
    end
  end

  describe "the transport" do
    test "a loopback address the operator did not list is refused before connecting", ctx do
      dir = directory(ctx, "loopback.test", fn _ -> flunk("no connection is made") end)
      alice = composed(dir.url)

      log =
        capture_log(fn ->
          assert {:error, :egress_refused} = Client.log(alice.identifier, dir.url, opts(ctx))
        end)

      assert log =~ "private IP 127.0.0.1 blocked"
      assert_received {:resolved, "loopback.test"}
      assert requests() == []
    end

    test "a metadata address is refused even when the operator lists its name", ctx do
      alice = composed("https://metadata.test")

      log =
        capture_log(fn ->
          assert {:error, :egress_refused} = Client.log(alice.identifier, alice.url, opts(ctx))
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

      alice = composed(dir.url)

      assert {:error, :redirected} = Client.log(alice.identifier, dir.url, opts(ctx))
      assert [%{target: "/directory/v1/" <> _}] = requests()
      refute_received {:resolved, "dir-b.test"}
    end

    test "a certificate the home does not trust is refused: verification is not optional",
         ctx do
      %{dir: dir, account: alice} = serving(ctx)

      log =
        capture_log(fn ->
          assert {:error, :unreachable} =
                   Client.log(alice.identifier, dir.url, resolver: Resolver)
        end)

      assert log =~ "unknown_ca"
      assert requests() == []
    end

    test "sends the canonical entry with no credential, and names itself", ctx do
      %{dir: dir, account: alice} = serving(ctx)
      bob = composed(dir.url)

      assert {:ok, %{result: :created, seq: 0, entry_hash: hash}} =
               Client.register(genesis(bob), opts(ctx))

      assert hash == Identity.hash(genesis(bob))

      assert [%{method: "POST", target: "/directory/v1/register", headers: headers, body: body}] =
               requests()

      assert body == Identity.canonical(genesis(bob))
      refute Enum.any?(headers, fn {name, _} -> Prima.Network.credential_header?(name) end)
      assert {"user-agent", "CYFR/" <> _} = List.keyfind(headers, "user-agent", 0)

      next =
        DirectoryServer.extend!(alice,
          kind: :remove_key,
          kid: DirectoryServer.kid(hd(alice.devices))
        )

      assert {:ok, %{result: :accepted, seq: 2}} =
               Client.append(alice.identifier, dir.url, Identity.canonical(last(next)), opts(ctx))

      assert [%{method: "POST", target: target, body: body}] = requests()
      assert target == "/directory/v1/#{alice.identifier}/append"
      assert body == Identity.canonical(last(next))
    end

    test "this member sheds its own requests to one directory past 300 a minute", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> flunk("a shed request is never sent") end)
      alice = composed(dir.url)

      for _ <- 1..300, do: :ok = Prima.RateLimiter.check({Client, dir.origin}, 300, 60_000)

      assert {:error, {:rate_limited, seconds}} = Client.register(genesis(alice), opts(ctx))
      assert seconds in 1..60
      assert requests() == []
    end

    @tag timeout: 60_000
    test "a directory that never answers is abandoned at the request's bound", ctx do
      dir = directory(ctx, "dir-a.test", fn _ -> :hang end)
      alice = composed(dir.url)
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = Client.log(alice.identifier, dir.url, opts(ctx))

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= @request_ms * 9 / 10 and elapsed < @request_ms + 5_000
    end
  end

  # ---- the writes --------------------------------------------------------------

  describe "the writes" do
    test "a repeat answers exists, naming the head; a moved log is stale_head with its head",
         ctx do
      %{dir: dir, account: alice} = serving(ctx)
      head = DirectoryServer.head(alice)

      assert {:ok, %{result: :exists, seq: 0, head: ^head}} =
               Client.register(genesis(alice), opts(ctx))

      assert {:ok, %{result: :exists, seq: 1, head: ^head}} =
               Client.append(alice.identifier, dir.url, last(alice), opts(ctx))

      moved = DirectoryServer.add_device!(dir.dir, alice)

      late =
        DirectoryServer.extend!(alice,
          kind: :remove_key,
          kid: DirectoryServer.kid(hd(alice.devices))
        )

      moved_head = DirectoryServer.head(moved)

      assert {:error, {:stale_head, ^moved_head}} =
               Client.append(alice.identifier, dir.url, last(late), opts(ctx))
    end

    test "a key listed twice is duplicate_key; a forged entry is unverified with its reason",
         ctx do
      %{dir: dir, account: alice} = serving(ctx)
      {pub, _} = hd(alice.devices)
      {:ok, key} = Prima.Identity.Key.new(alg: :ed25519, kind: :device, pub: pub)
      again = DirectoryServer.extend!(alice, kind: :add_key, key: key)

      assert {:error, :duplicate_key} =
               Client.append(alice.identifier, dir.url, last(again), opts(ctx))

      # A new key's entry naming the recovery key as its signer, signed by a stranger.
      {new_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, new_key} = Prima.Identity.Key.new(alg: :ed25519, kind: :device, pub: new_pub)
      {_pub, stranger} = :crypto.generate_key(:eddsa, :ed25519)
      added = DirectoryServer.extend!(alice, kind: :add_key, key: new_key)
      forged = Identity.sign(%{last(added) | sig: nil}, stranger)

      assert {:error, {:refused, :unverified, "wrong_signer"}} =
               Client.append(alice.identifier, dir.url, forged, opts(ctx))
    end

    test "a tombstoned account is gone to every read and write", ctx do
      %{dir: dir, account: alice} = serving(ctx)
      DirectoryServer.tombstone(dir.dir, alice.identifier)
      head = DirectoryServer.head(alice)

      assert {:error, :gone} = Client.log(alice.identifier, dir.url, opts(ctx))
      assert {:error, :gone} = Client.entries_after(alice.identifier, dir.url, head, 1, opts(ctx))
      assert {:error, :gone} = Client.register(genesis(alice), opts(ctx))
      assert {:error, :gone} = Client.append(alice.identifier, dir.url, last(alice), opts(ctx))
    end
  end

  # ---- the reads ---------------------------------------------------------------

  describe "the reads" do
    test "log/3 reads every linked page from the genesis, with the head and length", ctx do
      %{dir: dir, account: alice} = serving(ctx)

      alice =
        Enum.reduce(1..120, alice, fn _, alice -> DirectoryServer.add_device!(dir.dir, alice) end)

      assert {:ok, %{entries: entries, head: head, length: 122}} =
               Client.log(alice.identifier, dir.url, opts(ctx))

      assert entries == Enum.map(alice.log, &Entry.encode/1)
      assert head == DirectoryServer.head(alice)
      assert {:ok, _state} = Identity.verify_chain(entries)

      assert [%{target: first}, %{target: second}] = requests()
      assert first =~ "?after=-1"
      assert second =~ "?after=99"
    end

    test "entries_after/5 reads after an entry's hash, none at the head, and not_found for a hash the log does not hold",
         ctx do
      %{dir: dir, account: alice} = serving(ctx)
      at = DirectoryServer.head(alice)
      alice = DirectoryServer.add_device!(dir.dir, alice)
      alice = DirectoryServer.remove_key!(dir.dir, alice, DirectoryServer.kid(hd(alice.devices)))

      assert {:ok, %{entries: [added, removed], head: head, length: 4}} =
               Client.entries_after(alice.identifier, dir.url, at, 1, opts(ctx))

      assert [added, removed] == alice.log |> Enum.drop(2) |> Enum.map(&Entry.encode/1)
      assert head == DirectoryServer.head(alice)

      assert [%{target: target}] = requests()
      assert target == "/directory/v1/#{alice.identifier}/from/#{at}"

      assert {:ok, %{entries: [], head: ^head, length: 4}} =
               Client.entries_after(alice.identifier, dir.url, head, 3, opts(ctx))

      unknown = Prima.Digest.sha256("not in the log")

      assert {:error, :not_found} =
               Client.entries_after(alice.identifier, dir.url, unknown, 3, opts(ctx))
    end

    test "a page that does not start where it was asked, or whose next does not link, is refused",
         ctx do
      %{dir: dir, account: alice} = serving(ctx)
      head = DirectoryServer.head(alice)

      # The position the caller holds for the hash is not where the page starts.
      assert {:error, :invalid_page} =
               Client.entries_after(alice.identifier, dir.url, head, 0, opts(ctx))

      unlinked =
        directory(ctx, "dir-b.test", fn _ ->
          json(200, %{
            "identifier" => alice.identifier,
            "from" => 0,
            "entries" => [Entry.encode(genesis(alice))],
            "next" => 3,
            "head" => head,
            "length" => 2
          })
        end)

      assert {:error, :invalid_page} = Client.log(alice.identifier, unlinked.url, opts(ctx))
    end

    test "a caller passing no options reaches a directory only through the suite's seam", ctx do
      %{dir: dir, account: alice} = serving(ctx)

      # With no seam, the system's resolver knows no test directory.
      assert {:error, :unreachable} = Client.log(alice.identifier, dir.url)

      DirectoryServer.seam!(ctx.tls)
      assert {:ok, %{length: 2}} = Client.log(alice.identifier, dir.url)
    end
  end

  # ---- the directory's answers -------------------------------------------------

  describe "the directory's answers" do
    test "each refusal is decoded, with its bound when it is retryable", ctx do
      stale = "sha256:" <> String.duplicate("a", 64)

      answers = [
        json(409, %{"error" => "stale_head", "head" => stale}),
        json(409, %{"error" => "stale_head", "head" => "not a hash"}),
        json(409, %{"error" => "duplicate_key"}),
        json(409, %{"error" => "conflict"}),
        json(410, %{"error" => "gone"}),
        json(429, %{"error" => "rate_limited", "retry_after" => 7}, [{"retry-after", "7"}]),
        json(405, %{"error" => "read_only"}, [{"allow", "GET"}]),
        json(422, %{"error" => "unverified", "reason" => "broken_link"}),
        json(422, %{"error" => "invalid", "reason" => "invalid_field", "field" => "key"}),
        json(422, %{"error" => "invalid", "reason" => "Not A Word!"}),
        json(422, %{"error" => "wrong_directory"}),
        json(404, %{"error" => "not_served"}),
        json(404, %{"error" => "not_found"}),
        json(500, %{"error" => "corrupt"}),
        json(503, %{"error" => "unavailable"}, [{"retry-after", "1"}]),
        json(503, %{"error" => "capacity", "exhausted" => "identities"}, [{"retry-after", "60"}]),
        # A day's writes: the wait is the window's, and never past a day.
        json(503, %{"error" => "capacity", "exhausted" => "writes"}, [{"retry-after", "86000"}]),
        json(503, %{"error" => "capacity", "exhausted" => "writes"}, [{"retry-after", "999999"}]),
        {413, [], ~s({"errors":{"detail":"Request Entity Too Large"}})}
      ]

      {:ok, script} = Agent.start_link(fn -> answers end)

      dir =
        directory(ctx, "dir-a.test", fn _ ->
          Agent.get_and_update(script, fn [answer | rest] -> {answer, rest} end)
        end)

      alice = composed(dir.url)
      append = fn -> Client.append(alice.identifier, dir.url, last(alice), opts(ctx)) end

      assert {:error, {:stale_head, ^stale}} = append.()
      assert {:error, :invalid_response} = append.()
      assert {:error, :duplicate_key} = append.()
      assert {:error, :conflict} = append.()
      assert {:error, :gone} = append.()
      assert {:error, {:rate_limited, 7}} = append.()
      assert {:error, :read_only} = append.()
      assert {:error, {:refused, :unverified, "broken_link"}} = append.()
      assert {:error, {:refused, :invalid, "invalid_field"}} = append.()
      assert {:error, {:refused, :invalid, nil}} = append.()
      assert {:error, {:refused, :wrong_directory, nil}} = append.()
      assert {:error, :not_served} = append.()
      assert {:error, :not_found} = append.()
      assert {:error, :corrupt} = append.()
      assert {:error, {:unavailable, 1}} = append.()
      assert {:error, {:capacity, 60}} = append.()
      assert {:error, {:capacity, 86_000}} = append.()
      assert {:error, {:capacity, 86_400}} = append.()
      assert {:error, :body_too_large} = append.()
    end

    test "a write's answer is held to the entry sent and the result its call takes", ctx do
      alice = composed("https://dir-a.test")
      hash = Identity.hash(last(alice))

      answers = [
        json(200, %{
          "identifier" => alice.identifier,
          "seq" => 1,
          "entry_hash" => hash,
          "result" => "accepted"
        }),
        json(200, %{
          "identifier" => alice.identifier,
          "seq" => 1,
          "entry_hash" => Prima.Digest.sha256("x"),
          "result" => "accepted"
        }),
        json(200, %{
          "identifier" => alice.identifier,
          "seq" => 1,
          "entry_hash" => hash,
          "result" => "created"
        }),
        json(200, %{
          "identifier" => alice.identifier,
          "seq" => 1,
          "entry_hash" => hash,
          "result" => "exists"
        }),
        json(200, %{"identifier" => alice.identifier, "seq" => 1, "entry_hash" => hash})
      ]

      {:ok, script} = Agent.start_link(fn -> answers end)

      dir =
        directory(ctx, "dir-a.test", fn _ ->
          Agent.get_and_update(script, fn [answer | rest] -> {answer, rest} end)
        end)

      append = fn -> Client.append(alice.identifier, dir.url, last(alice), opts(ctx)) end

      assert {:ok, %{result: :accepted, seq: 1, entry_hash: ^hash} = written} = append.()
      refute Map.has_key?(written, :head)
      # Another entry's hash, a result an append never answers, exists naming no head, no result.
      assert {:error, :invalid_response} = append.()
      assert {:error, :invalid_response} = append.()
      assert {:error, :invalid_response} = append.()
      assert {:error, :invalid_response} = append.()
    end
  end
end
