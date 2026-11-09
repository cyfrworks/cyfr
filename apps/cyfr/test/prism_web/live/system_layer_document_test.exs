# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerDocumentTest do
  @moduledoc """
  Two layers in one document: the desktop's (`listen: :own`) beside the
  page's, which draws the person's confirmations. The desktop's layer opens
  no prompt for a record its own changes did not ask for, and a listening
  layer told that another layer of the document holds a record withdraws
  the prompt it opened for it, cancelling nothing, and opens none for it
  again.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias PrismWeb.SystemLayer
  alias Sanctum.Context

  setup %{conn: conn} do
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

    {:ok, conn: conn, ctx: ctx}
  end

  # Another session of the person asks for a change that waits on a fresh
  # confirmation; it alone holds the secret.
  defp asked_elsewhere!(ctx) do
    {:ok, session} = Sanctum.TestContext.create_session(%{ctx | provider: "github"})
    {:ok, other} = Sanctum.Caller.establish(session.token, focus: ctx.athanor_id, refresh: false)

    assert {:error, {:confirmation_required, %{id: id}}} =
             PrismWeb.Ops.call_tool(other, "vault/create", %{
               "name" => "asked-elsewhere-#{System.unique_integer([:positive])}",
               "kind" => "api_key",
               "fields" => %{"KEY" => "sk-elsewhere"},
               "destination" => %{"hosts" => ["api.example.com"]}
             })

    Prima.Confirmation.ref(id)
  end

  defp open_prompt(view, layer) do
    case Regex.run(~r/data-prompt-id="([^"]+)"/, view |> element("#" <> layer) |> render()) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp pending?(ctx, ref) do
    {:ok, %{confirmations: entries}} =
      PrismWeb.Ops.call_tool(ctx, "confirmation/pending", %{})

    Enum.any?(entries, &(&1.ref == ref))
  end

  test "the desktop page's layer draws another client's request, and the desktop's own layer does not",
       %{conn: conn, ctx: ctx} do
    {desktop, _html} = mount_desktop(conn)
    {:ok, page, _html} = live(conn, "/")
    ref = asked_elsewhere!(ctx)
    prompt_id = SystemLayer.Prompt.confirmation_id(ref)

    wait_until(
      fn -> open_prompt(page, SystemLayer.layer_id()) == prompt_id end,
      2_000,
      "the page's layer drawing the record"
    )

    refute open_prompt(desktop, SystemLayer.desktop_layer_id())
    assert render(desktop) =~ ~s(id="#{SystemLayer.desktop_layer_id()}")
    Cyfr.Test.Sandbox.end_views()
  end

  test "a record another layer of the document holds is left to it, withdrawn here and cancelling nothing",
       %{conn: conn, ctx: ctx} do
    {:ok, page, _html} = live(conn, "/")
    ref = asked_elsewhere!(ctx)
    prompt_id = SystemLayer.Prompt.confirmation_id(ref)
    layer = "#" <> SystemLayer.layer_id()

    wait_until(fn -> open_prompt(page, SystemLayer.layer_id()) == prompt_id end, 2_000, "drawn")

    # The browser hands the record to the layer's own component, as its
    # hook pushes to it (`pushEventTo` on the layer's element).
    page |> with_target(layer) |> render_hook("held_elsewhere", %{"ref" => ref})
    refute open_prompt(page, SystemLayer.layer_id())
    assert pending?(ctx, ref), "the record still waits for its proof"

    # A page that mounts after the record was handed over is handed it
    # again by the browser, and leaves it too.
    {:ok, again, _html} = live(conn, "/")
    again |> with_target(layer) |> render_hook("held_elsewhere", %{"ref" => ref})
    refute open_prompt(again, SystemLayer.layer_id())
    Cyfr.Test.Sandbox.end_views()
  end
end
