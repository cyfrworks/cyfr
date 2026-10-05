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
  them explicitly, as it is to the head's bindings the preview removes,
  each a line of its own. The command line's rendering is held to the
  same vectors by `apps/codex/cmd/profile_test.go`.
  """

  use PrismWeb.ConnCase, async: false

  alias Prima.ConsentPreview
  alias Sanctum.Context

  @vectors Path.expand("../../../../tests/fixtures/consent_preview.json", __DIR__)
  @ref "tincture:local.dashboard"

  # The vectors' four credentials, each as its row's sentence.
  @sentences [
    "reagent:local.weather uses weather-api, an entry of this athanor, for its own calls: " <>
      "a weather.example account, sent only to https://api.weather.example. " <>
      "CYFR attaches the value and the component never holds it.",
    "reagent:local.maps will use maps, an entry of this athanor, through its 'shared-maps' " <>
      "profile, from reagent:local.weather for its tiles need: sent only to " <>
      "https://tiles.maps.example, methods GET, paths /v1/tiles. " <>
      "The component reads the value itself.",
    "reagent:local.geo uses weather-api, provided by this instance, from reagent:local.weather, " <>
      "as the account 'Geo account': a weather.example account, sent only to " <>
      "https://*.weather.example port 8443, methods GET, POST, paths /v2. " <>
      "CYFR attaches the value and the component never holds it.",
    "reagent:local.maps uses maps public key, provided by local, the app's public " <>
      "configuration, from reagent:local.weather for its geocode need: sent only to " <>
      "https://geo.maps.example, paths /geocode. The component reads the value itself."
  ]

  # The vectors' removals, each as its line: the need it was bound for (or
  # that it cannot be told, and on a dependency's edge, which), its
  # account or the default, and its entry by name, else id or lender.
  @removals [
    "Removes api_key default: weather-old",
    "Removes api_key account 'Work': weather-work",
    "Removes a binding of reagent:local.geo from reagent:local.weather account 'Old geo': " <>
      "ine_old_geo",
    "Removes a binding of reagent:local.maps from reagent:local.weather default: " <>
      "the key its 'old-maps' profile lent"
  ]

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
      removed: document["removed"],
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

    # The head's bindings the grant removes, which are no row: each a line
    # of its own, keyed by its binding, in the preview's order.
    removals =
      doc
      |> LazyHTML.query(~s([data-test="grant-removed"] [data-binding]))
      |> Enum.map(fn element ->
        {LazyHTML.attribute(element, "data-binding"),
         element |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()}
      end)

    assert removals ==
             Enum.zip(Enum.map(preview.removed, &[&1["binding_key"]]), @removals)

    # Each credential reads as one sentence, the whole of it in its row.
    sentences =
      doc
      |> LazyHTML.query(~s([data-row="credential"] .consent-sheet__sentence))
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

    for sentence <- @sentences, do: assert(sentence in sentences, "missing: #{sentence}")

    # An attach-only credential's sentence says CYFR attaches the value and
    # the component never holds it; a disclosed one's never says so.
    attached = "CYFR attaches the value and the component never holds it."
    credentials = Enum.filter(preview.rows, &(&1["kind"] == "credential"))

    for {row, sentence} <- Enum.zip(credentials, sentences) do
      if row["values"]["disclosed"] == true,
        do: refute(sentence =~ attached, "a disclosed row says #{attached}: #{sentence}"),
        else: assert(sentence =~ attached, "an attach-only row does not say it: #{sentence}")
    end

    assert Enum.any?(credentials, &(&1["values"]["disclosed"] != true))

    # No control claims more than its methods, and no row says the
    # component never holds a value without saying CYFR attaches it.
    text = html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.downcase()

    for claim <- ["read only", "read-only", "attached by cyfr"] do
      refute text =~ claim, "the rendering says #{claim}"
    end

    refute text =~ "the component never holds the value"
  end

  # How a value reads in a row: as the row holds it, or in the renderer's
  # words where it names a relation rather than a resource. A credential
  # is one sentence naming the app or the dependency that uses it.
  defp expected(row, "edge", "@ingress"), do: ["#{row["node"]} uses", "for its own calls"]

  defp expected(row, "edge", edge) do
    case String.split(edge, "|", parts: 2) do
      [dep, need] -> ["#{dep} ", "from #{row["node"]} for its #{need} need"]
      [dep] -> ["#{dep} ", "from #{row["node"]}"]
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
  defp expected(_row, "source", "own"), do: ["an entry of this athanor"]
  defp expected(_row, "source", "instance"), do: ["provided by this instance"]

  defp expected(row, "source", "provided") do
    {:ok, %{namespace: publisher}} = Prima.ComponentRef.parse(row["node"])
    ["provided by #{publisher}, the app's public configuration"]
  end

  defp expected(_row, "label", label), do: ["through its '#{label}' profile"]
  defp expected(_row, "provider", provider), do: ["a #{provider} account"]
  defp expected(_row, "disclosed", true), do: ["The component reads the value itself."]

  defp expected(_row, "disclosed", false),
    do: ["CYFR attaches the value and the component never holds it."]

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
