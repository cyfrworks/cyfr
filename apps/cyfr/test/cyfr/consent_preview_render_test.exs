# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ConsentPreviewRenderTest.Host do
  @moduledoc false
  # A page holding the system layer, mounted through the context guard as
  # the shell is, that shows the prompt it is sent.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    PrismWeb.SystemLayer.show(prompt)
    {:noreply, socket}
  end

  def handle_info(_report, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} />
    """
  end
end

defmodule Cyfr.ConsentPreviewRenderTest do
  @moduledoc """
  No renderer hides a row kind. One preview holding a row of every kind —
  a tincture's frame, streams, cards and system actions included, one
  vault entry lent on two edges and one stream under two subjects among
  them (`tests/fixtures/consent_preview.json`) — is rendered by Prism's
  consent sheet and by the system layer's grant prompt, and every row's
  every value is found in each output, in the row drawn for it. The
  admitted origins are the preview's top-level list, not a row, and
  `Prima.ConsentPreview.kinds/0` omits them, so each output is held to
  them explicitly. The command line's rendering is held to the same
  vectors by `apps/codex/cmd/profile_test.go`.
  """

  use PrismWeb.ConnCase, async: false

  alias Prima.ConsentPreview
  alias Sanctum.Context

  @vectors Path.expand("../../../../tests/fixtures/consent_preview.json", __DIR__)
  @ref "tincture:local.dashboard"

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  # The preview as `profile.preview` answers it: the document beside the
  # proof a commit presents.
  defp preview do
    document = vectors()["preview"]
    {:ok, _decoded} = ConsentPreview.decode(document)

    %{
      v: document["v"],
      rows: document["rows"],
      origins: document["origins"],
      commit_digest: document["commit_digest"],
      proof: "not-a-proof"
    }
  end

  defp walk(preview) do
    %{
      ref: @ref,
      plan: %{plan_token: "not-read", expected_consent_revision: 0, needs: [], candidates: []},
      preview: preview,
      decisions: %{"ref" => @ref, "bindings" => [], "origins" => preview.origins}
    }
  end

  # Each row is drawn as one element naming its kind and node, in the
  # preview's order: the n-th element of a kind is the n-th row of it.
  defp assert_every_row(html, preview) do
    doc = LazyHTML.from_fragment(html)

    for kind <- ConsentPreview.kinds() |> Enum.map(&Atom.to_string/1) do
      rows = Enum.filter(preview.rows, &(&1["kind"] == kind))

      drawn =
        doc |> LazyHTML.query(~s([data-test="grant-rows"] [data-row="#{kind}"])) |> Enum.to_list()

      assert rows != [], "the vectors hold no #{kind} row"

      assert length(drawn) == length(rows),
             "#{kind}: #{length(rows)} rows, #{length(drawn)} drawn"

      for {row, element} <- Enum.zip(rows, drawn) do
        assert LazyHTML.attribute(element, "data-node") == [row["node"]]
        text = element |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

        # The person sees which component of the closure the row is for.
        assert text =~ row["node"], "#{kind} row does not name its node #{row["node"]}: #{text}"

        for {field, value} <- row["values"], want <- expected(row, field, value) do
          assert text =~ want,
                 "#{kind} row of #{row["node"]}: #{field} #{inspect(want)} not in #{text}"
        end

        if row["narrowed"], do: assert(text =~ "narrowed by you")
      end
    end

    # The admitted origins, which are no row: each named, by its spelling.
    admits = doc |> LazyHTML.query(~s([data-test="grant-admits"])) |> LazyHTML.text()

    for origin <- preview.origins do
      assert admits =~ "(#{origin})", "origin #{origin} not in #{admits}"

      if origin != "interactive" do
        assert doc
               |> LazyHTML.query(~s(input[data-origin="#{origin}"][checked]))
               |> Enum.count() == 1
      end
    end

    for origin <- Prima.Origin.spellings() -- preview.origins do
      refute admits =~ "(#{origin})"
    end
  end

  # How a value reads in a row: as the row holds it, or in the renderer's
  # words where it names a relation rather than a resource.
  defp expected(row, "edge", "@ingress"), do: ["#{row["node"]}'s own calls"]

  defp expected(_row, "edge", edge) do
    case String.split(edge, "|", parts: 2) do
      [dep, need] -> ["to #{dep} for its #{need} need"]
      [dep] -> ["to #{dep}"]
    end
  end

  defp expected(_row, "subject", "*"), do: ["any subject"]
  defp expected(_row, "tools", ["*"]), do: ["Every tool of the catalog (*)"]
  defp expected(_row, "background", true), do: ["Keeps running in the background"]
  defp expected(_row, "background", false), do: ["Stops when hidden"]
  defp expected(_row, "args", args), do: [Jason.encode!(args)]

  defp expected(_row, "rate_limit", %{"requests" => requests, "window" => window}),
    do: ["#{requests} per #{window}"]

  # A credential binding's values, in the renderer's words: whose entry,
  # where it goes, whether the component holds it, how long it stands.
  defp expected(_row, "destination", destination) do
    port = if destination["port"], do: ["port #{destination["port"]}"], else: []

    ["#{destination["scheme"]}://"] ++
      destination["hosts"] ++
      Map.get(destination, "methods", []) ++ Map.get(destination, "paths", []) ++ port
  end

  defp expected(_row, "lifetime", %{"kind" => "standing"}), do: ["until revoked"]
  defp expected(_row, "lifetime", %{"kind" => "until", "until" => until}), do: ["until #{until}"]
  defp expected(_row, "lifetime", %{"kind" => "once"}), do: ["one run"]
  defp expected(_row, "source", source), do: ["Source: #{source}"]
  defp expected(_row, "disclosed", true), do: ["the component reads the value itself"]
  defp expected(_row, "disclosed", false), do: ["the component never holds the value"]
  defp expected(_row, "suggested", true), do: ["Suggested"]
  defp expected(_row, "choice_required", true), do: ["Choose which entry to use"]
  defp expected(_row, field, false) when field in ["suggested", "choice_required"], do: []
  defp expected(_row, "connection", connection), do: ["as the account '#{connection}'"]
  defp expected(_row, "binding_key", key), do: ["Binding: #{key}"]

  defp expected(_row, _field, values) when is_list(values), do: values
  defp expected(_row, _field, value), do: [to_string(value)]

  test "the vectors' preview holds a row of every kind" do
    kinds = preview().rows |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()
    assert kinds == ConsentPreview.kinds() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  test "Prism's consent sheet draws every row of every kind, each value, and the origins" do
    ctx =
      Context.build(
        user_id: "render_test_user",
        namespace: "render_test_user",
        athanor_id: "ath_test",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    preview = preview()

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "render",
        ref: @ref,
        walk: walk(preview),
        context: ctx
      )

    assert_every_row(html, preview)
  end

  test "the system layer's grant prompt draws the same rows", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    {:ok, view, _html} =
      live_isolated(conn, Cyfr.ConsentPreviewRenderTest.Host,
        session: %{"athanor_id" => athanor.id}
      )

    preview = preview()

    prompt = %{
      id: "render-grant",
      kind: :grant,
      action: :grant,
      subject: Map.put(walk(preview), :athanor_id, athanor.id)
    }

    send(view.pid, {:prompt, prompt})
    render(view)
    html = render(view)

    assert html =~ ~s(data-prompt-id="render-grant")
    dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("#system-layer-dialog")
    assert Enum.count(dialog) == 1
    assert_every_row(LazyHTML.to_html(dialog), preview)
  end
end
