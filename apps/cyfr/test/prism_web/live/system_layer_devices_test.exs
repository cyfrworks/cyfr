# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerDevicesTest.Host do
  @moduledoc false
  # A page mounted through the context guard, holding the layer as the
  # shell does, and showing the prompts it is sent.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket), do: {:ok, assign(socket, test: session["test"])}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    PrismWeb.SystemLayer.show("system-layer", prompt)
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    send(socket.assigns.test, {:host, message})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} listen />
    """
  end
end

defmodule PrismWeb.SystemLayerDevicesTest do
  @moduledoc """
  The person's Devices, in the system layer's pairing prompt: a device
  removed from this CYFR there stays listed as removed with **Allow
  again** beside it, each change confirmed by a passkey of the person's
  account, and the device is out of this CYFR until it is allowed again.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias PrismWeb.SystemLayerDevicesTest.Host
  alias Sanctum.TestContext.Authenticator

  setup do
    Sanctum.Test.Newcomers.directory!()
    :ok
  end

  # A passkey's proof given from this client, as the account pages return
  # it to this browser's session.
  defp prove_here!(view, ref, authenticator) do
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()
    assert_push_event(view, "system_layer:hop", %{layer: "system-layer", url: url})
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, request} = fragment |> Prima.SignIn.parse_fragment() |> elem(1) |> Prima.SignIn.decode()
    ctx = :sys.get_state(view.pid).socket.assigns.context
    account = Sanctum.TestContext.account!(ctx.user_id)
    answer = Authenticator.answer(authenticator, request, account.identifier)

    assert {:ok, %{purpose: :confirm, ref: ^ref}} =
             Sanctum.SignIn.answer(answer, {:session, ctx.session_token_hash})
  end

  # A device of the person's account paired here, as its hello writes it.
  defp device!(athanor_id, user_id) do
    key = :crypto.strong_rand_bytes(32)
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("pcl")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.PairedClient, [
        %{
          id: id,
          athanor_id: athanor_id,
          user_id: user_id,
          source_kind: "device_cert",
          source_id: id,
          device_public_key: key,
          holder_kind: "chip",
          display_name: "Kitchen box",
          standing: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  defp standing(id), do: Arca.Repo.get!(Arca.Schemas.PairedClient, id).standing

  defp pending(user_id, operation) do
    Arca.Repo.all(
      from(c in "pending_confirmations",
        where: c.user_id == ^user_id and c.operation == ^operation and c.state == "pending",
        select: %{ref: c.ref, action: c.action}
      )
    )
  end

  defp control(client_id),
    do: ~s([data-test="pairing-client"][data-client="#{client_id}"] button)

  defp devices!(%{conn: conn}) do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    authenticator = Sanctum.TestContext.passkey!(user.user_id)
    client_id = device!(athanor.id, user.user_id)

    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"athanor_id" => athanor.id, "test" => self()})

    send(
      view.pid,
      {:prompt, %{id: "pairing-1", kind: :pairing, action: :pairing_revocation, subject: %{}}}
    )

    wait_until(
      fn -> has_element?(view, ~s([data-test="pairing-client"][data-client="#{client_id}"])) end,
      2_000,
      "the Devices list"
    )

    %{view: view, user: user, authenticator: authenticator, client_id: client_id}
  end

  describe "a device removed from this CYFR" do
    setup :devices!

    test "stays listed as removed with Allow again, and allowing it again lets it back in",
         %{view: view, user: user, authenticator: authenticator, client_id: client_id} do
      assert has_element?(view, control(client_id), "Remove from this CYFR")

      view |> element(control(client_id), "Remove from this CYFR") |> render_click()

      assert [%{ref: ref, action: "pairing_revocation"}] = pending(user.user_id, "pairing.remove")
      prove_here!(view, ref, authenticator)

      wait_until(
        fn -> has_element?(view, control(client_id), "Allow again") end,
        2_000,
        "the removed device's Allow again"
      )

      assert standing(client_id) == "removed"
      refute has_element?(view, control(client_id), "Remove from this CYFR")

      assert has_element?(
               view,
               ~s([data-client="#{client_id}"] [data-test="pairing-scope"]),
               "its key cannot connect here until you allow it again"
             )

      view |> element(control(client_id), "Allow again") |> render_click()

      assert [%{ref: again, action: "pairing_readmission"}] =
               pending(user.user_id, "pairing.allow_again")

      # Nothing moves before the person's key confirms it.
      assert standing(client_id) == "removed"
      prove_here!(view, again, authenticator)

      wait_until(
        fn ->
          not has_element?(view, ~s([data-test="pairing-client"][data-client="#{client_id}"]))
        end,
        2_000,
        "the device allowed again"
      )

      # Revoked, so its next hello pairs it anew as a new client.
      assert standing(client_id) == "revoked"
      Cyfr.Test.Sandbox.end_views()
    end

    test "a removal the person dismisses changes nothing",
         %{view: view, user: user, client_id: client_id} do
      view |> element(control(client_id), "Remove from this CYFR") |> render_click()
      assert [%{ref: _ref}] = pending(user.user_id, "pairing.remove")
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()
      assert standing(client_id) == "active"
      Cyfr.Test.Sandbox.end_views()
    end
  end
end
