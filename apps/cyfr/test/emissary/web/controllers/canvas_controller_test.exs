# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.CanvasControllerTest do
  @moduledoc """
  A canvas's host page (`/_c/v1/<asset credential>/<frame id>`): served
  only for a standing asset credential and a standing frame of its person,
  athanor and version, for a version whose placement is `canvas`, and 404
  with no body otherwise; the canvas's one policy for its own open; the
  toolkit's host bundle as its one script and the worker bundle only as
  inert data; no bearer in its markup; no redirect on any canvas, data or
  served path; and the credential in no telemetry span or log line.
  """

  # Mints credentials, flips the rate limit and the global log level,
  # and attaches telemetry handlers, all of them process-wide.
  use CyfrWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Sanctum.TinctureAuth

  @version "1.0.0"

  @toolkit Path.join(:code.priv_dir(:cyfr), "static/toolkit")

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)

    _athanor = Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)

    digest = canvas!(source, "page-canvas")
    open = frame!(source, "page-canvas", digest)

    {:ok, source: source, digest: digest, credential: asset!(source, digest), open: open}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A version's row in the source's athanor, as the registry records it.
  # Answers its release digest.
  defp put_version!(ctx, name, tincture) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => tincture
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

  defp canvas!(ctx, name) do
    put_version!(ctx, name, %{
      "frame" => %{"placement" => "canvas"},
      "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
      "streams" => [%{"name" => "mcp_servers.changes"}]
    })
  end

  defp asset!(source, digest) do
    {:ok, %{credential: credential}} = TinctureAuth.mint_asset_credential(source, digest)
    credential
  end

  # An open the shell made of `name`: its bearer, row id and frame id.
  defp frame!(source, name, digest, mint \\ :mint_frame_credential) do
    frame = "frm_page_#{System.unique_integer([:positive])}"
    reference = %{publisher: "local", name: name, version: @version}

    {:ok, %{credential: bearer, id: id}} =
      apply(TinctureAuth, mint, [source, reference, digest, 0, frame])

    %{bearer: bearer, id: id, frame_id: frame}
  end

  defp page(credential, frame_id, opts \\ []) do
    build_conn()
    |> Map.put(:req_headers, Keyword.get(opts, :headers, []))
    |> get(Prima.CanvasWire.page_path(credential, frame_id))
  end

  # The endpoint's origin as a tincture document's policy names it:
  # read off `Emissary.Web.TinctureAssets.csp/2`'s own `frame-ancestors`.
  defp endpoint_origin do
    [_, origin] =
      Regex.run(
        ~r/frame-ancestors ([^;]+)/,
        Emissary.Web.TinctureAssets.csp(%{}, String.duplicate("n", 22))
      )

    origin
  end

  defp toolkit(file), do: File.read!(Path.join(@toolkit, file))

  # ---------------------------------------------------------------------------
  # The page
  # ---------------------------------------------------------------------------

  describe "the host page" do
    test "the host page carries the canvas policy and the worker bundle only as inert data", %{
      credential: credential,
      open: open
    } do
      conn = page(credential, open.frame_id, headers: [{"accept-encoding", "gzip"}])
      assert conn.status == 200

      body = conn.resp_body
      host = toolkit("host.js")
      worker = toolkit("worker.js")

      # The page is exactly the host script under the nonce and the inert
      # element holding the worker bundle.
      assert [_, nonce] =
               Regex.run(
                 ~r/\A<!doctype html><html><head><meta charset="utf-8"><script nonce="([A-Za-z0-9_-]{22})">/,
                 body
               )

      head =
        ~s(<!doctype html><html><head><meta charset="utf-8"><script nonce="#{nonce}">) <>
          host <>
          ~s(</script></head><body><script type="application/json" id="cyfr-toolkit-worker">)

      assert String.starts_with?(body, head)
      assert String.ends_with?(body, "</script></body></html>")

      inert =
        body
        |> binary_part(byte_size(head), byte_size(body) - byte_size(head))
        |> String.replace_suffix("</script></body></html>", "")

      # One JSON string, the worker bundle whole, holding no `<`.
      assert Jason.decode!(inert) == worker
      refute inert =~ "<"

      # Two script elements and no other markup that runs: the host bundle's,
      # under the nonce, and the inert one. The worker bundle as it is
      # written is nowhere in the page.
      assert length(Regex.scan(~r/<script/i, body)) == 2
      assert length(Regex.scan(~r/<script nonce=/, body)) == 1
      refute String.contains?(body, worker)
      refute body =~ ~r/<(iframe|object|embed|base|link|meta http-equiv)/i

      # The canvas's one policy, for this open, under this page's nonce.
      endpoint = endpoint_origin()

      assert get_resp_header(conn, "content-security-policy") == [
               Compendium.tincture_canvas_page_csp(%{
                 endpoint: endpoint,
                 shell: endpoint,
                 asset_credential: credential,
                 frame_id: open.frame_id,
                 nonce: nonce
               })
             ]

      [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "connect-src #{endpoint}#{Prima.CanvasWire.data_path(open.frame_id)};"
      assert policy =~ "sandbox allow-scripts"

      # The served files' document headers, never cached, framed only by
      # the shell, and sent as they are.
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert get_resp_header(conn, "content-encoding") == []

      # No bearer and no frame id in the markup; the asset credential only
      # in the policy.
      refute body =~ open.bearer
      refute body =~ open.frame_id
      refute body =~ credential

      # Each page its own nonce.
      again = page(credential, open.frame_id)
      refute again.resp_body =~ ~s(nonce="#{nonce}")
    end

    test "a suspended open and a validation trial are served their page", %{
      source: source,
      digest: digest,
      credential: credential,
      open: open
    } do
      {:ok, _} = TinctureAuth.suspend_frame(source, open.id)
      assert page(credential, open.frame_id).status == 200

      trial = frame!(source, "page-canvas", digest, :mint_validation_credential)
      assert page(credential, trial.frame_id).status == 200
    end

    test "a page for another person's frame, another athanor's, a revoked one, an expired one, or one of another version is 404",
         %{source: source, digest: digest, credential: credential} do
      # Another person of the athanor opened the same version.
      bystander =
        Sanctum.TestContext.issuer!(%{
          Sanctum.TestContext.local()
          | user_id: "local|local|page-bystander",
            namespace: "page-bystander"
        })

      {:ok, session} = Sanctum.TestContext.create_session(bystander)
      {:ok, theirs_ctx} = Sanctum.Caller.establish(session.token)
      theirs = frame!(theirs_ctx, "page-canvas", digest)

      # The person's own frame of the version, in another athanor.
      elsewhere = "frm_page_elsewhere_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arca.FrameCredentials.mint(Prima.Actor.in_athanor("ath_page_elsewhere"), %{
          user_id: source.user_id,
          publisher: "local",
          name: "page-canvas",
          version: @version,
          version_digest: digest,
          grant_revision: 0,
          frame_id: elsewhere,
          source_kind: "session",
          source_id: source.credential_binding.source_id,
          deadline: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      revoked = frame!(source, "page-canvas", digest)
      {:ok, _} = TinctureAuth.revoke_frame(source, revoked.id)

      expired = frame!(source, "page-canvas", digest)

      {1, _} =
        Arca.Repo.update_all(
          from(f in Arca.Schemas.FrameCredential, where: f.id == ^expired.id),
          set: [deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      # An open of another canvas version, under this version's credential.
      another = frame!(source, "other-canvas", canvas!(source, "other-canvas"))

      for frame_id <- [
            theirs.frame_id,
            elsewhere,
            revoked.frame_id,
            expired.frame_id,
            another.frame_id
          ] do
        conn = page(credential, frame_id)
        assert {conn.status, conn.resp_body} == {404, ""}, frame_id
      end
    end

    test "a non-canvas version, or a credential that does not stand, is 404 with no body", %{
      source: source,
      credential: credential,
      open: open
    } do
      # A tincture that is not a canvas, opened and served under its own
      # credential: it has no host page.
      plain_digest = put_version!(source, "plain-page", %{"entry" => "index.html"})
      plain = frame!(source, "plain-page", plain_digest)

      unsigned = String.duplicate("a", 40)
      malformed_frame = build_conn() |> get("/_c/v1/#{credential}/x")
      bearer_as_credential = build_conn() |> get("/_c/v1/#{open.bearer}/#{open.frame_id}")

      for conn <- [
            page(asset!(source, plain_digest), plain.frame_id),
            page(credential <> "x", open.frame_id),
            page(unsigned, open.frame_id),
            malformed_frame,
            bearer_as_credential
          ] do
        assert {conn.status, conn.resp_body} == {404, ""}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A store that cannot answer, and the host bundle the page inlines
  # ---------------------------------------------------------------------------

  describe "a store outage" do
    # Each case fails one table and reads nothing after the request: the
    # test's transaction gives the table back.
    test "the page answers 503 with retry-after while the frame read cannot answer", %{
      credential: credential,
      open: open
    } do
      assert page(credential, open.frame_id).status == 200
      Arca.Repo.query!("ALTER TABLE frame_credentials RENAME TO frame_credentials_unavailable")

      conn = page(credential, open.frame_id)
      assert json_response(conn, 503)["code"] == "unavailable"
      assert get_resp_header(conn, "retry-after") == ["5"]
      refute conn.resp_body =~ "cyfr-toolkit-worker"
    end

    test "the page answers 503 with retry-after while the version read cannot answer", %{
      credential: credential,
      open: open
    } do
      assert page(credential, open.frame_id).status == 200
      Arca.Repo.query!("ALTER TABLE components RENAME TO components_unavailable")

      conn = page(credential, open.frame_id)
      assert json_response(conn, 503)["code"] == "unavailable"
      assert get_resp_header(conn, "retry-after") == ["5"]
      refute conn.resp_body =~ "cyfr-toolkit-worker"
    end
  end

  describe "the host bundle" do
    test "a bundle holding </script in any case, or <!--, is not page-safe, and the shipped one is" do
      assert Emissary.Web.CanvasController.page_safe?(toolkit("host.js"))
      assert Emissary.Web.CanvasController.page_safe?("if (a < b) { s = '<scr' + 'ipt>' }")

      for unsafe <- ["a</script>b", "a</SCRIPT b", "a</ScRiPt", "a<!--b", "<!-- x -->"] do
        refute Emissary.Web.CanvasController.page_safe?(unsafe), unsafe
      end

      # The build holds the embedded bundle to it once the module exists.
      assert Emissary.Web.CanvasController.__after_compile__(nil, nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # No redirects
  # ---------------------------------------------------------------------------

  describe "redirects" do
    test "no canvas page, data or served path answers a redirect", %{
      credential: credential,
      open: open
    } do
      page_path = Prima.CanvasWire.page_path(credential, open.frame_id)
      stream_path = Prima.CanvasWire.stream_path(open.frame_id)
      served = Prima.TinctureUrl.asset_path(credential, ["local", "page-canvas", @version])

      # Each answers its own status, and none a 3xx or a location: a
      # trailing slash, a malformed credential or frame id, a data request
      # with no body (refused before its bearer is read), and paths no
      # route takes, which the router answers 404.
      cases = [
        {:get, page_path <> "/", 200},
        {:get, "/_c/v1/short/#{open.frame_id}", 404},
        {:get, "/_c/v1/#{credential}/x", 404},
        {:get, "/_c/v1/#{credential}/has%20space", 404},
        {:get, page_path <> "/extra", 404},
        {:get, Prima.CanvasWire.page_prefix() <> credential, 404},
        {:get, "/_c/v1", 404},
        {:post, stream_path, 400},
        {:post, stream_path <> "/", 400},
        {:post, "/_f/v1/o/x/stream", 400},
        {:post, stream_path <> "/extra", 404},
        {:post, Prima.CanvasWire.data_path(open.frame_id) <> "invoke", 404},
        {:get, stream_path, 404},
        {:get, served <> "/", 404},
        {:get, served <> "/canvas.js/", 404},
        {:get, "/_s/short/local/page-canvas/#{@version}/canvas.js", 404},
        {:get, "/_s", 404}
      ]

      for {verb, path, status} <- cases do
        conn = dispatch(build_conn(), CyfrWeb.Endpoint, verb, path, nil)
        assert conn.status == status, "#{verb} #{path}: #{conn.status}"
        assert get_resp_header(conn, "location") == [], "#{verb} #{path}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The credential in what names the request
  # ---------------------------------------------------------------------------

  describe "the credential" do
    # The suite logs at `:warning`, below which nothing reaches a capture;
    # a request line is logged at `:info` (`Phoenix.Logger`), so this module,
    # which runs alone, lowers the level to it and restores it.
    setup do
      previous = Application.get_env(:cyfr, :tincture_rate_limit_max)
      level = Logger.level()
      Logger.configure(level: :info)

      on_exit(fn ->
        Logger.configure(level: level)
        Application.put_env(:cyfr, :tincture_rate_limit_max, previous)
        Prima.RateLimiter.reset()
      end)

      :ok
    end

    test "no telemetry span or log line names a page's credential, refused, malformed or rate-limited included",
         %{credential: credential, open: open} do
      test_pid = self()
      handler = "canvas-scrub-#{System.unique_integer([:positive])}"
      canary = "c4n4ryP4geCredential0123456789_-"

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:phoenix, :endpoint, :start],
            [:phoenix, :endpoint, :stop],
            [:phoenix, :router_dispatch, :start]
          ],
          fn event, _measurements, %{conn: seen} = metadata, _config ->
            send(test_pid, {:seen, event, seen.request_path, Map.get(metadata, :route)})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      frame = open.frame_id

      log =
        capture_log([level: :info], fn ->
          # A page, and the same page under its prefix written with escapes,
          # which the router decodes and serves.
          assert page(credential, frame).status == 200
          assert get(build_conn(), "/%5Fc/v1/#{credential}/#{frame}").status == 200
          assert get(build_conn(), "/_c/%76%31/#{credential}/#{frame}").status == 200

          # A served file under the served-file prefix written with an escape.
          served =
            get(build_conn(), "/%5Fs/#{credential}/local/page-canvas/#{@version}/canvas.js")

          refute served.status in 300..399

          # A malformed credential, and a credential refused.
          assert get(build_conn(), "/_c/v1/#{canary}!/#{frame}").status == 404
          assert page(canary, frame).status == 404
          assert get(build_conn(), "/%5Fc/v1/#{canary}/#{frame}").status == 404

          # A response the rate limit answers before the action.
          Application.put_env(:cyfr, :tincture_rate_limit_max, 1)
          Prima.RateLimiter.reset()
          assert page(credential, frame).status == 200
          assert page(canary, frame).status == 429
        end)

      # Every request's endpoint start and stop, at the least.
      seen = collect_seen([])
      assert length(seen) >= 18

      for {_event, path, _route} <- seen do
        refute path =~ credential
        refute path =~ canary
        assert path =~ "/[REDACTED]/", path
      end

      # The dispatch names the route by its pattern, not the path.
      assert Enum.any?(seen, fn {event, _path, route} ->
               event == [:phoenix, :router_dispatch, :start] and
                 route == "/_c/v1/:credential/:frame_id"
             end)

      # The request lines were logged, each naming the redacted path, and
      # nothing logged names either credential.
      assert log =~ "GET /_c/v1/[REDACTED]/#{frame}"
      assert log =~ "GET /%5Fc/v1/[REDACTED]/#{frame}"
      assert log =~ "GET /_c/%76%31/[REDACTED]/#{frame}"
      assert log =~ "GET /%5Fs/[REDACTED]/local/page-canvas/#{@version}/canvas.js"
      refute log =~ credential
      refute log =~ canary
    end
  end

  defp collect_seen(acc) do
    receive do
      {:seen, event, path, route} -> collect_seen([{event, path, route} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
