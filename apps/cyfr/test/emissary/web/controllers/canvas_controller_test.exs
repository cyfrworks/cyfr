# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.CanvasControllerTest do
  @moduledoc """
  A canvas's page (`/_c/v1/<asset credential>/<frame id>`): the version's
  own entry, served only for a standing asset credential and a standing
  frame of its person, athanor and version, while its release digest is
  the credential's, for a version whose placement is `canvas`, and 404
  with no body otherwise, a missing entry included; its `<base>` and the
  SDK's script first in its head, no nonce and no inline script in it;
  the canvas's one policy for its own open and the connection allowlist on
  the page alone; relative URLs of a vanilla and a react page resolving to
  the version's files under the `<base>`, which a page's own `<base>`
  never precedes; no credential in the page beyond the asset credential
  its own address carries; the SDK at its one digest-named path and
  nothing else under it; no HTML file of a canvas, or of a version whose
  declaration today's rules refuse, served as a page on the served files'
  route; no redirect on any canvas, SDK, data or served path; and the
  credential in no telemetry span or log line.
  """

  # Mints credentials, flips the rate limit and the global log level,
  # and attaches telemetry handlers, all of them process-wide.
  use CyfrWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Sanctum.TinctureAuth

  alias Emissary.Web.TinctureAssets

  @version "1.0.0"

  @sdk_bundle Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js")

  # A vanilla canvas's entry and the files its relative URLs name.
  @entry ~s(<!doctype html><html lang="en"><head><meta charset="utf-8">) <>
           ~s(<link rel="stylesheet" href="style.css"></head>) <>
           ~s(<body><main id="app"></main><script src="app.js"></script></body></html>)

  @files [
    {"index.html", @entry},
    {"app.js", ~s|cyfr.ready();\n|},
    {"style.css", "main { margin: 0; }"}
  ]

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    :ok = own_storage(%{})

    _athanor = Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)

    digest = canvas!(source, "page-canvas")
    lay!(source, "page-canvas", @files)
    open = frame!(source, "page-canvas", digest)

    {:ok,
     source: source,
     session: session,
     digest: digest,
     credential: asset!(source, digest),
     open: open}
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

    acknowledged!(ctx)
    release_digest
  end

  # The rows these fixtures write are the registry's, as a commit would
  # have written them: the root's projection is told it holds them after a
  # row is written and after a unit is laid, so a read derives nothing
  # over them from the units the fixtures commit.
  defp acknowledged!(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, "components")

    {:ok, :acknowledged} =
      Arca.StorageProjectionChanges.replace(actor, "components", token, fn -> :acknowledged end)

    :ok
  end

  defp canvas!(ctx, name, tincture \\ %{"entry" => "index.html"}) do
    put_version!(
      ctx,
      name,
      Map.merge(
        %{"frame" => %{"placement" => "canvas"}, "streams" => [%{"name" => "runs.changes"}]},
        tincture
      )
    )
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
    |> get(Prima.TinctureWire.page_path(credential, frame_id))
  end

  # The endpoint's origin as a tincture document's policy names it.
  defp endpoint_origin, do: TinctureAssets.endpoint_origin()

  # The two tags CYFR puts first in a canvas page's head: the `<base>` of
  # the entry's directory under the version's served prefix, and the
  # SDK's script from its one path.
  defp canvas_tags(credential, name, entry_dir \\ "") do
    base =
      endpoint_origin() <>
        Prima.TinctureUrl.asset_path(credential, ["local", name, @version]) <> "/" <> entry_dir

    {base,
     ~s(<base href="#{base}">) <>
       ~s(<script src="#{endpoint_origin()}#{TinctureAssets.canvas_sdk_path()}"></script>)}
  end

  # What a URL the page writes resolves to under its `<base>`, as a path
  # of the endpoint, and that path's answer.
  defp resolved(base, url) do
    %URI{path: path} = URI.merge(base, url)
    {path, get(build_conn(), path)}
  end

  # The versions' files in a storage root of the test's own, the
  # configured one restored after it.
  defp own_storage(_context) do
    root = Path.join(System.tmp_dir!(), "canvas_page_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, root)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  # `files` landed as the version `name` of the source's athanor, one unit.
  defp lay!(source, name, files) do
    Arca.Test.UnitFixtures.tenant_component!(source, "tincture", "local", name, @version,
      files: files
    )

    acknowledged!(source)
  end

  # A file of the version `name` under its served prefix.
  defp served(credential, name, file),
    do:
      get(build_conn(), Prima.TinctureUrl.asset_path(credential, ["local", name, @version, file]))

  # ---------------------------------------------------------------------------
  # The page
  # ---------------------------------------------------------------------------

  describe "the page" do
    test "is the version's entry with its <base> and the SDK's script first in its head", %{
      credential: credential,
      open: open
    } do
      conn = page(credential, open.frame_id, headers: [{"accept-encoding", "gzip"}])
      assert conn.status == 200
      body = conn.resp_body

      # The entry's bytes whole, with CYFR's two tags right after its
      # `<head>`: the `<base>`, then the SDK's script, and nothing else.
      {_base, tags} = canvas_tags(credential, "page-canvas")
      [before, rest] = String.split(@entry, "<head>", parts: 2)
      assert body == before <> "<head>" <> tags <> rest

      # No nonce anywhere, and no inline script: every script element
      # loads its source.
      refute body =~ "nonce"
      scripts = Regex.scan(~r/<script\b[^>]*>/i, body) |> List.flatten()
      assert length(scripts) == 2
      for script <- scripts, do: assert(script =~ ~r/\ssrc="/, script)
      assert length(Regex.scan(~r{<script\b[^>]*></script>}i, body)) == 2

      # The canvas's one policy, for this open, naming the SDK's one path.
      endpoint = endpoint_origin()

      policy =
        Compendium.tincture_canvas_page_csp(%{
          endpoint: endpoint,
          shell: endpoint,
          asset_credential: credential,
          frame_id: open.frame_id,
          sdk_path: TinctureAssets.canvas_sdk_path()
        })

      assert get_resp_header(conn, "content-security-policy") == [policy]

      assert policy =~
               "script-src #{endpoint}/_s/#{credential}/ #{endpoint}#{TinctureAssets.canvas_sdk_path()};"

      assert policy =~
               "connect-src #{endpoint}#{Prima.TinctureWire.data_path(open.frame_id)} "

      assert policy =~ "sandbox allow-scripts"

      # Chromium's connection allowlist, the page's alone.
      assert get_resp_header(conn, "connection-allowlist") == ["(response-origin)"]

      assert get_resp_header(conn, "connection-allowlist") == [
               Compendium.tincture_canvas_connection_allowlist()
             ]

      # The served files' document headers, never cached, framed only by
      # the shell, and sent as they are.
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert get_resp_header(conn, "content-encoding") == []

      # No frame id in the markup.
      refute body =~ open.frame_id
    end

    test "carries no credential beyond the one its own address carries: the asset credential " <>
           "only where the page's address carries it, and no bearer or frame credential",
         %{source: source, session: session, digest: digest, credential: credential, open: open} do
      trial = frame!(source, "page-canvas", digest, :mint_validation_credential)
      conn = page(credential, open.frame_id)
      assert conn.status == 200
      body = conn.resp_body

      # The asset credential is the page's own address's, which the page's
      # script can read in its URL: in the body it is only in the `<base>`
      # that resolves the page's relative URLs under that address.
      assert Prima.TinctureWire.page_path(credential, open.frame_id) =~ credential
      {base, _tags} = canvas_tags(credential, "page-canvas")
      assert [_one] = Regex.scan(~r/#{Regex.escape(credential)}/, body)
      assert body =~ ~s(<base href="#{base}">)

      # No other credential, in the body or any header: not the person's
      # session bearer, not the open's frame credential, not a validation
      # trial's.
      for {name, other} <- [
            {"session bearer", session.token},
            {"frame credential", open.bearer},
            {"validation credential", trial.bearer}
          ] do
        refute body =~ other, "the page's body carries the #{name}"

        for {header, value} <- conn.resp_headers,
            do: refute(value =~ other, "the page's #{header} carries the #{name}")
      end
    end

    test "a vanilla page's relative URLs resolve to the version's own files under its <base>", %{
      credential: credential,
      open: open
    } do
      assert page(credential, open.frame_id).status == 200
      {base, _tags} = canvas_tags(credential, "page-canvas")

      for {url, file} <- [{"app.js", "app.js"}, {"./style.css", "style.css"}] do
        {path, conn} = resolved(base, url)

        assert path ==
                 Prima.TinctureUrl.asset_path(credential, ["local", "page-canvas", @version, file])

        assert {conn.status, conn.resp_body} == {200, List.keyfind(@files, file, 0) |> elem(1)}
      end

      # The policy admits each: the version's files under the credential.
      [policy] = get_resp_header(page(credential, open.frame_id), "content-security-policy")
      assert String.starts_with?(base, "#{endpoint_origin()}/_s/#{credential}/")
      assert policy =~ "script-src #{endpoint_origin()}/_s/#{credential}/ "
    end

    test "a react page's ./assets/ URLs resolve under its build's directory", %{source: source} do
      entry =
        ~s(<!doctype html><html><head><script type="module" crossorigin ) <>
          ~s(src="./assets/index-a1.js"></script>) <>
          ~s(<link rel="stylesheet" href="./assets/index-b2.css"></head>) <>
          ~s(<body><div id="root"></div></body></html>)

      digest =
        canvas!(source, "react-canvas", %{
          "entry" => "dist/index.html",
          "build" => %{"tool" => "vite"}
        })

      lay!(source, "react-canvas", [
        {"index.html", "<!doctype html><html><head></head><body>source</body></html>"},
        {"src/main.tsx", "export {};"},
        {"package.json", "{}"},
        {"package-lock.json", "{}"},
        {"dist/index.html", entry},
        {"dist/assets/index-a1.js", "export const a = 1;"},
        {"dist/assets/index-b2.css", "body{}"}
      ])

      credential = asset!(source, digest)
      open = frame!(source, "react-canvas", digest)

      conn = page(credential, open.frame_id)
      assert conn.status == 200

      # The built entry is the page, its `<base>` its build's directory.
      {base, tags} = canvas_tags(credential, "react-canvas", "dist/")
      [before, rest] = String.split(entry, "<head>", parts: 2)
      assert conn.resp_body == before <> "<head>" <> tags <> rest
      refute conn.resp_body =~ "source"

      for {url, file, bytes} <- [
            {"./assets/index-a1.js", "dist/assets/index-a1.js", "export const a = 1;"},
            {"./assets/index-b2.css", "dist/assets/index-b2.css", "body{}"}
          ] do
        {path, served} = resolved(base, url)

        assert path ==
                 Prima.TinctureUrl.asset_path(
                   credential,
                   ["local", "react-canvas", @version | String.split(file, "/")]
                 )

        assert {served.status, served.resp_body} == {200, bytes}
      end
    end

    test "a <base> the page writes comes after CYFR's, and the policy names its files alone", %{
      source: source
    } do
      entry =
        ~s(<html><head><base href="https://elsewhere.example/"><title>x</title></head>) <>
          ~s(<body><script src="app.js"></script></body></html>)

      digest = canvas!(source, "based-canvas")
      lay!(source, "based-canvas", [{"index.html", entry}, {"app.js", "1;"}])
      credential = asset!(source, digest)
      open = frame!(source, "based-canvas", digest)

      conn = page(credential, open.frame_id)
      assert conn.status == 200

      {base, tags} = canvas_tags(credential, "based-canvas")
      assert String.starts_with?(conn.resp_body, "<html><head>" <> tags <> "<base href=")

      # The first `<base>` is the document's; and the policy lets a `<base>`
      # name the version's own files and nothing else.
      [first | _] = Regex.scan(~r/<base href="([^"]*)">/, conn.resp_body, capture: :all_but_first)
      assert first == [base]

      [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "; base-uri #{endpoint_origin()}/_s/#{credential}/;"
    end

    test "a version whose entry is not among its stored files is 404 with no body", %{
      source: source
    } do
      digest = canvas!(source, "lost-canvas")
      lay!(source, "lost-canvas", [{"app.js", "1;"}])
      open = frame!(source, "lost-canvas", digest)

      conn = page(asset!(source, digest), open.frame_id)
      assert {conn.status, conn.resp_body} == {404, ""}
      assert get_resp_header(conn, "connection-allowlist") == []
    end

    test "a page whose release digest is no longer the credential's is 404 with no body", %{
      credential: credential,
      open: open
    } do
      assert page(credential, open.frame_id).status == 200

      # The version's row now records other bytes: the credential names a
      # release that is no longer this version's.
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component,
            where: c.name == "page-canvas" and c.version == ^@version
          ),
          set: [release_digest: "sha256:" <> String.duplicate("0", 64)]
        )

      conn = page(credential, open.frame_id)
      assert {conn.status, conn.resp_body} == {404, ""}
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
        refused_bare!(conn)
      end
    end

    test "a non-canvas version, or a credential that does not stand, is 404 with no body", %{
      source: source,
      credential: credential,
      open: open
    } do
      # A tincture that is not a canvas, opened and served under its own
      # credential: it has no canvas page, though it has an entry.
      plain_digest = put_version!(source, "plain-page", %{"entry" => "index.html"})
      lay!(source, "plain-page", [{"index.html", "<html><head></head><body>p</body></html>"}])
      plain = frame!(source, "plain-page", plain_digest)

      # A canvas whose declaration today's rules refuse: no page either.
      off_digest = canvas!(source, "off-canvas", %{"entry" => "page.html"})
      lay!(source, "off-canvas", [{"page.html", "<html><head></head><body>o</body></html>"}])
      off = frame!(source, "off-canvas", off_digest)

      unsigned = String.duplicate("a", 40)
      malformed_frame = build_conn() |> get("/_c/v1/#{credential}/x")
      bearer_as_credential = build_conn() |> get("/_c/v1/#{open.bearer}/#{open.frame_id}")

      for conn <- [
            page(asset!(source, plain_digest), plain.frame_id),
            page(asset!(source, off_digest), off.frame_id),
            page(credential <> "x", open.frame_id),
            page(unsigned, open.frame_id),
            malformed_frame,
            bearer_as_credential
          ] do
        assert {conn.status, conn.resp_body} == {404, ""}
        refused_bare!(conn)
      end
    end
  end

  # A refusal carries no page header: no canvas policy and no connection
  # allowlist.
  defp refused_bare!(conn) do
    assert get_resp_header(conn, "connection-allowlist") == []
    refute Enum.any?(get_resp_header(conn, "content-security-policy"), &(&1 =~ "sandbox"))
  end

  # ---------------------------------------------------------------------------
  # The SDK the page loads
  # ---------------------------------------------------------------------------

  describe "the SDK" do
    test "is served at the one path its digest names, the bundle's bytes as they are" do
      bundle = File.read!(@sdk_bundle)
      digest = :sha256 |> :crypto.hash(bundle) |> Base.encode16(case: :lower)
      path = TinctureAssets.canvas_sdk_path()

      assert path == Prima.TinctureWire.page_prefix() <> "sdk/" <> digest <> ".js"

      conn = get(build_conn(), path)
      assert {conn.status, conn.resp_body} == {200, bundle}
      assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "location") == []
      assert get_resp_header(conn, "connection-allowlist") == []
      assert TinctureAssets.canvas_sdk() == bundle
    end

    test "no other name under its prefix is served", %{credential: credential, open: open} do
      path = TinctureAssets.canvas_sdk_path()
      "/_c/v1/sdk/" <> file = path

      for other <- [
            "/_c/v1/sdk/" <> String.duplicate("0", 64) <> ".js",
            "/_c/v1/sdk/cyfr.js",
            "/_c/v1/sdk/" <> String.replace_suffix(file, ".js", ".mjs"),
            "/_c/v1/sdk/" <> String.upcase(file),
            "/_c/v1/sdk/" <> credential,
            "/_c/v1/sdk/" <> open.frame_id
          ] do
        conn = get(build_conn(), other)
        assert {other, conn.status, conn.resp_body} == {other, 404, ""}
      end

      # The page's route never takes the SDK's path, nor the SDK's a page.
      assert page(credential, open.frame_id).status == 200
    end
  end

  # ---------------------------------------------------------------------------
  # A version that holds no page: a canvas, or one whose placement cannot
  # be read
  # ---------------------------------------------------------------------------

  describe "a version that holds no page on the served files' route" do
    test "a canvas version's HTML files, its entry included, are not found there; its other files are served",
         %{source: source, credential: credential} do
      lay!(source, "page-canvas", @files ++ [{"page.html", "<html><head></head></html>"}])

      absent = served(credential, "page-canvas", "absent.js")
      assert json_response(absent, 404)["code"] == "not_found"

      # Each page answers exactly as a file the store does not hold.
      for file <- ["index.html", "page.html"] do
        conn = served(credential, "page-canvas", file)

        assert {file, conn.status, get_resp_header(conn, "content-type"), conn.resp_body} ==
                 {file, absent.status, get_resp_header(absent, "content-type"), absent.resp_body}

        refute Enum.any?(get_resp_header(conn, "content-security-policy"), &(&1 =~ "sandbox"))
      end

      # A script beside them is served as the script it is, nothing injected.
      script = served(credential, "page-canvas", "app.js")

      assert {script.status, get_resp_header(script, "content-type"), script.resp_body} ==
               {200, ["text/javascript; charset=utf-8"],
                List.keyfind(@files, "app.js", 0) |> elem(1)}

      assert get_resp_header(script, "content-security-policy") == [
               "default-src 'none'; frame-ancestors 'none'"
             ]
    end

    test "a version whose declaration today's rules refuse is held as a canvas: no page, no document",
         %{source: source} do
      # Installed straight into the registry's storage, past the publish
      # check, as a rules change after install leaves a version: a
      # placement the rules no longer name, with a page or a script for
      # its entry, and a canvas off its templates.
      plants = [
        {"desk-dash", %{"frame" => %{"placement" => "desktop"}, "entry" => "index.html"}},
        {"desk-js", %{"frame" => %{"placement" => "desktop"}, "entry" => "main.js"}},
        {"off-canvas", %{"frame" => %{"placement" => "canvas"}, "entry" => "main.js"}}
      ]

      scripts = %{"main.js" => ~s|const t = "<head></head>";\n|}

      for {name, tincture} <- plants do
        assert {:error, _refused} = Compendium.tincture_declaration(%{"tincture" => tincture})
        credential = asset!(source, put_version!(source, name, tincture))

        lay!(source, name, [
          {"index.html", "<html><head></head><body>Desk</body></html>"},
          {"style.css", "body { margin: 0; }"} | Map.to_list(scripts)
        ])

        # Its page answers exactly as a file the store does not hold.
        page = served(credential, name, "index.html")
        absent = served(credential, name, "absent.js")
        assert json_response(absent, 404)["code"] == "not_found"

        assert {name, page.status, get_resp_header(page, "content-type"), page.resp_body} ==
                 {name, absent.status, get_resp_header(absent, "content-type"), absent.resp_body}

        # Its scripts, whichever is its entry, are scripts: the lockdown
        # policy, never a document's, and their bytes with nothing injected.
        for {file, bytes} <- scripts do
          conn = served(credential, name, file)

          assert {name, file, conn.status, get_resp_header(conn, "content-type"),
                  get_resp_header(conn, "content-security-policy"), conn.resp_body} ==
                   {name, file, 200, ["text/javascript; charset=utf-8"],
                    ["default-src 'none'; frame-ancestors 'none'"], bytes}
        end

        style = served(credential, name, "style.css")
        assert {name, style.status, style.resp_body} == {name, 200, "body { margin: 0; }"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A store that cannot answer
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
      refute conn.resp_body =~ "<base"
      assert get_resp_header(conn, "connection-allowlist") == []
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
      refute conn.resp_body =~ "<base"
      assert get_resp_header(conn, "connection-allowlist") == []
    end
  end

  # ---------------------------------------------------------------------------
  # No redirects
  # ---------------------------------------------------------------------------

  describe "redirects" do
    test "no canvas page, SDK, data or served path answers a redirect", %{
      credential: credential,
      open: open
    } do
      page_path = Prima.TinctureWire.page_path(credential, open.frame_id)
      stream_path = Prima.TinctureWire.stream_path(open.frame_id)
      served = Prima.TinctureUrl.asset_path(credential, ["local", "page-canvas", @version])
      sdk = TinctureAssets.canvas_sdk_path()

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
        {:get, Prima.TinctureWire.page_prefix() <> credential, 404},
        {:get, "/_c/v1", 404},
        {:get, sdk, 200},
        {:get, sdk <> "/", 200},
        {:get, String.replace_suffix(sdk, ".js", ""), 404},
        {:get, sdk <> "/extra", 404},
        {:get, "/_c/v1/sdk", 404},
        {:get, "/_c/v1/sdk/", 404},
        {:post, sdk, 404},
        {:post, stream_path, 400},
        {:post, stream_path <> "/", 400},
        {:post, "/_f/v1/o/x/stream", 400},
        {:post, stream_path <> "/extra", 404},
        {:post, Prima.TinctureWire.data_path(open.frame_id) <> "invoke", 404},
        {:get, stream_path, 404},
        {:get, served <> "/", 404},
        {:get, served <> "/app.js", 200},
        {:get, served <> "/app.js/", 200},
        {:get, served <> "/index.html", 404},
        {:get, "/_s/short/local/page-canvas/#{@version}/app.js", 404},
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
        Prima.Test.RateLimiter.reset!()
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
            get(build_conn(), "/%5Fs/#{credential}/local/page-canvas/#{@version}/app.js")

          refute served.status in 300..399

          # A malformed credential, and a credential refused.
          assert get(build_conn(), "/_c/v1/#{canary}!/#{frame}").status == 404
          assert page(canary, frame).status == 404
          assert get(build_conn(), "/%5Fc/v1/#{canary}/#{frame}").status == 404

          # A response the rate limit answers before the action.
          Application.put_env(:cyfr, :tincture_rate_limit_max, 1)
          Prima.Test.RateLimiter.reset!()
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
      assert log =~ "GET /%5Fs/[REDACTED]/local/page-canvas/#{@version}/app.js"
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
