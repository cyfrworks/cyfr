# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress.TinctureDataControllerTest do
  @moduledoc """
  The tincture data routes (`/_f/v1/invoke`, `/_f/v1/action`,
  `/_f/v1/stream`): a frame's per-open credential as a bearer and nothing
  else, held at every request to its row, its source, the version it
  opened and the grant it was opened under; the tincture's declaration as
  the grant, enforced before dispatch; a public tincture's page admitted
  under its public profile only; the per-frame invocation rate and
  open-stream count; and the stream answered as the wire's event stream,
  closed within the revalidation bound once its frame stops standing.
  """

  # Mints and suspends frame credentials, writes platform settings and
  # meters rates, all of them process-wide.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Prima.TinctureWire
  alias Sanctum.TinctureAuth

  @version "1.0.0"

  # How long a stream may take to open (the gate's admission and the
  # subscription) or to take an event, on a loaded host. Each wait ends on
  # the subscription or the delivery itself; this bounds one that never
  # ends.
  @stream_ms 10_000

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)

    _athanor = Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)

    {:ok, source: source, session: session}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A tincture version in the source's athanor declaring `block` (its
  # actions and streams) and `deps` (its static dependencies). Answers
  # its release digest.
  defp tincture!(ctx, name, block, deps) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => Map.merge(%{"entry" => "index.html"}, block),
      "dependencies" => %{"static" => deps}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: @version,
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    release_digest
  end

  defp declared!(ctx, name) do
    tincture!(
      ctx,
      name,
      %{"actions" => ["system.status"], "streams" => [%{"name" => "mcp_servers.changes"}]},
      [%{"ref" => "reagent:local.echo", "reason" => "echo"}]
    )
  end

  defp frame_id, do: "frm_data_#{System.unique_integer([:positive])}"

  # Another signed-in person of the same athanor.
  defp person!(namespace) do
    issuer =
      Sanctum.TestContext.issuer!(%{
        Sanctum.TestContext.local()
        | user_id: "local|local|#{namespace}",
          namespace: namespace
      })

    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, ctx} = Sanctum.Caller.establish(session.token)
    ctx
  end

  # The frame the shell would open for `name`: its credential and row id.
  defp frame!(source, name, digest, revision \\ 0) do
    reference = %{publisher: "local", name: name, version: @version}

    {:ok, %{credential: bearer, id: id}} =
      TinctureAuth.mint_frame_credential(source, reference, digest, revision, frame_id())

    %{bearer: bearer, id: id}
  end

  defp data(kind, body, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", Keyword.get(opts, :origin, "null"))
      |> Map.put(:remote_ip, Keyword.get(opts, :ip, {127, 0, 0, 1}))

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        bearer -> put_req_header(conn, "authorization", TinctureWire.bearer(bearer))
      end

    post(conn, TinctureWire.route(kind), Jason.encode!(body))
  end

  defp action(bearer, operation, opts \\ []) do
    body = TinctureWire.request(:action, %{operation: operation, args: %{}})
    data(:action, body, Keyword.put(opts, :bearer, bearer))
  end

  defp answer(conn, kind), do: TinctureWire.decode_answer(kind, Jason.decode!(conn.resp_body))

  defp refused(conn, kind) do
    assert {:refused, projection} = answer(conn, kind)
    projection
  end

  defp mcp_rows(tool),
    do: Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.tool == ^tool))

  # The gate's decisions for `tool`: what was dispatched, whether or not
  # the request log keeps a row of it.
  defp decisions(tool),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == ^tool))

  # ---------------------------------------------------------------------------
  # Who is asking
  # ---------------------------------------------------------------------------

  describe "the frame credential" do
    test "a declared action runs through the gate as the frame's person, in its athanor",
         %{source: source} do
      frame = frame!(source, "act-dash", declared!(source, "act-dash"))
      conn = action(frame.bearer, "system.status")

      assert conn.status == 200
      assert {:ok, _status} = answer(conn, :action)
      assert get_resp_header(conn, "access-control-allow-origin") == ["null"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []

      # A refusal after the frame was established is recorded as its
      # person's, in its athanor.
      assert action(frame.bearer, "execution.list").status == 403
      assert [row] = decisions("tincture")
      assert {row.action, row.admission} == {"system_action", "refused"}
      assert {row.user_id, row.athanor_id} == {source.user_id, source.athanor_id}
    end

    test "a request with no credential and no public tincture is no frame", %{source: source} do
      declared!(source, "none-dash")

      conn =
        data(:action, TinctureWire.request(:action, %{operation: "system.status", args: %{}}))

      assert conn.status == 401
      assert %{class: "unauthenticated", stage: "admission"} = refused(conn, :action)
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "a session token, an API key or a session cookie is never a frame credential",
         %{source: source, session: session} do
      declared!(source, "cookie-dash")
      body = TinctureWire.request(:action, %{operation: "system.status", args: %{}})

      conn = data(:action, body, bearer: session.token)
      assert %{class: "unauthenticated"} = refused(conn, :action)

      cookie =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("cookie", "_cyfr_key=" <> session.token)
        |> post(TinctureWire.route(:action), Jason.encode!(body))

      assert cookie.status == 401
      assert Enum.all?(decisions("tincture"), &(&1.admission == "refused" and is_nil(&1.user_id)))
    end

    test "a suspended frame is refused, a resumed one admitted, a revoked one refused at once",
         %{source: source} do
      frame = frame!(source, "state-dash", declared!(source, "state-dash"))

      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      suspended = action(frame.bearer, "system.status")
      assert suspended.status == 403
      assert %{class: "forbidden", stage: "admission"} = refused(suspended, :action)

      {:ok, _} = TinctureAuth.resume_frame(source, frame.id)
      assert action(frame.bearer, "system.status").status == 200

      # A closed tab: the shell's terminate revokes every credential it
      # minted, and the next request is refused.
      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      assert %{class: "unauthenticated"} = refused(action(frame.bearer, "system.status"), :action)
    end

    test "an unobserved frame's credential past its deadline is refused at the next request",
         %{source: source} do
      # A killed shell revokes nothing; the deadline is the backstop.
      frame = frame!(source, "late-dash", declared!(source, "late-dash"))
      assert action(frame.bearer, "system.status").status == 200

      {1, _} =
        Arca.Repo.update_all(
          from(f in Arca.Schemas.FrameCredential, where: f.id == ^frame.id),
          set: [deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert %{class: "unauthenticated"} = refused(action(frame.bearer, "system.status"), :action)
    end

    test "a bearer this server did not sign as a frame credential is refused", %{source: source} do
      frame = frame!(source, "forged-dash", declared!(source, "forged-dash"))

      assert %{class: "unauthenticated"} =
               refused(action(frame.bearer <> "x", "system.status"), :action)

      {:ok, %{credential: asset}} =
        TinctureAuth.mint_asset_credential(source, declared!(source, "a2"))

      assert %{class: "unauthenticated"} = refused(action(asset, "system.status"), :action)
    end

    test "a credential presented for another version is refused", %{source: source} do
      frame = frame!(source, "moved-dash", declared!(source, "moved-dash"))

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component, where: c.name == "moved-dash"),
          set: [release_digest: "sha256:" <> String.duplicate("f", 64)]
        )

      conn = action(frame.bearer, "system.status")
      assert conn.status == 403
      assert %{class: "forbidden", stage: "admission"} = refused(conn, :action)
    end

    test "a credential presented for another grant is refused", %{source: source} do
      frame = frame!(source, "grant-dash", declared!(source, "grant-dash"), 0)
      assert action(frame.bearer, "system.status").status == 200

      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          source,
          %{
            id: "prof_data_grant",
            kind: :owner,
            source_ref: "tincture:local.grant-dash",
            label: "owner",
            status: :active
          },
          %{
            id: "cons_data_grant",
            revision: 2,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            resolved_policy: "{}",
            activation: %{}
          }
        )

      assert %{class: "forbidden"} = refused(action(frame.bearer, "system.status"), :action)

      # A frame opened under the grant as it now stands is admitted.
      current = frame!(source, "grant-dash", digest_of("grant-dash"), 2)
      assert action(current.bearer, "system.status").status == 200
    end

    test "a credential replayed from elsewhere carries its bound authority and nothing wider",
         %{source: source} do
      frame = frame!(source, "replay-dash", declared!(source, "replay-dash"))
      elsewhere = [ip: {203, 0, 113, 9}, origin: "https://attacker.example"]

      # Proven, not refused: the same person, athanor and declaration...
      conn = action(frame.bearer, "system.status", elsewhere)
      assert conn.status == 200
      # ...and no CORS grant for an origin the deployment does not list.
      assert get_resp_header(conn, "access-control-allow-origin") == []

      # ...and nothing the declaration does not name, as the same person.
      assert %{class: "forbidden"} =
               refused(action(frame.bearer, "execution.list", elsewhere), :action)

      assert [row] = decisions("tincture")
      assert {row.user_id, row.athanor_id} == {source.user_id, source.athanor_id}
    end
  end

  defp digest_of(name) do
    Arca.Repo.one!(
      from(c in Arca.Schemas.Component, where: c.name == ^name, select: c.release_digest)
    )
  end

  # ---------------------------------------------------------------------------
  # The grant
  # ---------------------------------------------------------------------------

  describe "the declaration is the grant" do
    test "an action outside it is refused before dispatch", %{source: source} do
      frame = frame!(source, "narrow-dash", declared!(source, "narrow-dash"))
      conn = action(frame.bearer, "execution.list")

      assert conn.status == 403

      assert %{class: "forbidden", stage: "admission", message: message} =
               refused(conn, :action)

      assert message =~ "does not declare that action"
      # The one decision is this route's refusal: the gate never saw it.
      assert [%{tool: "tincture", action: "system_action", refusal_class: "forbidden"}] =
               Arca.Repo.all(Arca.Schemas.DecisionLog)
    end

    test "a declared component is invoked through the tincture operation with operation and params",
         %{source: source} do
      frame = frame!(source, "inv-dash", declared!(source, "inv-dash"))

      body =
        TinctureWire.request(:invoke, %{
          ref: "r:local.echo:1.0.0",
          operation: "run",
          args: %{"x" => 1}
        })

      conn = data(:invoke, body, bearer: frame.bearer)
      refute conn.resp_body =~ "does not declare"

      assert [row] = mcp_rows("tincture")
      assert row.action == "invoke_protected"

      assert %{
               "publisher" => "local",
               "tincture_name" => "inv-dash",
               "reference" => "r:local.echo:1.0.0",
               "input" => %{"operation" => "run", "params" => %{"x" => 1}}
             } = Jason.decode!(row.input)
    end

    test "a component outside it is refused before dispatch", %{source: source} do
      frame = frame!(source, "inv-narrow", declared!(source, "inv-narrow"))
      body = TinctureWire.request(:invoke, %{ref: "c:local.stripe", operation: "run", args: %{}})
      conn = data(:invoke, body, bearer: frame.bearer)

      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :invoke)
      assert message =~ "does not declare that component"
      refute Enum.any?(decisions("tincture"), &(&1.action == "invoke_protected"))
    end

    test "a stream outside it, or with a subject it does not take, is refused before the gate",
         %{source: source} do
      frame = frame!(source, "stream-narrow", declared!(source, "stream-narrow"))

      for {stream, subject} <- [{"executions.deltas", "exec_1"}, {"mcp_servers.changes", "x"}] do
        body = TinctureWire.request(:stream_open, %{stream: stream, subject: subject})
        conn = data(:stream_open, body, bearer: frame.bearer)
        assert conn.status == 403
        assert %{class: "forbidden", message: message} = refused(conn, :stream_open)
        assert message =~ "does not declare that stream"
      end

      refute Arca.Repo.exists?(
               from(d in Arca.Schemas.DecisionLog, where: like(d.tool, "stream:%"))
             )
    end

    test "a body at another version or with a field its kind does not carry is refused unread",
         %{source: source} do
      frame = frame!(source, "body-dash", declared!(source, "body-dash"))
      body = TinctureWire.request(:action, %{operation: "system.status", args: %{}})

      for bad <- [%{body | "v" => 2}, Map.put(body, "credential", frame.bearer)] do
        conn = data(:action, bad, bearer: frame.bearer)
        assert conn.status == 400
        assert %{class: "invalid_argument"} = refused(conn, :action)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A public tincture's page
  # ---------------------------------------------------------------------------

  describe "a public tincture's page" do
    setup %{source: source} do
      declared!(source, "pub-data")

      {:ok, _} =
        Arca.ProfileStorage.put(%{
          id: "prof_pub_data_#{System.unique_integer([:positive])}",
          athanor_id: source.athanor_id,
          source_ref: "tincture:local.pub-data",
          kind: "public",
          label: "public",
          status: "active"
        })

      declared!(source, "priv-data")
      :ok
    end

    defp public(name), do: %{athanor: "test", publisher: "local", name: name}

    test "invokes under its public profile, named by its address, with no bearer" do
      body =
        TinctureWire.request(:invoke, %{
          ref: "reagent:local.echo:1.0.0",
          operation: "run",
          args: %{},
          public: public("pub-data")
        })

      conn = data(:invoke, body)
      refute conn.status in [400, 401, 404]

      assert [row] = mcp_rows("tincture")
      assert row.action == "invoke_public"
      assert %{"athanor" => "test", "tincture_name" => "pub-data"} = Jason.decode!(row.input)
    end

    test "a private tincture named as public is not found, whoever asks" do
      body =
        TinctureWire.request(:action, %{
          operation: "system.status",
          args: %{},
          public: public("priv-data")
        })

      conn = data(:action, body)
      assert conn.status == 404
      assert %{class: "not_found"} = refused(conn, :action)
    end

    test "a request with a bearer and a public tincture is refused unread", %{source: source} do
      frame = frame!(source, "pub-data", digest_of("pub-data"))

      body =
        TinctureWire.request(:action, %{
          operation: "system.status",
          args: %{},
          public: public("pub-data")
        })

      conn = data(:action, body, bearer: frame.bearer)
      assert conn.status == 400
      assert %{class: "invalid_argument"} = refused(conn, :action)
    end
  end

  # ---------------------------------------------------------------------------
  # Limits
  # ---------------------------------------------------------------------------

  describe "the per-frame invocation rate" do
    setup do
      Cyfr.Test.Settings.put("frame_invocation_max", 2)
      Cyfr.Test.Settings.put("frame_invocation_window_ms", 60_000)
      :ok
    end

    test "is charged per request, refused over its bound with a typed refusal, one frame at a time",
         %{source: source} do
      digest = declared!(source, "rate-dash")
      frame = frame!(source, "rate-dash", digest)
      other = frame!(source, "rate-dash", digest)

      # An undeclared attempt is charged too.
      assert action(frame.bearer, "execution.list").status == 403
      assert action(frame.bearer, "system.status").status == 200

      over = action(frame.bearer, "system.status")
      assert over.status == 429
      assert %{class: "rate_limited", stage: "admission"} = refused(over, :action)
      assert [_seconds] = get_resp_header(over, "retry-after")

      assert action(other.bearer, "system.status").status == 200
    end
  end

  # ---------------------------------------------------------------------------
  # Streams
  # ---------------------------------------------------------------------------

  describe "a stream" do
    setup %{source: source} do
      digest = declared!(source, "live-dash")
      {:ok, frame: frame!(source, "live-dash", digest)}
    end

    defp open_stream(bearer) do
      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      Task.async(fn -> data(:stream_open, body, bearer: bearer) end)
    end

    defp topic(source), do: Cyfr.Bus.mcp_servers(Sanctum.Context.actor(source))

    defp subscribed?(source),
      do: Registry.lookup(Cyfr.PubSub, topic(source)) != []

    # The stream process has taken every `payload` it was sent and waits in
    # its delivery loop for the next: what it was sent is written.
    defp delivered?(stream, payload) do
      case Process.info(stream, [:messages, :status, :current_function]) do
        [messages: messages, status: :waiting, current_function: {CyfrWeb.SSE, :loop, 2}] ->
          not Enum.any?(messages, &is_struct(&1, payload))

        _other ->
          false
      end
    end

    test "is answered as the wire's event stream, and closed within the bound once its frame is suspended",
         %{source: source, frame: frame} do
      stream = open_stream(frame.bearer)
      wait_until(fn -> subscribed?(source) end, @stream_ms)

      actor = Sanctum.Context.actor(source)
      :ok = Cyfr.Bus.broadcast(actor, topic(source), Cyfr.Bus.McpServers.new(actor, :changed))

      suspended_at = System.monotonic_time(:millisecond)
      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      conn = Task.await(stream, 10_000)
      closed_in = System.monotonic_time(:millisecond) - suspended_at

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == [TinctureWire.stream_content_type()]

      assert [
               %{event: "mcp_servers.changes", data: %{"kind" => "changed"}},
               %{event: "refusal", data: %{"class" => "forbidden"}}
             ] = TinctureWire.decode_stream(conn.resp_body)

      # The session-freshness bound and the stream's own tick.
      assert closed_in < 5_000
      refute conn.resp_body =~ "tenant:"
      refute subscribed?(source)

      assert Arca.Repo.exists?(
               from(d in Arca.Schemas.DecisionLog,
                 where: d.tool == "stream:mcp_servers.changes" and d.admission == "admitted"
               )
             )
    end

    test "bound to its holder is each person's own, and a named subject is refused",
         %{source: source} do
      digest =
        tincture!(source, "cards-dash", %{"streams" => [%{"name" => "cards.refreshed"}]}, [])

      other = person!("bystander")
      mine = frame!(source, "cards-dash", digest)
      theirs = frame!(other, "cards-dash", digest)

      # A subject from the frame is never taken, the holder's own included.
      for subject <- [other.user_id, source.user_id] do
        body = TinctureWire.request(:stream_open, %{stream: "cards.refreshed", subject: subject})
        conn = data(:stream_open, body, bearer: mine.bearer)
        assert conn.status == 403
        assert %{message: message} = refused(conn, :stream_open)
        assert message =~ "does not declare that stream"
      end

      body = TinctureWire.request(:stream_open, %{stream: "cards.refreshed", subject: nil})
      my_stream = Task.async(fn -> data(:stream_open, body, bearer: mine.bearer) end)
      their_stream = Task.async(fn -> data(:stream_open, body, bearer: theirs.bearer) end)

      actor = Sanctum.Context.actor(source)
      my_topic = Cyfr.Bus.cards(actor, source.user_id)
      their_topic = Cyfr.Bus.cards(actor, other.user_id)
      wait_until(fn -> Registry.lookup(Cyfr.PubSub, my_topic) != [] end, @stream_ms)
      wait_until(fn -> Registry.lookup(Cyfr.PubSub, their_topic) != [] end, @stream_ms)

      refreshed =
        Cyfr.Bus.CardRefreshed.new(actor, %{
          tincture: "tincture:local.status",
          card: "runs",
          slot: "s0",
          user_id: source.user_id,
          data: %{"name" => "runs", "title" => "Runs", "number" => 3}
        })

      :ok = Cyfr.Bus.broadcast(actor, my_topic, refreshed)

      # A stream re-establishes its caller before delivering once its
      # context is past the freshness bound, so a frame revoked before the
      # event is delivered takes the event with it. The revocation waits
      # until the stream has taken the event and is waiting for the next.
      wait_until(fn -> delivered?(my_stream.pid, Cyfr.Bus.CardRefreshed) end, @stream_ms)

      for {frame, ctx} <- [{mine, source}, {theirs, other}],
          do: {:ok, _} = TinctureAuth.revoke_frame(ctx, frame.id)

      mine_body = Task.await(my_stream, 10_000).resp_body
      theirs_body = Task.await(their_stream, 10_000).resp_body

      assert [
               %{
                 event: "cards.refreshed",
                 data: %{"slot" => "s0", "card" => "runs", "data" => %{"number" => 3}} = event
               }
               | _closing
             ] = TinctureWire.decode_stream(mine_body)

      # The projection carries no person.
      refute Map.has_key?(event, "user_id")
      refute Enum.any?(TinctureWire.decode_stream(theirs_body), &(&1.event == "cards.refreshed"))
    end

    test "holds one of its frame's open-stream slots, released when it closes",
         %{source: source, frame: frame} do
      Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)

      first = open_stream(frame.bearer)
      wait_until(fn -> subscribed?(source) end, @stream_ms)

      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      over = data(:stream_open, body, bearer: frame.bearer)
      assert over.status == 429
      assert %{class: "rate_limited"} = refused(over, :stream_open)

      # Another frame's budget is its own.
      other = frame!(source, "live-dash", digest_of("live-dash"))
      second = open_stream(other.bearer)

      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      Task.await(first, 10_000)
      {:ok, _} = TinctureAuth.resume_frame(source, frame.id)

      # The closed stream released its slot: a reconnect is a new open.
      third = open_stream(frame.bearer)
      wait_until(fn -> length(Registry.lookup(Cyfr.PubSub, topic(source))) == 2 end, @stream_ms)

      for {stream, id} <- [{second, other.id}, {third, frame.id}] do
        {:ok, _} = TinctureAuth.revoke_frame(source, id)
        assert Task.await(stream, 10_000).status == 200
      end
    end
  end
end
