# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerPairingTest.Host do
  @moduledoc false
  # A page mounted through the context guard, as the shell is, with the
  # layer and nothing else; what the layer tells its parent goes to the
  # test.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket), do: {:ok, assign(socket, :test, session["test"])}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    Phoenix.LiveView.send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    send(socket.assigns.test, {:host, message})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} />
    """
  end
end

defmodule PrismWeb.SystemLayerPairingTest.BareHost do
  @moduledoc false
  # A page holding a context it was handed: a client no session backs.
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, test: session["test"], context: session["context"])}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    Phoenix.LiveView.send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    send(socket.assigns.test, {:host, message})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} />
    """
  end
end

defmodule PrismWeb.SystemLayerPairingTest.Issuer do
  @moduledoc false
  # The re-authentication's stand-in for the identity provider: it answers
  # the URL a person would be sent to, and redeems nothing here.
  def authorize_url(request),
    do:
      {:ok,
       "https://issuer.pairing.example/authorize?state=" <> URI.encode_www_form(request.state)}

  def redeem(_code, _request), do: {:error, :reauth_refused}
end

defmodule PrismWeb.SystemLayerPairingTest do
  @moduledoc """
  The system layer's pairing prompt: the person's paired devices, each
  revocable, and a pairing code for a new one. A pairing begins with the
  code the new device shows, the digest of the key it made first, typed
  into the prompt's form; a malformed code asks nothing. Beginning a
  pairing and revoking a device are sensitive changes, so each waits on
  its record, shown with the home's preview before any proof, the device's
  code in it; the layer holds the request's secret and makes the change
  once the record reads confirmed, wherever it was proven. The code it
  then draws is `pairing.begin`'s `invitation_url`, as a QR code and as
  the link, beside the device's code, and that link's code completes a
  pairing from the glass holding that key. Once the person holds a
  passkey, the pairing's record says it takes a passkey or a paired
  device's proof. A proof is a passkey,
  a code sent to the person's email, or a fresh sign-in at their identity
  provider, which opens in a new tab; a client with no person behind it
  is offered a request for confirmation instead.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias PrismWeb.SystemLayerPairingTest.{BareHost, Host, Issuer}
  alias Sanctum.Context
  alias Sanctum.TestContext.MailSink

  setup %{conn: conn} do
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    ctx =
      Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    %{conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  defp host!(conn, athanor) do
    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"athanor_id" => athanor.id, "test" => self()})

    view
  end

  defp open_pairing!(view, id \\ "pairing-1") do
    send(view.pid, {:prompt, %{id: id, kind: :pairing, action: :device_pairing, subject: %{}}})
    render(view)
    render(view)
  end

  defp open_record!(ctx, operation) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    assert [%{ref: ref, operation: ^operation}] = rows
    ref
  end

  # A new glass's key, made before any invitation: the key pair, its
  # digest and the code the glass shows for it.
  defp device_key! do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    digest = Prima.Device.key_digest(device_key)

    %{
      public: device_key,
      private: private,
      digest: digest,
      code: Prima.Device.key_code(digest)
    }
  end

  # The code typed into the prompt's begin form.
  defp begin!(view, code, id \\ "pairing-1") do
    view |> form("##{id}-pairing-begin", %{"key_code" => code}) |> render_submit()
  end

  # The glass holding `key`, and nothing else, completes the pairing the
  # link names.
  defp complete!(url, key) do
    %URI{fragment: "code=" <> secret} = URI.parse(url)
    {device_key, private} = {key.public, key.private}
    glass = Context.build(%{authenticated: false, client_ip: "198.51.100.71"})

    submission = %{
      "invitation_secret" => secret,
      "device_key" => Encoding.b64(device_key),
      "key_digest" => key.digest
    }

    call = &Sanctum.Gate.call_external("pairing", glass, Map.merge(&1, %{"action" => "complete"}))

    {:ok, %{challenge: challenge}} = call.(submission)
    {:ok, challenge} = Challenge.decode(challenge)
    proof = Proof.encode(Proof.sign(challenge, private))
    {:ok, %{client_id: client_id}} = call.(Map.put(submission, "proof", proof))
    client_id
  end

  # The pairing link the prompt shows beside its QR code.
  defp link(view) do
    html = view |> element(~s([data-test="pairing-link"])) |> render()
    [url] = Regex.run(~r/value="([^"]+)"/, html, capture: :all_but_first)
    String.replace(url, "&amp;", "&")
  end

  describe "pairing a device" do
    test "begins only once its record is confirmed, then draws the link as a QR code that pairs a glass",
         %{conn: conn, athanor: athanor, ctx: ctx} do
      key = device_key!()
      view = host!(conn, athanor)
      html = open_pairing!(view)

      assert html =~ ~s(data-kind="pairing")
      assert has_element?(view, ~s([data-test="pairing-none"]))

      assert has_element?(
               view,
               ~s([data-test="pairing-begin-form"] [data-test="pairing-key-input"])
             )

      # The code as the new device shows it, its groups spaced.
      begin!(view, key.code)

      # Waiting on its record, with the home's preview and this client as
      # the asker; no code is drawn and the prompt reports nothing.
      ref = open_record!(ctx, "pairing.begin")
      html = render(view)
      assert html =~ ~s(data-ref="#{ref}")
      assert html =~ ~s(data-status="waiting")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), "pairing.begin")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), key.code)
      assert has_element?(view, ~s([data-test="confirmation-asker"]), "a browser signed in")

      # The record asks for exactly this key's digest, the spaces gone.
      assert {:ok, %{preview: preview}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), ref)

      assert preview =~ key.code
      refute has_element?(view, ~s([data-test="pairing-qr"]))
      refute html =~ "cnf_"
      refute_received {:host, {:system_layer, "pairing-1", _}}

      # Proven elsewhere, by its ref: the layer begins it, once.
      Sanctum.TestContext.prove!(ctx, ref)
      wait_until(fn -> has_element?(view, ~s([data-test="pairing-qr"])) end, 2_000, "the code")

      url = link(view)
      assert url =~ ~r|\A#{Regex.escape(Sanctum.Person.home())}/pair#code=[A-Za-z0-9_-]{22}\z|

      # The QR code is the link's.
      {:ok, svg} = PrismWeb.QR.svg(url)
      [drawn] = Regex.run(~r/<path d="([^"]+)"/, svg, capture: :all_but_first)
      assert render(view) =~ drawn
      refute render(view) =~ ~s(data-ref="#{ref}")
      assert {:ok, %{state: "consumed"}} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)

      # Beside the link, the code of the one device it pairs; no sentence
      # says whoever opens it pairs.
      assert has_element?(view, ~s([data-test="pairing-key-code"]), key.code)
      refute render(view) =~ "Whoever opens it"

      # The link's code pairs the glass holding that key, as the person.
      client_id = complete!(url, key)

      assert {:ok, %{clients: [%{client_id: ^client_id}]}} =
               PrismWeb.Ops.call_tool(ctx, "pairing/list", %{})

      Cyfr.Test.Sandbox.end_views()
    end

    test "an address too long for a QR code still gives the link", %{
      conn: conn,
      athanor: athanor,
      ctx: ctx
    } do
      # A host of 186 characters: its link is past what version 10 holds.
      host =
        String.duplicate("a", 63) <>
          "." <> String.duplicate("b", 63) <> "." <> String.duplicate("c", 50) <> ".example"

      previous = Application.get_env(:sanctum, :public_url)
      Application.put_env(:sanctum, :public_url, "https://" <> host)
      on_exit(fn -> restore(:sanctum, :public_url, previous) end)

      view = host!(conn, athanor)
      open_pairing!(view)
      begin!(view, device_key!().code)
      Sanctum.TestContext.prove!(ctx, open_record!(ctx, "pairing.begin"))

      wait_until(fn -> has_element?(view, ~s([data-test="pairing-link"])) end, 2_000, "the link")
      url = link(view)
      assert byte_size(url) > PrismWeb.QR.capacity(10)
      assert url == "https://" <> host <> "/pair#code=" <> String.slice(url, -22, 22)
      assert has_element?(view, ~s([data-test="pairing-link-only"]))
      assert has_element?(view, ~s([data-test="pairing-key-code"]))
      refute render(view) =~ "Whoever opens it"
      refute has_element?(view, ~s([data-test="pairing-qr"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "a code sent to the person's email confirms it from the prompt",
         %{conn: conn, athanor: athanor, ctx: ctx} do
      view = host!(conn, athanor)
      open_pairing!(view)
      begin!(view, device_key!().code)
      ref = open_record!(ctx, "pairing.begin")

      # No passkey or device yet: not restricted, and the code is offered.
      refute has_element?(view, ~s([data-test="confirmation-restricted"]))
      view |> element(~s([data-test="confirm-email"])) |> render_click()
      assert_receive {:confirmation_code_mail, mail}, 2_000
      assert has_element?(view, ~s([data-test="confirm-code"]))

      view |> form("#system-layer-code", %{"code" => MailSink.code(mail)}) |> render_submit()

      wait_until(fn -> has_element?(view, ~s([data-test="pairing-qr"])) end, 2_000, "the code")
      assert {:ok, %{state: "consumed"}} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "the code the new device shows" do
    test "a malformed one asks nothing and says what to type", %{
      conn: conn,
      athanor: athanor,
      ctx: ctx
    } do
      key = device_key!()
      view = host!(conn, athanor)
      open_pairing!(view)

      for code <- ["", "not a code", String.slice(key.code, 0, 20), key.code <> " AAAA"] do
        html = begin!(view, code)
        assert html =~ "Type the code the new device shows"
        assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
      end

      refute_received {:host, {:system_layer, "pairing-1", _}}
      assert has_element?(view, ~s([data-test="pairing-begin-form"]))
    end

    test "a valid one asks for exactly its digest, typed with or without its spaces", %{
      conn: conn,
      athanor: athanor,
      ctx: ctx
    } do
      key = device_key!()
      view = host!(conn, athanor)
      open_pairing!(view)

      # Pasted with a line break for one space, its groups run together
      # after the next, and blanks around it.
      typed =
        "  " <>
          (key.code
           |> String.replace(" ", "\n", global: false)
           |> String.replace(" ", "", global: false)) <>
          "  "

      begin!(view, typed)

      ref = open_record!(ctx, "pairing.begin")
      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      assert row.preview =~ key.code

      # Proven elsewhere, the invitation is opened for that digest alone.
      Sanctum.TestContext.prove!(ctx, ref)
      wait_until(fn -> has_element?(view, ~s([data-test="pairing-link"])) end, 2_000, "the link")
      assert has_element?(view, ~s([data-test="pairing-key-code"]), key.code)

      assert {:ok, [%{key_digest: digest}]} =
               Arca.PairingInvitations.list(Context.actor(ctx), user_id: ctx.user_id)

      assert digest == key.digest
      Cyfr.Test.Sandbox.end_views()
    end

    test "once the person holds a passkey, the pairing's record says it takes a passkey or a paired device",
         %{conn: conn, athanor: athanor, ctx: ctx, user: user} do
      Sanctum.TestContext.passkey!(user.user_id)
      view = host!(conn, athanor)
      open_pairing!(view)
      begin!(view, device_key!().code)

      ref = open_record!(ctx, "pairing.begin")
      html = render(view)
      assert html =~ ~s(data-ref="#{ref}")

      assert has_element?(view, ~s([data-test="confirmation-restricted"]), "your passkey")
      assert has_element?(view, ~s([data-test="confirm-passkey"]))
      refute has_element?(view, ~s([data-test="confirm-email"]))
      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "revoking a device" do
    test "waits on its record, then revokes it and lists the devices again",
         %{conn: conn, athanor: athanor, ctx: ctx} do
      # Paired already, from another session of the person, under a
      # confirmation proven outside the page.
      {:ok, session} = Sanctum.TestContext.create_session(%{ctx | provider: "github"})

      {:ok, other} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      key = device_key!()

      {:ok, %{invitation_url: url}} =
        Sanctum.TestContext.confirming(
          other,
          &Sanctum.Gate.call_external("pairing", &1, %{
            "action" => "begin",
            "key_digest" => key.digest
          })
        )

      client_id = complete!(url, key)

      view = host!(conn, athanor)
      open_pairing!(view)

      assert has_element?(view, ~s([data-test="pairing-client"][data-client="#{client_id}"]))
      view |> element(~s([data-test="pairing-revoke"])) |> render_click()

      ref = open_record!(ctx, "pairing.revoke")
      assert render(view) =~ ~s(data-status="waiting")

      assert {:ok, %{clients: [_still]}} = PrismWeb.Ops.call_tool(ctx, "pairing/list", %{})

      Sanctum.TestContext.prove!(ctx, ref)

      wait_until(
        fn -> has_element?(view, ~s([data-test="pairing-none"])) end,
        2_000,
        "the device revoked and listed again"
      )

      assert {:ok, %{clients: []}} = PrismWeb.Ops.call_tool(ctx, "pairing/list", %{})
      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "the person's command lines" do
    test "are listed beside the devices, and revoking one needs no confirmation and ends it", %{
      conn: conn,
      athanor: athanor,
      ctx: ctx
    } do
      {:ok, begun} = Sanctum.CliSignIn.begin("build box", "198.51.100.95")
      secret = secret_of!(begun.approve_url)

      {:ok, session} = Sanctum.TestContext.create_session(%{ctx | provider: "github"})

      {:ok, session_ctx} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      {:ok, _approved} =
        Sanctum.TestContext.confirming(session_ctx, &Sanctum.CliSignIn.approve(&1, secret))

      view = host!(conn, athanor)
      open_pairing!(view)

      assert has_element?(view, ~s([data-test="command-line"]), "Command line on build box")
      assert has_element?(view, ~s([data-test="pairing-none"]))

      view |> element(~s([data-test="command-line-revoke"])) |> render_click()

      assert has_element?(view, ~s([data-test="command-lines-none"]))
      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

      assert {:error, _ended} =
               Sanctum.Caller.establish(begun.session_token, task_supervisor: nil)

      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "a fresh sign-in" do
    setup do
      issuer = "https://issuer.pairing.example"

      previous = {
        Application.get_env(:sanctum, :oidc_issuer),
        Application.get_env(:sanctum, :oidc_reauth_client),
        Application.get_env(:ueberauth, Ueberauth)
      }

      Application.put_env(:sanctum, :oidc_issuer, issuer)
      Application.put_env(:sanctum, :oidc_reauth_client, Issuer)

      Application.put_env(:ueberauth, Ueberauth,
        providers: [
          oidcc:
            {Ueberauth.Strategy.Oidcc,
             issuer: :cyfr_oidc, client_id: "cid", client_secret: "csec"}
        ]
      )

      on_exit(fn ->
        {oidc, client, ueberauth} = previous
        restore(:sanctum, :oidc_issuer, oidc)
        restore(:sanctum, :oidc_reauth_client, client)
        restore(:ueberauth, Ueberauth, ueberauth)
      end)

      %{issuer: issuer}
    end

    test "opens the identity provider in a new tab, so this page stays",
         %{conn: conn, issuer: issuer} do
      user =
        test_user(
          identity:
            Sanctum.Auth.Identity.key(:oidcc, issuer, "sub-#{System.unique_integer([:positive])}")
        )

      conn = log_in_user(conn, user)
      athanor = seated_athanor()

      view = host!(conn, athanor)
      open_pairing!(view)
      begin!(view, device_key!().code)

      view |> element(~s([data-test="confirm-reauth"])) |> render_click()

      assert has_element?(
               view,
               ~s(a[data-test="confirm-reauth-open"][target="_blank"][rel="noopener noreferrer"])
             )

      assert render(view) =~ "https://issuer.pairing.example/authorize?state="
      assert render(view) =~ ~s(data-status="waiting")
    end
  end

  describe "a client with no person behind it" do
    test "is offered a request for confirmation in place of pairing", %{conn: conn} do
      ctx =
        [
          user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          athanor_id: Sanctum.TestContext.athanor_id(),
          permissions: [:*],
          scope: :athanor,
          auth_method: :tincture,
          authenticated: true
        ]
        |> Context.build()
        |> Context.enter_guest()

      {:ok, view, _html} =
        live_isolated(conn, BareHost, session: %{"context" => ctx, "test" => self()})

      send(
        view.pid,
        {:prompt, %{id: "p-none", kind: :pairing, action: :device_pairing, subject: %{}}}
      )

      render(view)
      html = render(view)

      assert html =~ ~s(data-standing="none")
      assert has_element?(view, ~s([data-test="pairing-begin"]), "Request confirmation")
      refute has_element?(view, ~s([data-test="pairing-begin"]), "Pair a device")
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # The approval secret the link carries in its fragment, the link being
  # this home's `/cli` page.
  defp secret_of!(link) do
    prefix = Sanctum.Person.home() <> "/cli#code="
    assert String.starts_with?(link, prefix), "#{link} is not this home's /cli link"
    String.replace_prefix(link, prefix, "")
  end
end
