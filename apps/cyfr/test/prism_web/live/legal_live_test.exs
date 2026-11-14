# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalLiveTest do
  @moduledoc """
  The legal page shows the policy text the configured registry publishes,
  names it by its address, makes the pages' own links absolute against
  that address, and opens Privacy with this CYFR's own paragraph on who
  can read what.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Test.RegistryStub

  setup %{conn: conn} do
    {:ok, conn: log_in_user(conn, test_user())}
  end

  # A registry serving each legal page with a link that names a path alone,
  # once as Markdown and once as HTML.
  defp registry! do
    RegistryStub.start!(fn %{method: "GET", path: "/v1/legal/" <> name} ->
      {200,
       RegistryStub.answer(%{
         "name" => name,
         "title" => "Page #{name}",
         "content_markdown" =>
           "Report it [here](/legal/ncii/report), <a href=\"/legal/dmca\">or here</a>, " <>
             "or [elsewhere](https://example.com/x)."
       })}
    end)
  end

  # `config/test.exs` configures a registry that is not cyfr.run.
  test "the page names the registry it reads by its address, never cyfr.run", %{conn: conn} do
    host = Sanctum.registry_url()
    {view, _html} = mount_athanor(conn, "/legal")
    html = render(view)
    assert html =~ "Policy text published by #{host}."
    refute html =~ "cyfr.run"
  end

  test "a page's links that name a path alone resolve against the registry's address", %{
    conn: conn
  } do
    registry!()
    base = Sanctum.registry_base_url(Sanctum.registry_url())
    {view, _html} = mount_athanor(conn, "/legal")

    raw =
      view
      |> element("#legal-md-terms")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-raw-content")
      |> hd()

    assert raw ==
             "Report it [here](#{base}/legal/ncii/report), " <>
               "<a href=\"#{base}/legal/dmca\">or here</a>, " <>
               "or [elsewhere](https://example.com/x)."
  end

  test "Privacy opens with who can read what on this CYFR, and no other tab does", %{conn: conn} do
    registry!()
    {view, _html} = mount_athanor(conn, "/legal")
    refute has_element?(view, "#who-reads")

    view |> element(~s(button[phx-value-name="privacy"])) |> render_click()

    assert has_element?(view, "#who-reads", "Whoever runs the machine this CYFR runs on can read")
    assert has_element?(view, "#who-reads", "The people of a thread see its messages")
    assert has_element?(view, "#who-reads", "used for you and never shown to you")
    assert has_element?(view, "#who-reads", "goes to the model provider")
    PrismWeb.Vocabulary.refute_vocabulary(view |> element("#who-reads") |> render())
  end
end
