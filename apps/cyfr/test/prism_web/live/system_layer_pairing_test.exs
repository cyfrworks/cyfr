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
  revocable, and a pairing code for a new one. Beginning a pairing and
  revoking a device are sensitive changes, so each waits on its record,
  shown with the home's preview before any proof; the layer holds the
  request's secret and makes the change once the record reads confirmed,
  wherever it was proven. The code it then draws is `pairing.begin`'s
  `invitation_url`, as a QR code and as the link, and that link's code
  completes a pairing from a glass holding nothing. A proof is a passkey,
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
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
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

  # A glass holding nothing completes the pairing the link names.
  defp complete!(url) do
    %URI{fragment: "code=" <> secret} = URI.parse(url)
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    glass = Context.build(%{authenticated: false, client_ip: "198.51.100.71"})
    submission = %{"invitation_secret" => secret, "device_key" => Encoding.b64(device_key)}
    call = &Grimoire.call_external("pairing", glass, Map.merge(&1, %{"action" => "complete"}))

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
      view = host!(conn, athanor)
      html = open_pairing!(view)

      assert html =~ ~s(data-kind="pairing")
      assert has_element?(view, ~s([data-test="pairing-none"]))

      view |> element(~s([data-test="pairing-begin"])) |> render_click()

      # Waiting on its record, with the home's preview and this client as
      # the asker; no code is drawn and the prompt reports nothing.
      ref = open_record!(ctx, "pairing.begin")
      html = render(view)
      assert html =~ ~s(data-ref="#{ref}")
      assert html =~ ~s(data-status="waiting")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), "pairing.begin")
      assert has_element?(view, ~s([data-test="confirmation-asker"]), "a browser signed in")
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

      # The link's code pairs a glass holding nothing, as the person.
      client_id = complete!(url)

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
      view |> element(~s([data-test="pairing-begin"])) |> render_click()
      Sanctum.TestContext.prove!(ctx, open_record!(ctx, "pairing.begin"))

      wait_until(fn -> has_element?(view, ~s([data-test="pairing-link"])) end, 2_000, "the link")
      url = link(view)
      assert byte_size(url) > PrismWeb.QR.capacity(10)
      assert url == "https://" <> host <> "/pair#code=" <> String.slice(url, -22, 22)
      assert has_element?(view, ~s([data-test="pairing-link-only"]))
      refute has_element?(view, ~s([data-test="pairing-qr"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "a code sent to the person's email confirms it from the prompt",
         %{conn: conn, athanor: athanor, ctx: ctx} do
      view = host!(conn, athanor)
      open_pairing!(view)
      view |> element(~s([data-test="pairing-begin"])) |> render_click()
      ref = open_record!(ctx, "pairing.begin")

      view |> element(~s([data-test="confirm-email"])) |> render_click()
      assert_receive {:confirmation_code_mail, mail}, 2_000
      assert has_element?(view, ~s([data-test="confirm-code"]))

      view |> form("#system-layer-code", %{"code" => MailSink.code(mail)}) |> render_submit()

      wait_until(fn -> has_element?(view, ~s([data-test="pairing-qr"])) end, 2_000, "the code")
      assert {:ok, %{state: "consumed"}} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
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

      {:ok, %{invitation_url: url}} =
        Sanctum.TestContext.confirming(
          other,
          &Grimoire.call_external("pairing", &1, %{"action" => "begin"})
        )

      client_id = complete!(url)

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
      view |> element(~s([data-test="pairing-begin"])) |> render_click()

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
end
