# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponentTest.Host do
  @moduledoc false
  # A page mounted through the context guard, as the shell is, drawing the
  # system layer the sheet is the grant body of.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    Phoenix.LiveView.send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} />
    """
  end
end

defmodule PrismWeb.ConsentSheetComponentTest do
  @moduledoc """
  The consent sheet, the system layer's grant body, walks plan → preview
  through `PrismWeb.Ops.call_tool/3`, whose dialect is `tool/action` — a
  dot-spelled name silently misses the registry and every call fails with
  "Unknown tool" — and the layer commits the walk through the same
  adapter. These tests render the component against the real registry so
  a dialect drift (or a retired verb) fails here instead of in the
  operator's browser, and hold that no page draws it but the layer.
  """

  # The plan walk hits the DB, including from tasks the dispatcher spawns —
  # PrismWeb.ConnCase checks the sandbox out in shared mode.
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Context

  defp oidc_ctx do
    Context.build(
      user_id: "consent_sheet_test_user",
      namespace: "consent_sheet_test_user",
      athanor_id: "ath_test",
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  test "given no walk, the sheet's plan call reaches the profile tool through the registry" do
    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: "publisher/does-not-exist@0.0.1",
        context: oidc_ctx()
      )

    # The plan fails on the nonexistent ref — that's expected. What must
    # never appear is a registry miss: that means the component and the
    # helper disagree on the tool-name dialect again.
    refute html =~ "Unknown tool"
  end

  test "given the prompt's walk, the sheet draws it and reads nothing" do
    walk = %{
      ref: "tincture:local.sheet-probe",
      plan: %{
        plan_token: "not-read",
        expected_consent_revision: 0,
        source_ref: "tincture:local.sheet-probe",
        needs: [
          key_need("api_key", "to reach the service", [own("vlt_1", "Service key")],
            suggested: %{entry_id: "vlt_1"}
          )
        ],
        candidates: [],
        caps: nil
      },
      preview: %{
        v: 1,
        rows: [
          %{
            "kind" => "credential",
            "node" => "tincture:local.sheet-probe",
            "narrowed" => false,
            "values" => %{
              "name" => "Service key",
              "edge" => "@ingress",
              "fields" => ["SERVICE_KEY"],
              "scopes" => [],
              "provider" => "service.example",
              "destination" => %{"hosts" => ["api.service.example"], "scheme" => "https"},
              "source" => "own",
              "disclosed" => false,
              "suggested" => false,
              "choice_required" => false,
              "binding_key" => "tincture:local.sheet-probe|@ingress|default",
              "lifetime" => %{"kind" => "standing", "until" => nil}
            }
          }
        ],
        origins: ["interactive"],
        proof: "p",
        commit_digest: "d"
      },
      decisions: %{
        "ref" => "tincture:local.sheet-probe",
        "bindings" => [%{"need" => "api_key", "entry_id" => "vlt_1"}]
      }
    }

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: walk.ref,
        walk: walk,
        context: oidc_ctx(),
        athanor_name: "Home"
      )

    assert html =~ "to reach the service"

    # The binding in one sentence: who uses it, whose entry, the account,
    # where it may go and that CYFR attaches the value and the component
    # never holds it; then that it stands until revoked.
    assert sentences(html) == [
             "tincture:local.sheet-probe uses Service key, an entry of this athanor, for its " <>
               "own calls: a service.example account, sent only to " <>
               "https://api.service.example. CYFR attaches the value and the component " <>
               "never holds it."
           ]

    assert html =~ "Lifetime: until revoked"
    refute html =~ "Attached by CYFR"
    refute html =~ "Choose which entry to use"
    assert html =~ "tincture:local.sheet-probe · in Home"
    assert html =~ ~r/aria-pressed="true"[^>]*>\s*Service key/

    # One candidate: nothing to change to.
    refute html =~ ~s(data-test="grant-change")

    # How long it lives: until revoked, chosen; no session behind this
    # walk, so no "this session".
    assert pressed(html, ~s([data-lifetime])) == ["standing"]
    refute html =~ ~s(data-lifetime="session")
  end

  # ---------------------------------------------------------------------------
  # Each need's row
  # ---------------------------------------------------------------------------

  defp own(id, name, over \\ %{}) do
    Map.merge(
      %{
        source: "own",
        entry_id: id,
        name: name,
        kind: "api_key",
        provider: "service.example",
        destination: %{"hosts" => ["api.service.example"], "scheme" => "https"},
        disclosed: false
      },
      over
    )
  end

  defp offered(id, name) do
    %{
      source: "instance",
      instance_entry_id: id,
      name: name,
      kind: "api_key",
      provider: "service.example",
      destination: %{"hosts" => ["api.service.example"], "scheme" => "https"},
      disclosed: false
    }
  end

  # A declared API-key need as the plan answers it.
  defp key_need(name, reason, candidates, opts \\ []) do
    %{
      need: name,
      type: "api_key:service.example",
      kind: Keyword.get(opts, :kind, "api_key"),
      provider: Keyword.get(opts, :provider, "service.example"),
      reason: reason,
      fields: ["SERVICE_KEY"],
      scopes: [],
      required: Keyword.get(opts, :required, true),
      disclose_only: Keyword.get(opts, :disclose_only, false),
      disclose: false,
      hosts: Keyword.get(opts, :hosts),
      paths: nil,
      candidates: candidates,
      suggested: Keyword.get(opts, :suggested),
      choice_required: Keyword.get(opts, :choice_required, false),
      source: Keyword.get(opts, :source),
      newer_shipped: Keyword.get(opts, :newer_shipped)
    }
  end

  defp sheet(plan, opts \\ []) do
    ref = plan[:source_ref] || "tincture:local.sheet-needs"

    walk =
      Map.merge(
        %{
          ref: ref,
          plan: Map.merge(%{plan_token: "not-read", expected_consent_revision: 0}, plan),
          preview: Keyword.get(opts, :preview),
          decisions:
            Map.merge(%{"ref" => ref, "bindings" => []}, Keyword.get(opts, :decisions, %{}))
        },
        Map.new(Keyword.take(opts, [:session_expires_at]))
      )

    render_component(PrismWeb.ConsentSheetComponent,
      id: "consent-sheet",
      ref: ref,
      walk: walk,
      context: oidc_ctx(),
      athanor_route: Keyword.get(opts, :athanor_route)
    )
  end

  defp need_html(html, need) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-test="grant-need"][data-need="#{need}"]))
    |> LazyHTML.to_html()
  end

  # The values the pressed controls matching `selector` carry, by their
  # data-lifetime or their entry.
  defp pressed(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector <> ~s([aria-pressed="true"]))
    |> Enum.flat_map(fn element ->
      LazyHTML.attribute(element, "data-lifetime") ++
        LazyHTML.attribute(element, "phx-value-entry_id") ++
        LazyHTML.attribute(element, "phx-value-instance_entry_id") ++
        LazyHTML.attribute(element, "phx-value-label")
    end)
  end

  defp picks(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-test="grant-pick"]))
    |> Enum.flat_map(fn element ->
      LazyHTML.attribute(element, "phx-value-entry_id") ++
        LazyHTML.attribute(element, "phx-value-instance_entry_id") ++
        LazyHTML.attribute(element, "phx-value-label")
    end)
  end

  defp sentences(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".consent-sheet__sentence")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  test "a required need opens on its suggestion, an optional one offers it a click away, " <>
         "and the candidates open unasked only where a choice is required" do
    plan = %{
      source_ref: "tincture:local.sheet-needs",
      candidates: [],
      dependency_needs: [],
      needs: [
        key_need("one", "the one key", [own("vlt_1", "Only key")],
          suggested: %{entry_id: "vlt_1"}
        ),
        key_need(
          "optional",
          "an optional key",
          [own("vlt_a", "A key"), offered("ine_b", "B key")],
          required: false,
          suggested: %{entry_id: "vlt_a"}
        ),
        key_need("pick", "a key to choose", [own("vlt_x", "X key"), own("vlt_y", "Y key")],
          choice_required: true
        ),
        %{
          need: "@ingress",
          reason: "credentials this component may use when invoked",
          required: false,
          hosts: nil,
          paths: nil,
          disclose: false,
          candidates: [own("vlt_d", "Disclosed", %{disclosed: true})],
          suggested: %{entry_id: "vlt_d"},
          choice_required: false,
          source: "own",
          newer_shipped: nil
        }
      ]
    }

    # What the grant opens with binds the required need's suggestion
    # alone: never the optional one, never the undeclared slot.
    assert PrismWeb.ConsentSheetComponent.initial_choices(plan) == %{
             {:need, "one", nil} => %{
               source: "own",
               id: "vlt_1",
               need: nil,
               lifetime: %{"kind" => "standing"},
               choice: "standing",
               renew: false
             }
           }

    html =
      sheet(plan,
        decisions: %{"bindings" => [%{"need" => "one", "entry_id" => "vlt_1"}]}
      )

    # One candidate, suggested and bound: pressed, nothing to change to.
    one = need_html(html, "one")
    assert picks(one) == ["vlt_1"] and pressed(one, ~s([data-test="grant-pick"])) == ["vlt_1"]
    refute one =~ ~s(data-test="grant-change")

    # Optional: the suggestion a click away, unpressed; the other behind
    # "Change".
    optional = need_html(html, "optional")
    assert picks(optional) == ["vlt_a"]
    assert pressed(optional, ~s([data-test="grant-pick"])) == []
    assert optional =~ ~s(data-test="grant-change")

    # A choice required: every candidate, unasked, and no "Change".
    pick = need_html(html, "pick")
    assert picks(pick) == ["vlt_x", "vlt_y"]
    refute pick =~ ~s(data-test="grant-change")

    # The undeclared slot: offered, unbound.
    slot = need_html(html, "@ingress")
    assert picks(slot) == ["vlt_d"] and pressed(slot, ~s([data-test="grant-pick"])) == []

    refute html =~ "This app asks for no credentials"
  end

  test "a dependency's need: its suggestion, a profile that lends, or the publisher's " <>
         "configuration, which takes no choice" do
    plan = %{
      source_ref: "tincture:local.sheet-app",
      candidates: [],
      needs: [],
      dependency_needs: [
        %{
          from: "tincture:local.sheet-app",
          dep: "catalyst:local.sheet-db",
          needs: [
            key_need("db", "to reach the database", [own("vlt_db", "DB key")],
              suggested: %{entry_id: "vlt_db"}
            )
          ],
          candidates: [
            %{
              profile_id: "prof_1",
              label: "work",
              source: "own",
              entry_id: "vlt_w",
              entry_name: "Work key",
              fields: ["SERVICE_KEY"],
              scopes: []
            }
          ]
        },
        %{
          from: "tincture:local.sheet-app",
          dep: "catalyst:local.sheet-maps",
          needs: [
            key_need("tiles", "to draw the map", [],
              source: "provided",
              provider: "maps.example"
            )
            |> Map.put(:destination, %{"hosts" => ["tiles.maps.example"], "scheme" => "https"})
          ],
          candidates: []
        }
      ]
    }

    choices = PrismWeb.ConsentSheetComponent.initial_choices(plan)
    assert Map.keys(choices) == [{:dep, "tincture:local.sheet-app", "catalyst:local.sheet-db"}]

    decisions =
      PrismWeb.ConsentSheetComponent.decisions(
        "tincture:local.sheet-app",
        nil,
        ["interactive"],
        %{},
        choices
      )

    assert decisions["selections"] == [
             %{
               "dep" => "catalyst:local.sheet-db",
               "from" => "tincture:local.sheet-app",
               "entry_id" => "vlt_db",
               "lifetime" => %{"kind" => "standing"}
             }
           ]

    html = sheet(plan, decisions: Map.take(decisions, ["selections"]))

    db = need_html(html, "db")
    assert pressed(db, ~s([data-test="grant-pick"])) == ["vlt_db"]
    # The lending profile is one of the choices behind "Change".
    assert db =~ ~s(data-test="grant-change")

    tiles = need_html(html, "tiles")
    assert tiles =~ ~s(data-test="grant-provided")
    assert tiles =~ "Provided by local, the app&#39;s public configuration"
    assert tiles =~ "https://tiles.maps.example"
    assert picks(tiles) == []
    refute tiles =~ ~s(data-test="grant-change")
    refute html =~ "This app asks for no credentials"
  end

  test "a need nothing can meet: an API key is connected, another kind is added in the " <>
         "vault, and a need the component reads itself says why and offers its update" do
    plan = %{
      source_ref: "catalyst:local.sheet-model",
      dependency_needs: [],
      # The athanor's own entries: one of the model's provider, attach-only.
      candidates: [
        %{
          id: "vlt_attach",
          name: "Attach-only key",
          kind: "api_key",
          provider_hint: "model.example",
          attach_only: true
        }
      ],
      needs: [
        key_need("key", "to call the service", [], provider: "keyed.example"),
        key_need("mail", "to read mail", [], kind: "oauth", provider: "google"),
        key_need("model", "to call the model", [],
          provider: "model.example",
          disclose_only: true,
          newer_shipped: "1.4.0"
        )
      ]
    }

    html = sheet(plan, athanor_route: "home")

    key = need_html(html, "key")
    assert key =~ "Connect your keyed.example account"
    refute key =~ ~s(data-test="grant-why")

    mail = need_html(html, "mail")
    refute mail =~ ~s(data-test="grant-connect")
    assert mail =~ ~s(href="/a/home/vault")

    model = need_html(html, "model")
    assert model =~ ~s(data-test="grant-why")
    assert model =~ "reads the value itself"
    assert model =~ "attach-only"
    assert model =~ "Connect your model.example account"

    [update] =
      model
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(a[data-test="grant-update"]))
      |> Enum.to_list()

    assert LazyHTML.text(update) =~ "Update catalyst:local.sheet-model to 1.4.0"

    assert LazyHTML.attribute(update, "href") == [
             "/a/home/components?" <>
               URI.encode_query(%{"ref" => "catalyst:local.sheet-model", "setup" => "true"})
           ]
  end

  test "\"This app asks for no credentials\" only when neither the app nor a dependency " <>
         "declares one, the undeclared slot still listed" do
    undeclared = %{
      need: "@ingress",
      reason: "credentials this component may use when invoked",
      required: false,
      hosts: nil,
      paths: nil,
      disclose: false,
      candidates: [],
      suggested: nil,
      choice_required: false,
      source: nil,
      newer_shipped: nil
    }

    html = sheet(%{candidates: [], dependency_needs: [], needs: [undeclared]})
    assert html =~ "This app asks for no credentials."
    assert need_html(html, "@ingress") =~ "credentials this component may use when invoked"

    with_dep =
      sheet(%{
        candidates: [],
        needs: [undeclared],
        dependency_needs: [
          %{
            from: "tincture:local.sheet-needs",
            dep: "catalyst:local.sheet-db",
            needs: [key_need("db", "to reach the database", [])],
            candidates: []
          }
        ]
      })

    refute with_dep =~ "This app asks for no credentials"
  end

  # ---------------------------------------------------------------------------
  # Each binding's lifetime, and the GET and HEAD narrowing
  # ---------------------------------------------------------------------------

  defp keyed_preview(rows),
    do: %{v: 1, rows: rows, origins: ["interactive"], proof: "p", commit_digest: "d"}

  defp credential_row(ref, lifetime) do
    %{
      "kind" => "credential",
      "node" => ref,
      "narrowed" => false,
      "values" => %{
        "name" => "Service key",
        "edge" => "@ingress",
        "fields" => ["SERVICE_KEY"],
        "scopes" => [],
        "provider" => "service.example",
        "destination" => %{"hosts" => ["api.service.example"], "scheme" => "https"},
        "source" => "own",
        "disclosed" => false,
        "suggested" => true,
        "choice_required" => false,
        "binding_key" => "#{ref}|@ingress|default",
        "lifetime" => lifetime
      }
    }
  end

  test "each binding offers five lifetimes, until revoked chosen and never once; this " <>
         "session names when it ends; a once the head used can be granted again" do
    ref = "tincture:local.sheet-life"
    now = DateTime.utc_now()
    session_end = now |> DateTime.add(3 * 3600) |> DateTime.truncate(:second)

    plan = %{
      source_ref: ref,
      candidates: [],
      dependency_needs: [],
      needs: [
        key_need("api_key", "to reach the service", [own("vlt_1", "Service key")],
          suggested: %{entry_id: "vlt_1"}
        )
      ],
      head_bindings: [
        %{
          binding_key: "#{ref}|@ingress|default",
          lifetime: %{kind: "once", until: nil},
          consumed: true
        }
      ]
    }

    html =
      sheet(plan,
        preview: keyed_preview([credential_row(ref, %{"kind" => "standing", "until" => nil})]),
        decisions: %{"bindings" => [%{"need" => "api_key", "entry_id" => "vlt_1"}]},
        session_expires_at: DateTime.to_iso8601(session_end)
      )

    doc = LazyHTML.from_fragment(html)

    offered =
      doc
      |> LazyHTML.query(~s([data-test="grant-lifetime"] [data-lifetime]))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-lifetime"))

    assert offered == ["standing", "5m", "1h", "session", "once"]
    assert pressed(html, ~s([data-lifetime])) == ["standing"]

    [session] = doc |> LazyHTML.query(~s([data-lifetime="session"])) |> Enum.to_list()
    words = session |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    assert words ==
             "This session, until #{Calendar.strftime(session_end, "%H:%M UTC")}" <>
               if(Date.diff(DateTime.to_date(session_end), DateTime.to_date(now)) == 1,
                 do: " tomorrow",
                 else: ""
               )

    refute String.downcase(html) =~ "sign out"
    refute String.downcase(html) =~ "signing out"

    # The head's once binding of this key was used: it can be granted
    # again, which no binding is unasked.
    assert html =~ ~s(data-test="grant-renew")
    assert pressed(html, ~s([data-test="grant-renew"])) == []

    # A session more than a day off is held to 24 hours on.
    far = now |> DateTime.add(30 * 86_400) |> DateTime.to_iso8601()

    html =
      sheet(plan,
        preview: keyed_preview([credential_row(ref, %{"kind" => "standing", "until" => nil})]),
        decisions: %{"bindings" => [%{"need" => "api_key", "entry_id" => "vlt_1"}]},
        session_expires_at: far
      )

    [session] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-lifetime="session"]))
      |> Enum.to_list()

    assert LazyHTML.text(session) =~ "tomorrow"
  end

  # ---------------------------------------------------------------------------
  # A re-grant
  # ---------------------------------------------------------------------------

  @regrant "tincture:local.sheet-regrant"

  # An app with one required need its suggestion meets, whose head binds
  # another of its candidates with `lifetime`.
  defp regrant_plan(lifetime, over \\ %{}) do
    Map.merge(
      %{
        source_ref: @regrant,
        candidates: [],
        dependency_needs: [],
        needs: [
          key_need(
            "api_key",
            "to reach the service",
            [own("vlt_s", "Suggested key"), own("vlt_h", "Held key")],
            suggested: %{entry_id: "vlt_s"}
          )
        ],
        head_bindings: [
          %{
            binding_key: "#{@regrant}|@ingress|default",
            entry_id: "vlt_h",
            lifetime: lifetime,
            consumed: lifetime.kind == "once"
          }
        ]
      },
      over
    )
  end

  # The grant as the layer opens it: the choices the plan opens with, as
  # decisions, previewed as one credential row of that lifetime.
  defp regrant_sheet(plan) do
    choices = PrismWeb.ConsentSheetComponent.initial_choices(plan)

    decisions =
      PrismWeb.ConsentSheetComponent.decisions(@regrant, nil, ["interactive"], %{}, choices)

    rows =
      for %{"lifetime" => lifetime} <- decisions["bindings"],
          do: put_in(credential_row(@regrant, lifetime), ["values", "name"], "Held key")

    html =
      sheet(plan,
        preview: if(rows != [], do: keyed_preview(rows)),
        decisions: Map.take(decisions, ["bindings"])
      )

    {choices, decisions, html}
  end

  defp lifetimes_offered(html, at) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-test="#{at}"] [data-lifetime]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-lifetime"))
  end

  test "a re-grant opens on the entry its head binds, not the suggestion: a once stays once, " <>
         "and a used one is offered to be granted once again" do
    {choices, decisions, html} = regrant_sheet(regrant_plan(%{kind: "once", until: nil}))

    assert choices == %{
             {:need, "api_key", nil} => %{
               source: "own",
               id: "vlt_h",
               need: nil,
               lifetime: %{"kind" => "once"},
               choice: "once",
               renew: false
             }
           }

    assert decisions["bindings"] == [
             %{"need" => "api_key", "entry_id" => "vlt_h", "lifetime" => %{"kind" => "once"}}
           ]

    assert pressed(need_html(html, "api_key"), ~s([data-test="grant-pick"])) == ["vlt_h"]
    assert pressed(html, ~s([data-test="grant-lifetime"] [data-lifetime])) == ["once"]
    assert html =~ ~s(data-test="grant-renew")
    assert pressed(html, ~s([data-test="grant-renew"])) == []
  end

  test "a re-grant whose until is still ahead reopens pressed on its own time, beside the " <>
         "five, and sends that same until" do
    now = DateTime.utc_now()
    at = now |> DateTime.add(2 * 3600) |> DateTime.truncate(:second)
    until = DateTime.to_iso8601(at)

    {choices, decisions, html} = regrant_sheet(regrant_plan(%{kind: "until", until: until}))

    assert %{{:need, "api_key", nil} => %{id: "vlt_h", lifetime: lifetime, choice: nil}} =
             choices

    assert lifetime == %{"kind" => "until", "until" => until}

    assert decisions["bindings"] == [
             %{"need" => "api_key", "entry_id" => "vlt_h", "lifetime" => lifetime}
           ]

    assert lifetimes_offered(html, "grant-lifetime") == ["kept", "standing", "5m", "1h", "once"]
    assert pressed(html, ~s([data-test="grant-lifetime"] [data-lifetime])) == ["kept"]

    [kept] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-lifetime="kept"]))
      |> Enum.to_list()

    day =
      if Date.diff(DateTime.to_date(at), DateTime.to_date(now)) == 1, do: " tomorrow", else: ""

    assert kept |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim() ==
             "Until #{Calendar.strftime(at, "%H:%M UTC")}#{day}, as granted"
  end

  test "a re-grant whose until has passed opens with no lifetime pressed, says why, and " <>
         "sends no binding for it until one is chosen" do
    passed = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    plan = regrant_plan(%{kind: "until", until: DateTime.to_iso8601(passed)})

    {choices, decisions, html} = regrant_sheet(plan)

    assert choices == %{
             {:need, "api_key", nil} => %{
               source: "own",
               id: "vlt_h",
               need: nil,
               lifetime: nil,
               choice: nil,
               renew: false
             }
           }

    # Neither the head's entry nor the suggestion is bound.
    assert decisions["bindings"] == []

    need = need_html(html, "api_key")
    assert pressed(need, ~s([data-test="grant-pick"])) == ["vlt_h"]
    assert need =~ ~s(data-test="grant-lifetime-pending")
    assert need =~ "The time this was granted until has passed"

    assert lifetimes_offered(need, "grant-lifetime-pending") == [
             "standing",
             "5m",
             "1h",
             "once"
           ]

    assert pressed(need, ~s([data-lifetime])) == []
    refute html =~ ~s(data-test="grant-lifetime")
  end

  test "a head binding whose need cannot be told is left unbound, with no suggestion in its " <>
         "place; a dependency's edge reopens on the profile that lent it" do
    app_needs = [
      key_need("api_key", "to reach the service", [own("vlt_s", "Suggested key")],
        suggested: %{entry_id: "vlt_s"}
      ),
      key_need("other", "another key", [own("vlt_o", "Other key")], required: false)
    ]

    plan =
      regrant_plan(%{kind: "standing", until: nil}, %{
        needs: app_needs,
        head_bindings: [
          %{
            binding_key: "#{@regrant}|@ingress|default",
            entry_id: "vlt_gone",
            lifetime: %{kind: "standing", until: nil},
            consumed: false
          }
        ]
      })

    assert PrismWeb.ConsentSheetComponent.initial_choices(plan) == %{}

    dep = "catalyst:local.sheet-regrant-db"

    lender = %{
      profile_id: "prof_1",
      label: "work",
      source: "own",
      entry_id: "vlt_w",
      entry_name: "Work key",
      fields: ["SERVICE_KEY"],
      scopes: []
    }

    row = fn needs ->
      %{from: @regrant, dep: dep, needs: needs, candidates: [lender]}
    end

    edge_head = fn binds ->
      Map.merge(
        %{
          binding_key: "#{@regrant}|#{dep}|default",
          lifetime: %{kind: "standing", until: nil},
          consumed: false
        },
        binds
      )
    end

    db =
      key_need("db", "to reach the database", [own("vlt_db", "DB key")],
        suggested: %{entry_id: "vlt_db"}
      )

    # A dependency declaring several needs, on an edge naming none.
    several = %{
      source_ref: @regrant,
      candidates: [],
      needs: [],
      dependency_needs: [row.([db, key_need("write", "to write", [own("vlt_x", "X key")])])],
      head_bindings: [edge_head.(%{entry_id: "vlt_gone"})]
    }

    assert PrismWeb.ConsentSheetComponent.initial_choices(several) == %{}

    lent = %{
      several
      | dependency_needs: [row.([db])],
        head_bindings: [edge_head.(%{label: "work"})]
    }

    choices = PrismWeb.ConsentSheetComponent.initial_choices(lent)

    assert PrismWeb.ConsentSheetComponent.decisions(@regrant, nil, ["interactive"], %{}, choices)[
             "selections"
           ] == [
             %{
               "dep" => dep,
               "from" => @regrant,
               "label" => "work",
               "lifetime" => %{"kind" => "standing"}
             }
           ]
  end

  test "a named head binding reopens as its own row, its name fixed and its entry pressed, on " <>
         "the app's own calls and on a dependency's edge; one whose until has passed is no " <>
         "decision until its lifetime is chosen" do
    dep = "catalyst:local.sheet-named-db"
    now = DateTime.utc_now()
    ahead = now |> DateTime.add(2 * 3600) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    passed = now |> DateTime.add(-3600) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    head = fn key, id, lifetime, consumed ->
      %{binding_key: key, entry_id: id, lifetime: lifetime, consumed: consumed}
    end

    plan = %{
      source_ref: @regrant,
      candidates: [],
      needs: [
        key_need(
          "api_key",
          "to reach the service",
          [own("vlt_h", "Held key"), own("vlt_w", "Work key")],
          suggested: %{entry_id: "vlt_h"}
        )
      ],
      dependency_needs: [
        %{
          from: @regrant,
          dep: dep,
          candidates: [],
          needs: [
            key_need(
              "db",
              "to reach the database",
              [own("vlt_db", "DB key"), own("vlt_dw", "DW key")],
              suggested: %{entry_id: "vlt_db"}
            )
          ]
        }
      ],
      head_bindings: [
        head.("#{@regrant}|@ingress|default", "vlt_h", %{kind: "standing", until: nil}, false),
        head.("#{@regrant}|@ingress|name:Work", "vlt_w", %{kind: "once", until: nil}, true),
        head.("#{@regrant}|#{dep}|default", "vlt_db", %{kind: "standing", until: nil}, false),
        head.("#{@regrant}|#{dep}|name:Later", "vlt_dw", %{kind: "until", until: ahead}, false),
        head.("#{@regrant}|#{dep}|name:Gone", "vlt_dw", %{kind: "until", until: passed}, false)
      ]
    }

    choices = PrismWeb.ConsentSheetComponent.initial_choices(plan)

    decisions =
      PrismWeb.ConsentSheetComponent.decisions(@regrant, nil, ["interactive"], %{}, choices)

    assert decisions["bindings"] == [
             %{"need" => "api_key", "entry_id" => "vlt_h", "lifetime" => %{"kind" => "standing"}},
             %{
               "need" => "api_key",
               "entry_id" => "vlt_w",
               "name" => "Work",
               "lifetime" => %{"kind" => "once"}
             }
           ]

    # Gone's time has passed: it is no decision until a lifetime is chosen.
    assert decisions["selections"] == [
             %{
               "dep" => dep,
               "from" => @regrant,
               "entry_id" => "vlt_db",
               "lifetime" => %{"kind" => "standing"}
             },
             %{
               "dep" => dep,
               "from" => @regrant,
               "entry_id" => "vlt_dw",
               "name" => "Later",
               "lifetime" => %{"kind" => "until", "until" => ahead}
             }
           ]

    html = sheet(plan, decisions: Map.take(decisions, ["bindings", "selections"]))

    row = fn edge, name ->
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        ~s([data-test="grant-account"][data-edge="#{edge}"][data-account="#{name}"])
      )
      |> LazyHTML.to_html()
    end

    work = row.("@ingress", "Work")
    assert work =~ ~s(data-test="grant-account-name")
    refute work =~ ~s(name="name")
    assert pressed(work, ~s([data-test="grant-account-pick"])) == ["vlt_w"]
    assert pressed(work, ~s([data-lifetime])) == ["once"]
    assert work =~ ~s(data-test="grant-renew")

    later = row.(dep, "Later")
    assert pressed(later, ~s([data-test="grant-account-pick"])) == ["vlt_dw"]
    assert pressed(later, ~s([data-lifetime])) == ["kept"]

    gone = row.(dep, "Gone")
    assert pressed(gone, ~s([data-test="grant-account-pick"])) == ["vlt_dw"]
    assert pressed(gone, ~s([data-lifetime])) == []
    assert gone =~ "The time this was granted until has passed"

    # Each edge whose default is an entry offers another account.
    adds =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test="grant-add-account"]))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-edge"))

    assert Enum.sort(adds) == Enum.sort(["@ingress", dep])
  end

  test "a catalyst asking for other methods offers GET and HEAD only, named by its methods; " <>
         "no control reads \"read only\"" do
    ask = fn node, methods ->
      %{
        "kind" => "egress",
        "node" => node,
        "narrowed" => false,
        "values" => %{
          "domains" => ["api.example.com"],
          "methods" => methods,
          "schemes" => ["https"],
          "private_ips" => []
        }
      }
    end

    rows = [
      ask.("catalyst:local.sheet-mail", ["GET", "HEAD", "POST"]),
      ask.("catalyst:local.sheet-feed", ["GET"]),
      ask.("reagent:local.sheet-parse", ["GET", "PUT"])
    ]

    html =
      sheet(
        %{
          source_ref: "tincture:local.sheet-net",
          candidates: [],
          needs: [],
          dependency_needs: [],
          rows: rows
        },
        preview: %{v: 1, rows: rows, origins: ["interactive"], proof: "p", commit_digest: "d"}
      )

    narrowings =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test="grant-get-head-only"]))
      |> Enum.map(&{LazyHTML.attribute(&1, "phx-value-node"), String.trim(LazyHTML.text(&1))})

    assert narrowings == [{["catalyst:local.sheet-mail"], "GET and HEAD only"}]
    refute String.downcase(html) =~ "read only"
    refute String.downcase(html) =~ "read-only"
  end

  test "a plan whose closure is unresolved names what is missing, and draws no rows" do
    walk = %{
      ref: "tincture:local.sheet-orphan",
      plan: %{
        plan_token: "not-read",
        expected_consent_revision: 0,
        needs: [],
        candidates: [],
        rows: [%{"kind" => "limits", "node" => "tincture:local.sheet-orphan"}],
        unresolved: %{reason: "unresolvable_dependency", missing: "reagent:local.absent"}
      },
      preview: nil,
      decisions: %{"ref" => "tincture:local.sheet-orphan", "bindings" => []}
    }

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: walk.ref,
        walk: walk,
        context: oidc_ctx()
      )

    assert html =~ ~s(data-test="grant-unresolved")
    assert html =~ "reagent:local.absent is missing"
    refute html =~ ~s(data-test="grant-rows")
    refute html =~ ~s(data-test="grant-origins")
  end

  test "what changed is worded against the person's grant, never as the component widening" do
    walk = %{
      ref: "tincture:local.sheet-delta",
      plan: %{
        plan_token: "not-read",
        expected_consent_revision: 1,
        needs: [],
        candidates: [],
        rows: [],
        shape_diff: [
          %{
            capability: "egress.domains",
            change: :changed,
            added: ["b.example"],
            removed: ["old.example"]
          }
        ]
      },
      preview: %{v: 1, rows: [], origins: ["interactive"], proof: "p", commit_digest: "d"},
      decisions: %{"ref" => "tincture:local.sheet-delta", "bindings" => []}
    }

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: walk.ref,
        walk: walk,
        context: oidc_ctx()
      )

    assert html =~ "asks for b.example, which your grant does not give"
    assert html =~ "no longer asks for old.example"
    refute html =~ "now wants"
  end

  test "every verb of the walk is a registered profile action" do
    {:ok, tool} = Grimoire.get_tool("profile")

    enum = get_in(tool, ["inputSchema", "properties", "action", "enum"]) || []

    # The sheet plans and previews; the layer commits what it holds.
    for action <- ~w(plan preview commit) do
      assert action in enum,
             "a grant drives profile.#{action}, which the profile tool no longer registers"
    end

    layer = File.read!(Path.expand("../../../lib/prism_web/live/system_layer.ex", __DIR__))
    assert layer =~ ~s("profile/commit")
  end

  describe "a whole-number limit" do
    # A component that asks for a memory bound: the limit the person lowers.
    @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
            <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
            <<0x03, 0x02, 0x01, 0x00>> <>
            <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
            <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

    @ask 8_388_608

    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      {:ok, view, _html} = live_isolated(conn, PrismWeb.ConsentSheetComponentTest.Host)
      local = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
      name = "sheet-cap-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Compendium.Registry.publish_bytes(local, @wasm, %{
          name: name,
          version: "0.1.0",
          type: "catalyst",
          description: "A component that asks for a memory bound",
          manifest: Jason.encode!(%{"caps" => %{"limits" => %{"max_memory_bytes" => @ask}}})
        })

      context = :sys.get_state(view.pid).socket.assigns.context
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(context, "g-cap", "catalyst:local.#{name}")
      send(view.pid, {:prompt, grant})
      render(view)
      render(view)

      %{view: view, node: "catalyst:local.#{name}"}
    end

    defp lower(view, value) do
      view
      |> form(~s(form[phx-submit="set_limits"]), %{"limits" => %{"max_memory_bytes" => value}})
      |> render_submit()

      render(view)
    end

    defp decisions(view) do
      {by_cid, _ids, _next} = :sys.get_state(view.pid).components

      Enum.find_value(by_cid, fn {_cid, entry} ->
        if elem(entry, 0) == PrismWeb.SystemLayer,
          do: elem(entry, 2).current.subject.decisions
      end)
    end

    test "is capped at the ask: above it is refused and sends nothing", %{view: view} do
      assert has_element?(view, ~s([data-row="limits"]), "at most #{@ask}")

      for above <- ["#{@ask + 1}", "#{@ask * 2}"] do
        lower(view, above)

        assert has_element?(
                 view,
                 ~s([data-row="limits"] [data-test="grant-refusal"]),
                 "can be at most #{@ask}"
               )

        refute Map.has_key?(decisions(view), "subset")
      end
    end

    test "below the ask is sent exactly; at the ask nothing is sent", %{view: view, node: node} do
      lower(view, "4194304")
      refute has_element?(view, ~s([data-test="grant-refusal"]))

      assert decisions(view)["subset"] == %{
               node => %{"limits" => %{"max_memory_bytes" => 4_194_304}}
             }

      # Back at the ask, the limit names nothing: the same decision as one
      # that never lowered it.
      lower(view, "#{@ask}")
      refute Map.has_key?(decisions(view), "subset")
    end

    test "a value that is no whole number is refused", %{view: view} do
      for value <- ["1.5", "lots", "-1"] do
        lower(view, value)
        assert has_element?(view, ~s([data-row="limits"] [data-test="grant-refusal"]))
        refute Map.has_key?(decisions(view), "subset")
      end
    end
  end

  test "no page draws the sheet but the system layer" do
    live = Path.expand("../../../lib/prism_web/live", __DIR__)

    drawn =
      for path <- Path.wildcard(Path.join(live, "**/*.ex")),
          File.read!(path) =~
            ~r/module=\{(PrismWeb\.)?ConsentSheetComponent\}|ConsentSheetComponent\./,
          do: Path.relative_to(path, live)

    assert drawn == ["system_layer.ex"]
  end
end
