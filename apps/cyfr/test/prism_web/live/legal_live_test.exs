# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalLiveTest do
  @moduledoc """
  The legal page shows the policy text the configured registry publishes,
  names it by its address, renders each page as fetched into an element
  that names that address as the base of the page's own links, and opens
  Privacy with this CYFR's own paragraph on who can read what.
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

  # `config/test.exs` configures a registry that is not cyfr.run. The
  # address is the one the page's answer names.
  test "the page names the registry it read by its address, never cyfr.run", %{conn: conn} do
    registry!()
    host = Sanctum.registry_url()
    {view, _html} = mount_athanor(conn, "/legal")
    assert has_element?(view, "#legal-md-terms")
    html = render(view)
    assert html =~ "Policy text published by #{host}."
    refute html =~ "cyfr.run"
  end

  test "before a page has loaded, the page names no address", %{conn: conn} do
    html = conn |> get(athanor_path("/legal")) |> html_response(200)
    assert html =~ "Policy text published by the registry."
  end

  test "a page renders as fetched, its element naming the registry's address as its links' base",
       %{conn: conn} do
    registry!()
    base = Sanctum.registry_base_url(Sanctum.registry_url())
    {view, _html} = mount_athanor(conn, "/legal")
    element = view |> element("#legal-md-terms") |> render() |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(element, "data-raw-content") == [
             "Report it [here](/legal/ncii/report), <a href=\"/legal/dmca\">or here</a>, " <>
               "or [elsewhere](https://example.com/x)."
           ]

    assert LazyHTML.attribute(element, "data-link-base") == [base]
  end

  test "Privacy opens with who can read what on this CYFR, and no other tab does", %{conn: conn} do
    registry!()
    {view, _html} = mount_athanor(conn, "/legal")
    refute has_element?(view, "#who-reads")

    view |> element(~s(button[phx-value-name="privacy"])) |> render_click()

    paragraph =
      view
      |> element("#who-reads p")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

    assert paragraph ==
             "Whoever runs the machine this CYFR runs on can read what it keeps there: your " <>
               "files, your vault's values and your messages among them. The people of a " <>
               "thread see its messages, and leaving a thread does not take yours out of it. " <>
               "A key someone shares with you is used for you and never shown to you. Your " <>
               "questions and the context AQUA uses to answer them, including other people's " <>
               "words it reads in shared threads, go to the model provider whose key AQUA " <>
               "uses. The policy below is #{Sanctum.registry_url()}'s, for your account and " <>
               "the components you publish there."

    PrismWeb.Vocabulary.refute_vocabulary(view |> element("#who-reads") |> render())
  end
end
