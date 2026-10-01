# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IdentityFreshnessTest do
  @moduledoc """
  How fresh an identity's head is at this home, and the live key's
  rotation, against a scripted directory that speaks HTTPS under a test
  authority on loopback.

  A cached head is answered within `identity_freshness_seconds` and read
  again past it; past the bound with the directory unreachable, the
  person's work pauses as `identity_stale`, naming the bound; a head that
  does not descend from the cached one is refused with the cache left as
  it was. A refreshed head that changes the `key_epoch` retires the
  sessions and passkeys bound to the old one in the cache's transaction,
  and the memos with them.

  A rotation needs `key_rotation` confirmed, opens one durable attempt
  that consumes it, submits its entry to the directory the genesis names,
  advances the cache before it activates the staged key, and resumes under
  the same request id without a second key. A log that moved past it ends
  the attempt without its key.
  """

  # The private-egress configuration, the resolver, the rate counters, the
  # caller bound and the head cache are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.{DirectoryHead, IdentityAttempt, Passkey, PersonIdentity, Session}
  alias Prima.Identity
  alias Prima.Identity.{Entry, RecoverRequest}
  alias Sanctum.{Caller, Cipher, CipherAAD, Context, IdentityFreshness}
  alias Sanctum.Consent.Authz
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @host "dir-a.test"

  defmodule Resolver do
    @moduledoc false
    # The test directory's name answers at loopback; nothing else resolves.
    # Each lookup is told to the running test, so a read the directory
    # never answered is still seen to have been tried.
    def getaddr(~c"dir-a.test", :inet) do
      case :persistent_term.get({__MODULE__, :observer}, nil) do
        pid when is_pid(pid) -> send(pid, {:resolved, "dir-a.test"})
        nil -> :ok
      end

      {:ok, {127, 0, 0, 1}}
    end

    def getaddr(_name, _family), do: {:error, :nxdomain}
  end

  defmodule Server do
    @moduledoc false
    # A TLS listener on loopback that reads one HTTP/1.1 request per
    # connection, reports it to the test and answers `handler.(request)`:
    # `{status, headers, body}`, or `:close` to close without answering.

    def start(ssl_options, handler, observer) do
      {:ok, listen} =
        :ssl.listen(
          0,
          ssl_options ++ [ip: {127, 0, 0, 1}, active: false, mode: :binary, reuseaddr: true]
        )

      {:ok, {_address, port}} = :ssl.sockname(listen)
      pid = spawn(fn -> accept(listen, handler, observer) end)
      %{port: port, pid: pid, listen: listen}
    end

    def stop(%{pid: pid, listen: listen}) do
      Process.exit(pid, :kill)
      :ssl.close(listen)
    end

    defp accept(listen, handler, observer) do
      case :ssl.transport_accept(listen) do
        {:ok, socket} ->
          # Told before the handshake: a client that opened a connection
          # is seen to have, whether or not it then trusts the server.
          send(observer, :connected)
          serve(socket, handler, observer)
          accept(listen, handler, observer)

        {:error, _closed} ->
          :ok
      end
    end

    defp serve(socket, handler, observer) do
      with {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, request} <- read(socket, "") do
        send(observer, {:request, request})

        case handler.(request) do
          :close ->
            :ok

          {status, headers, body} ->
            headers = [{"content-length", byte_size(body)}, {"connection", "close"} | headers]
            head = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)
            :ssl.send(socket, "HTTP/1.1 #{status} Answer\r\n" <> head <> "\r\n" <> body)
        end

        :ssl.close(socket)
      end
    end

    defp read(socket, acc) do
      case :binary.split(acc, "\r\n\r\n") do
        [head, rest] ->
          [line | lines] = String.split(head, "\r\n")
          [method, target, _version] = String.split(line, " ", parts: 3)

          headers =
            for line <- lines, [name, value] = String.split(line, ":", parts: 2) do
              {String.downcase(name), String.trim(value)}
            end

          length =
            case List.keyfind(headers, "content-length", 0) do
              {_name, value} -> String.to_integer(value)
              nil -> 0
            end

          with {:ok, body} <- body(socket, rest, length) do
            {:ok, %{method: method, target: target, body: body}}
          end

        [_partial] ->
          with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: read(socket, acc <> data)
      end
    end

    defp body(_socket, acc, length) when byte_size(acc) >= length, do: {:ok, acc}

    defp body(socket, acc, length) do
      with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: body(socket, acc <> data, length)
    end
  end

  setup_all do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(@host)}]}
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    tls =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    %{tls: tls}
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.RateLimiter.reset()
    targets = Application.fetch_env(:sanctum, :private_egress_targets)
    ttl = Application.fetch_env(:sanctum, :caller_memo_ttl_ms)

    # The test directory is on loopback, which the operator lists by name.
    Application.put_env(:sanctum, :private_egress_targets, [@host])
    :persistent_term.put({Resolver, :observer}, self())

    on_exit(fn ->
      restore(:private_egress_targets, targets)
      restore(:caller_memo_ttl_ms, ttl)
      :persistent_term.erase({Resolver, :observer})
      Arca.Cache.delete_match({:established, :_, :_, :_})
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      Prima.RateLimiter.reset()
    end)

    # The logs the scripted directory serves, by identifier, and how it
    # answers each identifier's next append.
    {:ok, dir} = Agent.start_link(fn -> %{logs: %{}, next: %{}} end)
    %{dir: dir}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:sanctum, key, value)
  defp restore(key, :error), do: Application.delete_env(:sanctum, key)

  @doc false
  # Telemetry's handler: the event and its metadata, to the test.
  def handle_telemetry(event, _measurements, metadata, pid),
    do: send(pid, {:telemetry, event, metadata})

  @doc false
  # Arca's query handler: when the person's row takes a new head (the
  # staged key's activation), the head this home's cache names at that
  # instant, read in the activation's own transaction.
  def handle_activation(_event, _measurements, %{source: "person_identities"} = meta, config) do
    {pid, identifier} = config

    if String.starts_with?(meta.query, "UPDATE") and
         String.contains?(meta.query, "live_key_sealed") do
      cached = Arca.Repo.get(DirectoryHead, identifier)
      send(pid, {:activated_under, cached && cached.head_hash})
    end
  end

  def handle_activation(_event, _measurements, _meta, _config), do: :ok

  defp listen!(events) do
    id = "identity-freshness-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # ---- the scripted directory --------------------------------------------------

  defp directory!(%{tls: tls, dir: dir}) do
    server = Server.start(tls[:server_config], serving(dir), self())
    on_exit(fn -> Server.stop(server) end)
    %{url: "https://#{@host}:#{server.port}", server: server}
  end

  defp opts(%{tls: tls}), do: [resolver: Resolver, cacerts: tls[:client_config][:cacerts]]

  defp publish(dir, identifier, log),
    do: Agent.update(dir, &put_in(&1, [:logs, identifier], log))

  defp log(dir, identifier), do: Agent.get(dir, &get_in(&1, [:logs, identifier]))

  # How the directory answers `identifier`'s next append: `:drop` takes it
  # and closes without an answer; `:stale_after_commit` takes it and
  # answers `409 stale_head` naming the head it now is; `{:supersede,
  # fun}` takes it and then commits `fun.(its_hash)` after it; `{:race,
  # fun}` commits `fun.(head)` first, so the append meets a moved head;
  # `:refuse` refuses it.
  defp next_append(dir, identifier, mode),
    do: Agent.update(dir, &put_in(&1, [:next, identifier], mode))

  defp serving(dir) do
    fn
      %{method: "GET", target: target} -> page(dir, target)
      %{method: "POST", target: target, body: body} -> append(dir, target, body)
    end
  end

  defp page(dir, target) do
    %URI{path: path, query: query} = URI.parse(target)
    identifier = path |> String.split("/") |> List.last()
    after_seq = String.to_integer(URI.decode_query(query || "")["after"])

    case log(dir, identifier) do
      nil ->
        json(404, %{"error" => "not_found"})

      log ->
        page = log |> Enum.drop(after_seq + 1) |> Enum.take(100)
        last = after_seq + length(page)
        next = if last < length(log) - 1, do: last, else: nil

        json(200, %{
          "identifier" => identifier,
          "from" => after_seq + 1,
          "entries" => Enum.map(page, &Entry.encode/1),
          "next" => next,
          "head" => head_of(log),
          "length" => length(log)
        })
    end
  end

  defp append(dir, target, body) do
    ["", "directory", "v1", identifier, "entries"] = String.split(target, "/")
    {:ok, entry} = body |> Jason.decode!() |> Entry.decode()
    hash = Identity.hash(entry)

    Agent.get_and_update(dir, fn state ->
      {mode, next} = Map.pop(state.next, identifier, :accept)
      log = Map.fetch!(state.logs, identifier)

      log =
        case mode do
          {:race, moved} -> log ++ [moved.(head_of(log))]
          _other -> log
        end

      {answer, log} =
        cond do
          mode == :refuse ->
            {json(422, %{"error" => "unverified", "reason" => "bad_signature"}), log}

          # An exact retry is answered while the entry is the head.
          hash == head_of(log) ->
            {accepted(identifier, log), log}

          entry.prev == head_of(log) ->
            log = log ++ [entry]

            case mode do
              :drop -> {:close, log}
              :stale_after_commit -> {stale_head(log), log}
              {:supersede, after_it} -> {accepted(identifier, log), log ++ [after_it.(hash)]}
              _accept -> {accepted(identifier, log), log}
            end

          true ->
            {stale_head(log), log}
        end

      {answer, %{state | logs: Map.put(state.logs, identifier, log), next: next}}
    end)
  end

  defp stale_head(log), do: json(409, %{"error" => "stale_head", "head" => head_of(log)})

  defp accepted(identifier, log) do
    json(200, %{
      "identifier" => identifier,
      "seq" => length(log) - 1,
      "entry_hash" => head_of(log)
    })
  end

  defp head_of(log), do: Identity.hash(List.last(log))

  defp json(status, body),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(body)}

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  # ---- people ------------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp request_id, do: "req_#{System.unique_integer([:positive])}"

  # A person seated in a group of their own, and their session's context.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|freshness-#{n}",
        provider: "github",
        email: "freshness#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Freshness #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)
    %{user: user, athanor: athanor}
  end

  defp session_ctx!(%{user: user, athanor: athanor}) do
    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    ctx
  end

  defp row(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)
  defp cached_row(identifier), do: Arca.Repo.get(DirectoryHead, identifier)

  defp attempt(request_id), do: Arca.Repo.get_by!(IdentityAttempt, request_id: request_id)

  defp rotations(user_id) do
    Arca.Repo.aggregate(
      from(a in IdentityAttempt, where: a.user_id == ^user_id and a.kind == "rotation"),
      :count
    )
  end

  # A local person enrolled at the directory `url`: their genesis names
  # their own live and operational keys and a recovery key the test holds,
  # signed by their operational key, and their enrollment accepted.
  defp enrolled!(%{dir: dir}, url) do
    %{user: user} = person = seated!()
    row = row(user.id)

    {:ok, operational} =
      Cipher.decrypt(row.operational_key_sealed, CipherAAD.person_key(user.id, :operational))

    {recovery_pub, recovery} = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: row.live_public_key,
        operational_key: row.operational_public_key,
        recovery_keys: [recovery_pub],
        directory: url
      )

    genesis = Identity.sign(genesis, operational)
    identifier = Identity.identifier(genesis)
    as = %Prima.Actor{user_id: user.id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: request_id(),
        user_id: user.id,
        identifier: identifier,
        directory_url: url,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")
    publish(dir, identifier, [genesis])

    Map.merge(person, %{
      ctx: session_ctx!(person),
      identifier: identifier,
      genesis: genesis,
      recovery: recovery,
      url: url
    })
  end

  # A person whose keys are at another home, admitted here: their identity
  # row is `remote`, their head cached from the directory, and a session
  # bound to that head's `key_epoch`.
  defp remote!(%{dir: dir} = context, url) do
    %{user: user, athanor: athanor} = person = seated!()
    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^user.id))

    {live, _} = keypair()
    {operational_pub, operational} = keypair()
    {recovery_pub, recovery} = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: operational_pub,
        recovery_keys: [recovery_pub],
        directory: url
      )

    genesis = Identity.sign(genesis, operational)
    identifier = Identity.identifier(genesis)

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user.id,
        provenance: "remote",
        identifier: identifier,
        directory_url: url
      })

    publish(dir, identifier, [genesis])

    {:ok, head} =
      IdentityFreshness.fresh!(
        identifier,
        [genesis: Identity.canonical(genesis)] ++ opts(context)
      )

    token = session_row!(user.id, athanor.id, head.key_epoch)

    Map.merge(person, %{
      identifier: identifier,
      genesis: genesis,
      operational: operational,
      recovery: recovery,
      url: url,
      token: token,
      epoch: head.key_epoch
    })
  end

  # The session behind `token`, established as a console does, with no
  # sliding refresh left running behind the case.
  defp establish(token, athanor),
    do: Caller.establish(token, focus: athanor.id, task_supervisor: nil)

  # A session row of `user_id`, bound to `epoch`, as a door at this home
  # mints one for a remote person, with a whole idle window ahead of it;
  # answers its token.
  defp session_row!(user_id, athanor_id, epoch) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Arca.Repo.insert_all(Session, [
      %{
        id: Prima.UUID7.generate_id("ses"),
        token_hash: :crypto.hash(:sha256, token),
        token_prefix: String.slice(token, 0, 8),
        user_id: user_id,
        provider: "cyfr",
        athanor_id: athanor_id,
        identity_key_epoch: epoch,
        expires_at: DateTime.add(now, 30 * 86_400, :second),
        inserted_at: now
      }
    ])

    token
  end

  # A recovery of `person`'s identity after the entry hashing to `prev`,
  # signed by the recovery key their genesis names.
  defp recovery(person, prev) do
    {live, _} = keypair()
    {operational, _} = keypair()

    {:ok, request} =
      RecoverRequest.new(
        identifier: person.identifier,
        directory: person.url,
        live_key: live,
        operational_key: operational,
        expected_revision: 0,
        request_id: request_id()
      )

    {:ok, entry} = Entry.recover(prev, Identity.sign(request, person.recovery))
    entry
  end

  # A passkey of the remote `person` registered at this home, bound to
  # `epoch`.
  defp passkey!(person, epoch) do
    Arca.Passkeys.register(%Prima.Actor{user_id: person.user.id}, %{
      user_id: person.user.id,
      credential_id: "cred-#{System.unique_integer([:positive])}",
      rp_id: Sanctum.Passkeys.rp_id(),
      relying_home: Sanctum.Person.home(),
      public_key: "cose-key",
      registration_digest: Prima.Digest.sha256("registration-#{System.unique_integer()}"),
      possession_verified: true,
      state: "active",
      identity_key_epoch: epoch
    })
  end

  defp rotation(person, prev) do
    {live, _} = keypair()
    {:ok, entry} = Entry.rotate(prev, live)
    Identity.sign(entry, person.operational)
  end

  defp stale!(identifier) do
    past = DateTime.add(DateTime.utc_now(), -400, :second)

    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: past]
      )

    :ok
  end

  defp rotate(person, request_id, context),
    do:
      Sanctum.TestContext.confirming(
        person.ctx,
        &IdentityFreshness.rotate_live(&1, request_id, opts(context))
      )

  # ---- freshness ---------------------------------------------------------------

  describe "fresh?/2" do
    test "within the bound the cached head is answered, the directory unread", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      _ = requests()
      Server.stop(dir.server)

      assert {:ok, %{identifier: identifier, key_epoch: epoch}} =
               IdentityFreshness.fresh?(person.identifier, opts(context))

      assert {identifier, epoch} == {person.identifier, person.epoch}
      assert requests() == []
    end

    test "past the bound the head is read again, and its verification moves", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      stale!(person.identifier)
      before = cached_row(person.identifier).verified_at

      assert {:ok, %{key_epoch: epoch}} =
               IdentityFreshness.fresh?(person.identifier, opts(context))

      assert epoch == person.epoch
      assert DateTime.compare(cached_row(person.identifier).verified_at, before) == :gt
      assert [%{method: "GET"} | _] = requests()
    end

    test "past the bound with the directory unreachable, the work pauses naming the bound",
         context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      stale!(person.identifier)
      Server.stop(dir.server)
      listen!([[:cyfr, :sanctum, :identity, :stale]])

      log =
        capture_log(fn ->
          assert {:refused, :identity_stale} =
                   IdentityFreshness.fresh?(person.identifier, opts(context))
        end)

      assert log =~ "300-second freshness bound"
      assert log =~ person.identifier

      assert_received {:telemetry, [:cyfr, :sanctum, :identity, :stale],
                       %{identifier: identifier, directory: directory, bound_seconds: 300}}

      assert {identifier, directory} == {person.identifier, dir.url}
    end

    test "a head that does not descend from the cached one is refused, the cache untouched",
         context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      genesis_hash = Identity.hash(person.genesis)

      # The cache moves to a first rotation...
      first = rotation(person, genesis_hash)
      publish(context.dir, person.identifier, [person.genesis, first])
      stale!(person.identifier)
      assert {:ok, _} = IdentityFreshness.fresh?(person.identifier, opts(context))
      stale!(person.identifier)
      cached = cached_row(person.identifier)

      # ...and the directory then serves a log that never held it.
      publish(context.dir, person.identifier, [person.genesis, rotation(person, genesis_hash)])
      listen!([[:cyfr, :sanctum, :identity, :not_descendant]])

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh?(person.identifier, opts(context))
      end)

      assert cached_row(person.identifier) == cached

      assert_received {:telemetry, [:cyfr, :sanctum, :identity, :not_descendant],
                       %{identifier: identifier, directory: directory}}

      assert {identifier, directory} == {person.identifier, dir.url}
    end

    test "with nothing cached and no genesis given, it pauses and asks no directory", context do
      _dir = directory!(context)
      identifier = "per_" <> String.duplicate("c", 64)

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh?(identifier, opts(context))
      end)

      assert requests() == []
    end

    test "the genesis passed is a locator only while nothing is cached", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      other = remote!(context, dir.url)
      stale!(person.identifier)

      # Another genesis passed for a cached identifier is not read: the
      # cached binding is the one resolved.
      assert {:ok, %{identifier: identifier}} =
               IdentityFreshness.fresh?(
                 person.identifier,
                 [genesis: Identity.canonical(other.genesis)] ++ opts(context)
               )

      assert identifier == person.identifier
    end

    test "a store that cannot answer is unavailable, never a verdict", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      Arca.Repo.query!("ALTER TABLE directory_heads RENAME TO directory_heads_unavailable")

      capture_log(fn ->
        assert {:error, :unavailable} = IdentityFreshness.fresh?(person.identifier, opts(context))
      end)
    end

    test "it takes only the locator and the client's options", context do
      assert_raise ArgumentError, fn ->
        IdentityFreshness.fresh?("per_" <> String.duplicate("d", 64), directory: "https://x.test")
      end

      assert_raise ArgumentError, fn ->
        IdentityFreshness.rotate_live(
          Context.build(user_id: "usr_x"),
          "req_1",
          [genesis: "{}"] ++ opts(context)
        )
      end
    end
  end

  describe "a directory found unreachable" do
    defp resolved do
      receive do
        {:resolved, host} -> [host | resolved()]
      after
        0 -> []
      end
    end

    defp unreachable_key(person), do: Arca.Cache.Keys.identity_unreachable(person.identifier)

    test "is not read again within its window, and is read again once the window ends",
         context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      stale!(person.identifier)
      Server.stop(dir.server)
      _ = resolved()

      # The first request past the bound tries the directory, finds it
      # unreachable, and pauses.
      log =
        capture_log(fn ->
          assert {:refused, :identity_stale} =
                   IdentityFreshness.fresh?(person.identifier, opts(context))
        end)

      assert log =~ "300-second freshness bound"
      assert resolved() == [@host]

      # Within the window: paused at once, and the directory is not tried.
      capture_log(fn ->
        for _ <- 1..3 do
          assert {:refused, :identity_stale} =
                   IdentityFreshness.fresh?(person.identifier, opts(context))
        end
      end)

      assert resolved() == []

      # The window is fifteen seconds on the cache's own (monotonic) clock.
      key = unreachable_key(person)
      [{^key, :unreachable, expires_at}] = :ets.lookup(Arca.Cache.table_name(), key)
      assert (expires_at - System.monotonic_time(:millisecond)) in 14_000..15_000

      # The window ends on that clock: the next request tries the
      # directory again.
      true =
        :ets.update_element(
          Arca.Cache.table_name(),
          key,
          {3, System.monotonic_time(:millisecond)}
        )

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh?(person.identifier, opts(context))
      end)

      assert resolved() == [@host]
    end

    test "fresh!/2 reads it within the window, and a read that succeeds ends the window",
         context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      stale!(person.identifier)
      _ = resolved()
      :ok = Arca.Cache.put(unreachable_key(person), :unreachable, 15_000)

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh?(person.identifier, opts(context))
      end)

      assert resolved() == []

      assert {:ok, %{key_epoch: epoch}} =
               IdentityFreshness.fresh!(person.identifier, opts(context))

      assert epoch == person.epoch
      assert resolved() == [@host]
      assert Arca.Cache.get(unreachable_key(person)) == :miss
    end

    test "a directory that answers, even with a refusal, opens no window", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      stale!(person.identifier)

      Agent.update(
        context.dir,
        &update_in(&1, [:logs], fn logs -> Map.delete(logs, person.identifier) end)
      )

      _ = resolved()

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh?(person.identifier, opts(context))

        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh?(person.identifier, opts(context))
      end)

      assert resolved() == [@host, @host]
      assert Arca.Cache.get(unreachable_key(person)) == :miss
    end
  end

  describe "inside a transaction" do
    defp connections do
      receive do
        :connected -> [:connected | connections()]
      after
        0 -> []
      end
    end

    defp session_stands?(token),
      do:
        Arca.Repo.exists?(
          from(s in Session, where: s.token_hash == ^:crypto.hash(:sha256, token))
        )

    # A remote person whose directory listens on loopback by the name
    # `localhost`, which the default resolver answers and the operator
    # lists: a revalidation, which passes no test resolver, reaches it. The
    # head is cached as verified now, and a session is bound to it and held.
    defp listening_remote!(context) do
      Application.put_env(:sanctum, :private_egress_targets, [@host, "localhost"])
      server = Server.start(context.tls[:server_config], serving(context.dir), self())
      on_exit(fn -> Server.stop(server) end)
      url = "https://localhost:#{server.port}"

      %{user: user, athanor: athanor} = seated!()
      Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^user.id))
      {live, _} = keypair()
      {operational_pub, operational} = keypair()
      {recovery_pub, _} = keypair()

      {:ok, genesis} =
        Entry.genesis(
          live_key: live,
          operational_key: operational_pub,
          recovery_keys: [recovery_pub],
          directory: url
        )

      genesis = Identity.sign(genesis, operational)
      identifier = Identity.identifier(genesis)
      head = Identity.hash(genesis)

      {:ok, _} =
        Arca.PersonIdentities.create(Prima.Actor.system(), %{
          user_id: user.id,
          provenance: "remote",
          identifier: identifier,
          directory_url: url
        })

      {:ok, _} =
        Arca.DirectoryHeads.put(Prima.Actor.system(), %{
          identifier: identifier,
          genesis: Identity.canonical(genesis),
          directory_url: url,
          head_hash: head,
          key_epoch: head,
          state: ~s({"head":"#{head}"})
        })

      publish(context.dir, identifier, [genesis])
      token = session_row!(user.id, athanor.id, head)
      {:ok, held} = establish(token, athanor)
      %{identifier: identifier, token: token, held: held}
    end

    test "past the bound, a revalidation pauses on the cached head and opens no connection",
         context do
      remote = listening_remote!(context)
      stale!(remote.identifier)
      cached = cached_row(remote.identifier)
      _ = connections()

      {result, _log} =
        with_log(fn ->
          Arca.Repo.transaction(fn ->
            answer =
              {Caller.revalidate_session(remote.held),
               IdentityFreshness.fresh?(remote.identifier)}

            {answer, connections()}
          end)
        end)

      assert {:ok, {{{:error, :identity_stale}, {:refused, :identity_stale}}, []}} = result

      # Nothing was read or written: no connection, the cache as it was,
      # the session standing.
      assert connections() == []
      assert cached_row(remote.identifier) == cached
      assert session_stands?(remote.token)

      # Outside the transaction the same revalidation does read the
      # directory (its certificate is the test's, so the read fails and the
      # work stays paused).
      capture_log(fn ->
        assert {:error, :identity_stale} = Caller.revalidate_session(remote.held)
      end)

      assert [:connected | _] = connections()
    end

    test "within the bound it stands on the cached head", context do
      remote = listening_remote!(context)
      _ = connections()

      assert {:ok, {:ok, %Context{}}} =
               Arca.Repo.transaction(fn -> Caller.revalidate_session(remote.held) end)

      assert connections() == []
    end

    test "a session bound to an epoch the head no longer names is refused there and revoked outside",
         context do
      remote = listening_remote!(context)
      newer = Prima.Digest.sha256("a newer head")

      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^remote.identifier),
        set: [head_hash: newer, key_epoch: newer]
      )

      listen!([[:cyfr, :sanctum, :caller, :invalidated], [:cyfr, :sanctum, :sessions, :revoked]])

      assert {:ok, {{:error, :unauthenticated}, true}} =
               Arca.Repo.transaction(fn ->
                 {Caller.revalidate_session(remote.held), session_stands?(remote.token)}
               end)

      # Nothing deleted or announced under the caller's transaction.
      assert session_stands?(remote.token)
      refute_received {:telemetry, [:cyfr, :sanctum, :caller, :invalidated], _}

      # The next revalidation outside one revokes it.
      capture_log(fn ->
        assert {:error, :unauthenticated} = Caller.revalidate_session(remote.held)
      end)

      refute session_stands?(remote.token)
      assert_received {:telemetry, [:cyfr, :sanctum, :caller, :invalidated], _}
    end

    test "Authz reading standing under a write's transaction pauses and opens no connection",
         context do
      remote = listening_remote!(context)
      stale!(remote.identifier)
      cached = cached_row(remote.identifier)
      _ = connections()

      # The grant arm, and the standing check `Sanctum.Passkeys` makes under
      # `Arca.Passkeys.register`'s lock, each inside the caller's
      # transaction with the head past its bound.
      {result, _log} =
        with_log(fn ->
          Arca.Repo.transaction(fn ->
            answer = {Authz.authorize(remote.held, grant()), Authz.standing(remote.held)}
            {answer, connections()}
          end)
        end)

      assert {:ok, {{{:error, :identity_stale}, {:error, :identity_stale}}, []}} = result
      assert connections() == []
      assert cached_row(remote.identifier) == cached
      assert session_stands?(remote.token)
    end
  end

  # ---- the grant arm -------------------------------------------------------------

  describe "Authz's grant arm" do
    # A grant of one exact commit, as the consent flow asks for it.
    defp grant,
      do: %Authz.Request{commit_digest: "sha256:" <> String.duplicate("e", 64)}

    test "grants on a fresh head", context do
      remote = listening_remote!(context)
      assert {:ok, :interactive} = Authz.authorize(remote.held, grant())
    end

    test "a stale identity is refused as paused, never allowed and never a crash", context do
      remote = listening_remote!(context)
      stale!(remote.identifier)

      # Outside a transaction the directory is tried, and cannot be trusted
      # here (its certificate is the test's): the work pauses.
      {answer, log} = with_log(fn -> Authz.authorize(remote.held, grant()) end)

      assert answer == {:error, :identity_stale}
      assert log =~ "300-second freshness bound"
      assert [:connected | _] = connections()

      # The pause reads as the refusal's own sentence, and the session
      # stands for when the identity is fresh again.
      assert Authz.message(:identity_stale) =~ "try again shortly"
      refute Authz.message(:identity_stale) =~ "sign in"
      assert session_stands?(remote.token)
    end
  end

  describe "fresh!/2" do
    test "reads the directory however recently the head was verified", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      _ = requests()

      assert {:ok, %{key_epoch: epoch}} =
               IdentityFreshness.fresh!(person.identifier, opts(context))

      assert epoch == person.epoch
      assert [%{method: "GET"} | _] = requests()

      Server.stop(dir.server)

      capture_log(fn ->
        assert {:refused, :identity_stale} =
                 IdentityFreshness.fresh!(person.identifier, opts(context))
      end)
    end
  end

  # ---- retirement --------------------------------------------------------------

  describe "a refreshed head that changes the key_epoch" do
    test "revokes the sessions and passkeys bound to the old one, and their memos", context do
      dir = directory!(context)
      person = remote!(context, dir.url)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

      {:ok, held} = establish(person.token, person.athanor)
      # Memoized: the next establish is answered without reading a row.
      assert {:ok, _} = establish(person.token, person.athanor)

      {:ok, passkey} = passkey!(person, person.epoch)

      # A recovery at the person's directory, which this home reads once
      # its cached head is past the bound.
      recovered = recovery(person, person.epoch)
      publish(context.dir, person.identifier, [person.genesis, recovered])
      stale!(person.identifier)

      assert {:ok, %{key_epoch: new_epoch}} =
               IdentityFreshness.fresh?(person.identifier, opts(context))

      assert new_epoch == Identity.hash(recovered)

      # Revoked at the refresh, and refused on its next request even though
      # the head is now fresh: no row, and no memo answers for it.
      token_hash = :crypto.hash(:sha256, person.token)
      refute Arca.Repo.get_by(Session, token_hash: token_hash)
      assert {:error, :unauthenticated} = establish(person.token, person.athanor)
      assert {:error, :unauthenticated} = Caller.revalidate_session(held)

      # The B-local passkey bound to the old key is retired, and no
      # credential can bind that epoch again.
      assert %{state: "revoked"} = Arca.Repo.get!(Passkey, passkey.id)
      assert {:error, :stale_key_epoch} = passkey!(person, person.epoch)
      assert {:ok, %{state: "active"}} = passkey!(person, new_epoch)

      # A session bound to the new epoch stands.
      token = session_row!(person.user.id, person.athanor.id, new_epoch)
      assert {:ok, %Context{}} = establish(token, person.athanor)
    end
  end

  # ---- rotation ----------------------------------------------------------------

  describe "rotate_live/3" do
    test "a session alone opens nothing and reads no directory: the change waits for its proof",
         context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)

      assert {:error, {:confirmation_required, %{id: "cnf_" <> _}}} =
               IdentityFreshness.rotate_live(person.ctx, request_id(), opts(context))

      assert rotations(person.user.id) == 0
      assert requests() == []
    end

    test "a confirmed rotation is submitted, the cache advanced, and only then the key activated",
         context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      before = row(person.user.id)
      genesis_epoch = before.head_hash

      # A device certificate recorded under the genesis's key_epoch, which
      # the rotation retires.
      {client, certificate} = certificate!(person)
      {:ok, old_cert} = record(person, client, certificate, genesis_epoch)
      assert old_cert.status == "active"

      id = request_id()
      hook = "activation-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          hook,
          [:arca, :repo, :query],
          &__MODULE__.handle_activation/4,
          {self(), person.identifier}
        )

      on_exit(fn -> :telemetry.detach(hook) end)

      assert {:ok, %{request_id: ^id, phase: "completed", key_epoch: epoch}} =
               rotate(person, id, context)

      :telemetry.detach(hook)

      # The staged key was activated once, and only with the cache already
      # naming its entry: a certificate issued before then met the new head.
      assert_received {:activated_under, ^epoch}
      refute_received {:activated_under, _another}

      after_row = row(person.user.id)
      assert after_row.head_hash == epoch
      refute after_row.live_public_key == before.live_public_key
      assert after_row.operational_public_key == before.operational_public_key
      assert after_row.operational_key_sealed == before.operational_key_sealed

      # The directory holds one rotation, naming the activated key.
      assert [_genesis, %Entry{kind: :rotate} = rotate] = log(context.dir, person.identifier)
      assert Identity.hash(rotate) == epoch
      assert rotate.live_key == after_row.live_public_key

      # The cache holds the new head, and the old epoch's certificate is revoked.
      assert %{head_hash: ^epoch, key_epoch: ^epoch} = cached_row(person.identifier)
      assert {:ok, %{status: "revoked"}} = Arca.DeviceCertificates.get(actor(person), old_cert.id)

      # The attempt completed and holds no staged key.
      assert %{phase: "completed", staged_live_key_sealed: nil} = attempt(id)

      # The live key now signs under the new epoch.
      {:ok, cert} =
        Sanctum.Person.issue_device_cert(
          person.user.id,
          :crypto.strong_rand_bytes(32),
          client.id,
          %{
            subject: :identity,
            audience: "https://hub.example",
            athanor: person.athanor.id
          }
        )

      assert cert.subject.key_epoch == epoch

      assert {:ok, _} =
               Prima.DeviceCert.verify(cert, after_row.live_public_key,
                 home: "https://hub.example",
                 now: System.os_time(:millisecond),
                 skew: 0,
                 key_epoch: epoch
               )
    end

    test "a lost reply leaves the attempt to its retry, which generates no second key", context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      id = request_id()
      next_append(context.dir, person.identifier, :drop)

      capture_log(fn ->
        assert {:error, :directory_unavailable} = rotate(person, id, context)
      end)

      # The directory took the entry; this home has not heard so.
      assert %{phase: "submitted", entry_hash: entry_hash} = attempt(id)
      assert [_genesis, rotate] = log(context.dir, person.identifier)
      assert Identity.hash(rotate) == entry_hash
      assert row(person.user.id).head_hash == Identity.hash(person.genesis)

      # The retry under the same id needs no new confirmation and resumes
      # the same attempt: the same entry, the same staged key.
      assert {:ok, %{key_epoch: ^entry_hash, phase: "completed"}} =
               IdentityFreshness.rotate_live(person.ctx, id, opts(context))

      assert rotations(person.user.id) == 1
      assert length(log(context.dir, person.identifier)) == 2
      assert row(person.user.id).live_public_key == rotate.live_key

      # And again, answered from the completed attempt.
      assert {:ok, %{key_epoch: ^entry_hash}} =
               IdentityFreshness.rotate_live(person.ctx, id, opts(context))
    end

    test "a 409 for an entry the log now ends with is reconciled as accepted, and its key activated",
         context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      id = request_id()
      next_append(context.dir, person.identifier, :stale_after_commit)

      {answer, _log} = with_log(fn -> rotate(person, id, context) end)

      assert {:ok, %{phase: "completed", key_epoch: epoch}} = answer
      assert [_genesis, rotate] = log(context.dir, person.identifier)
      assert Identity.hash(rotate) == epoch

      # The reconciling read found the entry at the head: accepted, with no
      # second append, and its staged key the live one.
      assert %{phase: "completed", outcome: "accepted", entry_hash: ^epoch} = attempt(id)
      assert row(person.user.id).head_hash == epoch
      assert row(person.user.id).live_public_key == rotate.live_key
      assert cached_row(person.identifier).head_hash == epoch

      assert [%{method: "POST"}] =
               Enum.filter(requests(), &(&1.method == "POST"))
    end

    test "a recovery that supersedes the accepted entry before activation ends it, no key",
         context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      before = row(person.user.id)
      id = request_id()

      next_append(
        context.dir,
        person.identifier,
        {:supersede, fn accepted -> recovery(person, accepted) end}
      )

      capture_log(fn -> assert {:error, :superseded} = rotate(person, id, context) end)

      assert %{phase: "superseded", outcome: "superseded", staged_live_key_sealed: nil} =
               attempt(id)

      after_row = row(person.user.id)
      assert after_row.live_public_key == before.live_public_key
      assert after_row.head_hash == before.head_hash

      [_genesis, _rotate, recovered] = log(context.dir, person.identifier)
      assert cached_row(person.identifier).head_hash == Identity.hash(recovered)
    end

    test "a rotate refused as stale ends without its key; a new one needs a new confirmation",
         context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      before = row(person.user.id)
      authenticator = Sanctum.TestContext.passkey!(person.user.id)
      id = request_id()

      # The log moves between the head this home read and the append.
      next_append(context.dir, person.identifier, {:race, fn head -> recovery(person, head) end})

      {:error, {:confirmation_required, %{id: confirmation}}} =
        IdentityFreshness.rotate_live(person.ctx, id, opts(context))

      Sanctum.TestContext.prove!(person.ctx, confirmation, authenticator)
      confirmed = %{person.ctx | confirmation_id: confirmation}

      capture_log(fn ->
        assert {:error, :stale_head} =
                 IdentityFreshness.rotate_live(confirmed, id, opts(context))
      end)

      assert %{phase: "refused", outcome: "stale_head", staged_live_key_sealed: nil} =
               attempt(id)

      assert row(person.user.id).live_public_key == before.live_public_key

      # This home's head is refreshed to the one that moved past it.
      [_genesis, recovered] = log(context.dir, person.identifier)
      assert cached_row(person.identifier).head_hash == Identity.hash(recovered)

      # The confirmation was consumed with the attempt: a new rotation asks
      # for its own.
      assert {:error, {:confirmation_required, %{id: other}}} =
               IdentityFreshness.rotate_live(confirmed, request_id(), opts(context))

      refute other == confirmation
    end

    test "a log already past this home's head is refused before anything is staged", context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      recovered = recovery(person, Identity.hash(person.genesis))
      publish(context.dir, person.identifier, [person.genesis, recovered])

      capture_log(fn -> assert {:error, :stale_head} = rotate(person, request_id(), context) end)

      assert rotations(person.user.id) == 0
      assert cached_row(person.identifier).head_hash == Identity.hash(recovered)
    end

    test "a certificate issued between the cache's advance and the key's activation is refused",
         context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      old_epoch = row(person.user.id).head_hash
      id = request_id()
      next_append(context.dir, person.identifier, :drop)

      capture_log(fn ->
        assert {:error, :directory_unavailable} = rotate(person, id, context)
      end)

      # The head is read again before the key is active: the cache names the
      # rotation's entry while the person's row still names the old head.
      assert {:ok, %{key_epoch: new_epoch}} =
               IdentityFreshness.fresh!(person.identifier, opts(context))

      assert new_epoch == attempt(id).entry_hash
      assert row(person.user.id).head_hash == old_epoch

      {client, certificate} = certificate!(person)
      assert {:error, :stale_key_epoch} = record(person, client, certificate, old_epoch)

      assert {:ok, %{key_epoch: ^new_epoch}} =
               IdentityFreshness.rotate_live(person.ctx, id, opts(context))

      assert {:ok, %{status: "active"}} = record(person, client, certificate, new_epoch)
    end

    test "a directory that refuses the entry ends the attempt, nothing rotated", context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      before = row(person.user.id)
      id = request_id()
      next_append(context.dir, person.identifier, :refuse)

      capture_log(fn -> assert {:error, :rotation_refused} = rotate(person, id, context) end)

      assert %{phase: "refused", outcome: "refused"} = attempt(id)
      assert row(person.user.id).live_public_key == before.live_public_key

      assert {:error, :rotation_refused} =
               IdentityFreshness.rotate_live(person.ctx, id, opts(context))
    end

    test "another rotation in progress is named before anything is asked", context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      id = request_id()
      next_append(context.dir, person.identifier, :drop)
      capture_log(fn -> {:error, :directory_unavailable} = rotate(person, id, context) end)

      assert {:error, {:attempt_in_progress, ^id}} =
               IdentityFreshness.rotate_live(person.ctx, request_id(), opts(context))

      assert rotations(person.user.id) == 1
    end

    test "a person never enrolled, one whose keys are elsewhere, and a malformed id rotate nothing",
         context do
      dir = directory!(context)
      local = seated!()
      unenrolled = session_ctx!(local)

      assert {:error, :not_enrolled} =
               IdentityFreshness.rotate_live(unenrolled, request_id(), opts(context))

      remote = remote!(context, dir.url)
      {:ok, remote_ctx} = establish(remote.token, remote.athanor)
      _ = requests()

      assert {:error, :not_found} =
               IdentityFreshness.rotate_live(remote_ctx, request_id(), opts(context))

      assert {:error, :invalid_request} =
               IdentityFreshness.rotate_live(unenrolled, "not a request id!", opts(context))

      assert requests() == []
      assert rotations(local.user.id) == 0
    end

    test "a request id that names another person's attempt is not theirs to resume", context do
      dir = directory!(context)
      person = enrolled!(context, dir.url)
      other = enrolled!(context, dir.url)
      id = request_id()
      next_append(context.dir, person.identifier, :drop)
      capture_log(fn -> {:error, :directory_unavailable} = rotate(person, id, context) end)

      assert {:error, :request_id_reused} =
               IdentityFreshness.rotate_live(other.ctx, id, opts(context))

      assert %{phase: "submitted"} = attempt(id)
    end
  end

  # ---- certificates ------------------------------------------------------------

  defp actor(person), do: Context.actor(person.ctx)

  # A paired client of the person in their athanor, holding a device key.
  defp certificate!(person) do
    device_key = :crypto.strong_rand_bytes(32)

    {:ok, client} =
      Arca.PairedClients.record(actor(person), %{
        user_id: person.user.id,
        source_kind: "device_cert",
        source_id: Prima.Digest.sha256(device_key),
        device_public_key: device_key,
        label: "phone"
      })

    {client, device_key}
  end

  defp record(person, client, device_key, key_epoch) do
    now = DateTime.utc_now()

    Arca.DeviceCertificates.record(actor(person), %{
      paired_client_id: client.id,
      user_id: person.user.id,
      subject_kind: "identity",
      identifier: person.identifier,
      key_epoch: key_epoch,
      device_public_key: device_key,
      issuing_home: "https://home.example",
      audience_home: "https://hub.example",
      not_before: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      certificate: "cert-#{System.unique_integer()}",
      digest: Prima.Digest.sha256("cert-#{System.unique_integer()}")
    })
  end
end
