# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FlashDismissTest do
  @moduledoc """
  A flash is dismissed by naming the message it shows, and the server
  clears it only while that message is still the one shown: a dismissal
  of a message replaced meanwhile, as the old message's fade sends it,
  leaves the newer one standing, and a message cleared shows again when it
  is put again.
  """

  use PrismWeb.ConnCase, async: true

  defmodule FlashView do
    @moduledoc false
    use PrismWeb, :live_view

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket, layout: false}

    @impl true
    def render(assigns), do: ~H"<.flash_group flash={@flash} />"

    @impl true
    def handle_event("put", %{"message" => message}, socket),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :error, message)}
  end

  defp shown(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-error span:first-child")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp dismiss(view, message),
    do:
      render_click(view, "flash:dismiss", %{
        "key" => "error",
        "shown" => PrismWeb.CoreComponents.flash_token(message)
      })

  test "a dismissal names its message: a replaced one leaves the newer standing", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FlashView)

    render_click(view, "put", %{"message" => "A failed"})
    assert shown(view) == ["A failed"]

    render_click(view, "put", %{"message" => "B failed"})
    dismiss(view, "A failed")
    assert shown(view) == ["B failed"]

    dismiss(view, "B failed")
    assert shown(view) == []

    # Cleared on the server, the same message put again shows again.
    render_click(view, "put", %{"message" => "B failed"})
    assert shown(view) == ["B failed"]
  end

  test "the flash's click and fade send the dismissal of the message it shows", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FlashView)
    render_click(view, "put", %{"message" => "A failed"})

    view |> element("#flash-error") |> render_click()
    assert shown(view) == []
  end

  test "a dismissal of an unknown kind or with no message clears nothing", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FlashView)
    render_click(view, "put", %{"message" => "A failed"})

    render_click(view, "flash:dismiss", %{"key" => "nope", "shown" => "x"})
    render_click(view, "flash:dismiss", %{"key" => "error"})
    assert shown(view) == ["A failed"]
  end
end
