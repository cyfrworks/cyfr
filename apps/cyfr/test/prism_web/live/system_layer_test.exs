# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerTest.Relay do
  @moduledoc false
  # The layer as the shell mounts it, and a host that forwards what the
  # layer tells its parent to the test process.
  use Phoenix.Component

  def layer(assigns) do
    ~H"""
    <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} />
    """
  end

  def forward({:prompt, prompt}, socket) do
    Phoenix.LiveView.send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)
    {:noreply, socket}
  end

  def forward(message, socket) do
    send(socket.assigns.test, {:host, message})
    {:noreply, socket}
  end
end

defmodule PrismWeb.SystemLayerTest.Host do
  @moduledoc false
  # A page mounted through the context guard, as the shell is.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket), do: {:ok, assign(socket, :test, session["test"])}

  @impl true
  def handle_info(message, socket), do: PrismWeb.SystemLayerTest.Relay.forward(message, socket)

  @impl true
  def render(assigns), do: PrismWeb.SystemLayerTest.Relay.layer(assigns)
end

defmodule PrismWeb.SystemLayerTest.MovingHost do
  @moduledoc false
  # A page that opens another athanor, as the chat page's rail does: its
  # context moves to the athanor `{:focus, athanor_id}` names, and the
  # layer it renders is handed the moved context.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket), do: {:ok, assign(socket, :test, session["test"])}

  @impl true
  def handle_info({:focus, athanor_id}, socket) do
    {:ok, moved} = Sanctum.Context.focus(socket.assigns.context, athanor_id)
    {:noreply, assign(socket, :context, moved)}
  end

  def handle_info(message, socket), do: PrismWeb.SystemLayerTest.Relay.forward(message, socket)

  @impl true
  def render(assigns), do: PrismWeb.SystemLayerTest.Relay.layer(assigns)
end

defmodule PrismWeb.SystemLayerTest.BareHost do
  @moduledoc false
  # A page holding a context it was handed: a client no session backs.
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, test: session["test"], context: session["context"])}

  @impl true
  def handle_info(message, socket), do: PrismWeb.SystemLayerTest.Relay.forward(message, socket)

  @impl true
  def render(assigns), do: PrismWeb.SystemLayerTest.Relay.layer(assigns)
end

defmodule PrismWeb.SystemLayerTest.QuietHost do
  @moduledoc false
  # A nested view's own layer beside a page's, as the person's panel
  # mounts it: an id of its own, and no stream.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket), do: {:ok, assign(socket, :test, session["test"])}

  @impl true
  def handle_info({:prompt, prompt}, socket) do
    PrismWeb.SystemLayer.show("system-layer-panel", prompt)
    {:noreply, socket}
  end

  def handle_info(message, socket), do: PrismWeb.SystemLayerTest.Relay.forward(message, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PrismWeb.SystemLayer}
      id="system-layer-panel"
      context={@context}
      listen={false}
    />
    """
  end
end

defmodule PrismWeb.SystemLayerTest do
  @moduledoc """
  The system layer presents a prompt and never decides it: it shows no
  confirm control to a client with no person behind it, dispatches the
  same operations the consent sheet and the vault page dispatch through
  the gate, so the operation decides every confirmation that arrives,
  reports each outcome to its parent, a refusal as its sentence, queues
  a second prompt behind the open one, keeps a typed credential out of
  the page, the socket and the logs, and offers safe mode's ways out with
  no dismissal.

  A change that needs a fresh confirmation waits on its record: the
  asking layer keeps the signal's secret in its process and never
  renders it, shows the home's preview and the client that asked, takes
  a passkey's proof by the record's ref, and repeats the change once the
  record reads confirmed on `confirmation.changes`. Another client of the
  person, listening on the same stream, shows the same record before any
  proof and confirms it by its ref.

  Each test mounts the layer the way the shell does, in a small host view
  that forwards what the layer tells its parent to the test.
  """

  use PrismWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias PrismWeb.SystemLayer.Prompt
  alias PrismWeb.SystemLayerTest.{BareHost, Host, MovingHost, QuietHost}
  alias Sanctum.Context
  alias Sanctum.TestContext.Authenticator

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp signed_in(%{conn: conn}) do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"athanor_id" => athanor.id, "test" => self()})

    ctx =
      Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    %{view: view, ctx: ctx, user: user}
  end

  # A platform administrator's page, the layer the Settings page mounts.
  defp signed_in_admin(%{conn: conn}) do
    user = test_user()
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(user.user_id)
    %{view: view, ctx: ctx} = signed_in(%{conn: conn}, user)
    %{view: view, ctx: %{ctx | platform_admin: true}, user: user}
  end

  defp signed_in(%{conn: conn}, user) do
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"athanor_id" => athanor.id, "test" => self()})

    %{view: view, ctx: person_context(user, athanor)}
  end

  # A tincture's context entered onto the guest plane: a client with no
  # person behind it who can give a proof.
  defp none_client(%{conn: conn}) do
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

    refute Sanctum.Pairing.can_confirm?(ctx)

    {:ok, view, _html} =
      live_isolated(conn, BareHost, session: %{"context" => ctx, "test" => self()})

    %{view: view, ctx: ctx}
  end

  # The host answers `{:prompt, _}` with `send_update/3`, which the view
  # takes as a message of its own: the first render is behind the prompt,
  # the second behind the update.
  defp prompt(view, prompt) do
    send(view.pid, {:prompt, prompt})
    render(view)
    render(view)
  end

  defp layer(view), do: with_target(view, "#system-layer")

  # The secret the layer holds for the change it asked for: in its process
  # alone, read here from the view's state.
  defp held_secret(view) do
    state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    [secret] = Regex.run(~r/cnf_[A-Za-z0-9_-]{43}/, state)
    secret
  end

  # A passkey's proof given on this client: the ceremony the layer asks
  # for, answered by the person's authenticator over the record's digest.
  defp prove_here!(view, ref, authenticator) do
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()

    # The ceremony names the layer that asks for it: every hook on a page
    # hears every push.
    assert_push_event(view, "webauthn:get", %{
      layer: "system-layer",
      purpose: "confirmation",
      id: ^ref,
      public_key: %{"challenge" => challenge}
    })

    {:ok, digest} = Prima.Identity.Encoding.unb64(challenge, 32)
    credential = Authenticator.assertion(authenticator, digest)

    view
    |> layer()
    |> render_hook("webauthn_result", %{
      "purpose" => "confirmation",
      "id" => ref,
      "credential" => credential
    })
  end

  # Another session of the same person, in the same athanor.
  defp other_session!(ctx) do
    {:ok, session} = Sanctum.TestContext.create_session(%{ctx | provider: "github"})

    {:ok, other} =
      Sanctum.Caller.establish(session.token, focus: ctx.athanor_id, task_supervisor: nil)

    other
  end

  # What the request log and the decision log hold.
  defp logged do
    inspect(
      {Arca.Repo.all(from(l in Arca.Schemas.McpLog, select: {l.input, l.output, l.error})),
       Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, select: {d.reason, d.tool, d.action}))},
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  defp end_views, do: Cyfr.Test.Sandbox.end_views()

  defp person_context(user, athanor) do
    Context.build(
      user_id: user.user_id,
      athanor_id: athanor.id,
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # A grant planned in the athanor of `ctx`, the host's context.
  defp grant(ctx, id, attrs \\ %{}) do
    ref = "tincture:local.system-layer-probe"

    Map.merge(
      %{
        id: id,
        kind: :grant,
        action: :grant,
        subject: %{
          ref: ref,
          athanor_id: ctx.athanor_id,
          plan: %{plan_token: "not-a-plan-token", expected_consent_revision: 0},
          preview: typed_preview(ref),
          decisions: %{"ref" => ref, "bindings" => []}
        }
      },
      attrs
    )
  end

  # A preview as `profile.preview` answers one: the typed rows, the
  # origins and the digest, beside the proof. It carries no sentence.
  defp typed_preview(ref, rows \\ nil) do
    %{
      v: Prima.ConsentPreview.version(),
      rows:
        rows ||
          [
            %{
              "kind" => "egress",
              "node" => ref,
              "narrowed" => false,
              "values" => %{
                "domains" => ["api.example.com"],
                "methods" => ["GET"],
                "schemes" => ["https"],
                "private_ips" => []
              }
            },
            %{
              "kind" => "storage",
              "node" => ref,
              "narrowed" => false,
              "values" => %{"paths" => ["data/probe/"], "actions" => ["read"]}
            }
          ],
      origins: ["interactive"],
      proof: "not-a-proof",
      commit_digest: "sha256:" <> String.duplicate("0", 64)
    }
  end

  defp sign_in(id), do: %{id: id, kind: :sign_in, action: nil, subject: %{}}

  defp credential(id, name),
    do: %{id: id, kind: :credential_entry, action: :credential_entry, subject: %{name: name}}

  # A grant's confirm is answered in a later message (the layer asks its
  # sheet for the walk, then commits), so an outcome is waited for.
  defp outcome(id) do
    assert_receive {:host, {:system_layer, ^id, outcome}}, 2_000
    outcome
  end

  defp no_outcome(id), do: refute_received({:host, {:system_layer, ^id, _outcome}})

  defp open_prompt(view) do
    html = render(view)

    case Regex.run(~r/data-prompt-id="([^"]+)"/, html) do
      [_, id] -> id
      nil -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Presentation
  # ---------------------------------------------------------------------------

  describe "presentation" do
    setup :signed_in

    test "a prompt is a labelled, described modal dialog with real buttons", %{
      view: view,
      ctx: ctx
    } do
      html = prompt(view, grant(ctx, "g1"))

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="system-layer-title")
      assert html =~ ~s(aria-describedby="system-layer-description")
      assert html =~ ~s(id="system-layer-title")
      assert html =~ ~s(id="system-layer-description")
      assert html =~ ~s(data-open="true")
      assert html =~ ~s(data-dismissable="true")
      assert html =~ "api.example.com"
      assert html =~ "data/probe/"

      # A person's session can confirm: it is told nothing about standing,
      # and no client is shown a rank.
      refute html =~ ~s(data-standing="none")
      refute html =~ ~s(data-needs=)

      assert has_element?(view, ~s(button[type="button"][phx-click="confirm"]), "Grant")
      assert has_element?(view, ~s(button[type="button"][phx-click="dismiss"]), "Dismiss")
      assert html =~ "focus-visible:ring-2"
    end

    test "with no prompt nothing is drawn", %{view: view} do
      html = render(view)
      assert html =~ ~s(data-open="false")
      refute html =~ ~s(id="system-layer-title")
    end

    test "an unlock has nothing to confirm and can be dismissed", %{view: view} do
      html = prompt(view, %{id: "u1", kind: :unlock, action: :vault_unlock, subject: %{}})

      assert html =~ "Nothing on this server unlocks the vault"
      refute has_element?(view, ~s([phx-click="confirm"]))

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("u1") == :dismissed
    end
  end

  # ---------------------------------------------------------------------------
  # Standing
  # ---------------------------------------------------------------------------

  describe "a person's session" do
    setup :signed_in

    test "is offered the control for every action of the table; no action names a rank", %{
      view: view,
      ctx: ctx
    } do
      for action <- Sanctum.Pairing.actions() do
        id = "act-#{action}"
        html = prompt(view, grant(ctx, id, %{action: action}))

        assert has_element?(view, ~s(button[phx-click="confirm"]), "Grant"), inspect(action)
        refute html =~ ~s(data-standing="none")

        view |> element(~s(button[phx-click="dismiss"])) |> render_click()
        assert outcome(id) == :dismissed
      end
    end

    test "a confirmation is decided by the operation it dispatches, not by the layer", %{
      view: view,
      ctx: ctx
    } do
      # A sensitive action: the layer dispatches it like any other, and
      # the commit, not the layer, refuses the stale plan token.
      prompt(view, grant(ctx, "sensitive", %{action: :home_transfer}))

      view |> element(~s(button[phx-click="confirm"])) |> render_click()

      assert {:refused, reason} = outcome("sensitive")
      html = render(view)
      sentence = reason |> PrismWeb.Ops.error_message() |> Phoenix.HTML.html_escape()
      assert html =~ Phoenix.HTML.safe_to_string(sentence)
      assert open_prompt(view) == "sensitive"
    end
  end

  describe "a client with no person behind it" do
    setup :none_client

    test "is shown no confirm control and told where to confirm", %{view: view, ctx: ctx} do
      html = prompt(view, grant(ctx, "n1"))

      refute has_element?(view, ~s([phx-click="confirm"]))
      assert html =~ ~s(data-standing="none")
      assert html =~ "Confirm it from a"
      assert html =~ "signed-in browser."
    end

    test "a confirmation sent anyway is dispatched, and the operation refuses it", %{
      view: view,
      ctx: ctx
    } do
      prompt(view, grant(ctx, "n2"))

      view |> layer() |> render_click("confirm", %{"id" => "n2"})

      assert {:refused, reason} = outcome("n2")
      html = render(view)
      sentence = reason |> PrismWeb.Ops.error_message() |> Phoenix.HTML.html_escape()
      assert html =~ Phoenix.HTML.safe_to_string(sentence)
      assert open_prompt(view) == "n2"
    end

    test "is offered a request for confirmation in place of saving, and the vault refuses it", %{
      view: view,
      ctx: ctx
    } do
      name = "none-client-entry-#{System.unique_integer([:positive])}"
      prompt(view, credential("n3", name))

      assert has_element?(view, ~s([data-test="credential-submit"]), "Request confirmation")
      refute has_element?(view, ~s([data-test="credential-submit"]), "Save to vault")

      view
      |> layer()
      |> render_submit("enter_credential", %{
        "prompt_id" => "n3",
        "secret" => "sk-none",
        "destination_hosts" => "api.example.com"
      })

      assert {:refused, _reason} = outcome("n3")
      refute render(view) =~ "sk-none"

      # Nothing reached the vault under the person the context names.
      person = %{ctx | plane: :external, auth_method: :oidc}
      {:ok, entries} = Sanctum.Vault.list(person)
      refute Enum.any?(entries, &(&1.name == name))
    end
  end

  describe "the confirmation signal" do
    test "a confirmation the operation answers with it reads as its sentence, never naming its secret" do
      # What a refused dispatch shows (`PrismWeb.Ops.error_message/1`): the
      # signal is neither a denial nor an unknown term, and names the
      # change the person confirms in Prism; its id is the asking
      # request's secret, which no page shows.
      signal =
        {:confirmation_required,
         %{
           id: "confirmation-7f3a",
           operation: "vault.create",
           expires_at: ~U[2026-09-30 12:05:00Z]
         }}

      sentence = PrismWeb.Ops.error_message(signal)
      refute sentence =~ "confirmation-7f3a"
      assert sentence =~ "vault.create"
      assert sentence == Prima.ConsentSignal.message(signal)
    end
  end

  # ---------------------------------------------------------------------------
  # Confirmations
  # ---------------------------------------------------------------------------

  describe "a confirmation the operation refuses" do
    setup :signed_in

    test "shows the refusal's sentence, reports it, and stays dismissable", %{
      view: view,
      ctx: ctx
    } do
      prompt(view, grant(ctx, "g-refused"))

      view |> element(~s(button[phx-click="confirm"])) |> render_click()

      assert {:refused, reason} = outcome("g-refused")
      html = render(view)
      assert html =~ ~s(role="alert")
      sentence = reason |> PrismWeb.Ops.error_message() |> Phoenix.HTML.html_escape()
      assert html =~ Phoenix.HTML.safe_to_string(sentence)
      assert open_prompt(view) == "g-refused"

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("g-refused") == :dismissed
    end
  end

  # ---------------------------------------------------------------------------
  # Grants
  # ---------------------------------------------------------------------------

  # Minimal valid WASM with a `run` export: enough to publish a row.
  @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
          <<0x03, 0x02, 0x01, 0x00>> <>
          <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
          <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  # A component in the person's athanor whose one credential need no
  # grant has bound yet, and a vault entry that can meet it.
  defp needing_key(%{ctx: ctx}) do
    local = %{Sanctum.TestContext.local() | user_id: ctx.user_id, athanor_id: ctx.athanor_id}
    name = "layer-needs-key-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Compendium.Registry.publish_bytes(local, @wasm, %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A component that needs a key",
        manifest:
          Jason.encode!(%{
            "needs" => %{
              "api_key" => %{
                "type" => "api_key:layer.test",
                "reason" => "to call the service with your key",
                "fields" => ["LAYER_API_KEY"],
                "required" => true
              }
            }
          })
      })

    # The provider the need names; the component reads its key itself, so
    # the entry is disclosed.
    params = %{
      name: "layer key #{System.unique_integer([:positive])}",
      kind: "api_key",
      provider_hint: "layer.test",
      fields: %{"LAYER_API_KEY" => "sk-layer-not-shown"},
      destination: %{"hosts" => ["api.example.com"]},
      disclose: true
    }

    entering =
      Sanctum.TestContext.confirmed(local, :credential_entry, %{
        operation: "vault.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.Vault.create(entering, params)

    %{
      local: local,
      name_ref: "catalyst:local.#{name}",
      ref: "catalyst:local.#{name}:0.1.0",
      entry: entry
    }
  end

  # A component in the person's athanor asking for egress, storage, every
  # tool and a timeout: what the person narrows.
  defp asking_more(%{ctx: ctx}) do
    local = %{Sanctum.TestContext.local() | user_id: ctx.user_id, athanor_id: ctx.athanor_id}
    name = "layer-asks-#{System.unique_integer([:positive])}"
    publish_asking!(local, name, "0.1.0", ["a.layer.example", "b.layer.example"])

    %{local: local, name: name, name_ref: "catalyst:local.#{name}", ref: "catalyst:local.#{name}"}
  end

  defp publish_asking!(local, name, version, domains) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(local, @wasm, %{
        name: name,
        version: version,
        type: "catalyst",
        description: "A component that asks for more",
        manifest:
          Jason.encode!(%{
            "caps" => %{
              "egress" => %{"domains" => domains, "methods" => ["GET"]},
              "storage" => %{"paths" => ["data/layer/"], "actions" => ["read", "write"]},
              "tools" => ["*"],
              "limits" => %{"timeout" => "30s"}
            }
          })
      })
  end

  defp head!(local, name_ref) do
    {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(local, name_ref)
    {:ok, head} = Sanctum.Consent.head_consent(local, profile_id)
    {:ok, blob} = Prima.Authority.Blob.parse(head.resolved_policy)
    {:ok, ingress} = Prima.Authority.Blob.ingress(blob, name_ref)
    {head, ingress, blob.nodes[name_ref].limits}
  end

  defp click(view, selector) do
    view |> element(selector) |> render_click()
    render(view)
  end

  defp view_context(view), do: :sys.get_state(view.pid).socket.assigns.context

  # The assigns of the layer `id` holds in the view's process.
  defp layer_assigns(view, id \\ "system-layer") do
    {by_cid, _ids, _next} = :sys.get_state(view.pid).components

    Enum.find_value(by_cid, fn {_cid, entry} ->
      if elem(entry, 0) == PrismWeb.SystemLayer and elem(entry, 1) == id, do: elem(entry, 2)
    end)
  end

  defp head_refs(local, name_ref) do
    {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(local, name_ref)
    {:ok, head} = Sanctum.Consent.head_consent(local, profile_id)
    Enum.map(head.vault_refs, & &1.vault_entry_id)
  end

  describe "the grant" do
    setup [:signed_in, :needing_key]

    test "its body is the consent sheet: the suggested entry opens bound, and is committed with it",
         %{view: view, ref: ref, name_ref: name_ref, entry: entry, local: local} do
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-bind", ref)

      # The one entry that meets the required need is the plan's
      # suggestion: the grant opens with it bound, standing, and the
      # preview is of exactly that.
      assert grant.subject.decisions["bindings"] == [
               %{
                 "need" => "api_key",
                 "entry_id" => entry.id,
                 "lifetime" => %{"kind" => "standing"}
               }
             ]

      assert [%{"kind" => "credential", "values" => %{"name" => name}}] =
               Enum.filter(grant.subject.preview.rows, &(&1["kind"] == "credential"))

      assert name == entry.name

      html = prompt(view, grant)

      # The walk as the prompt arrived with it, drawn in the layer: the
      # need, the entry that meets it, pressed, and nothing to change to.
      assert html =~ ~s(data-kind="grant")
      assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))

      assert has_element?(
               view,
               ~s([data-test="grant-needs"]),
               "to call the service with your key"
             )

      assert has_element?(view, ~s([data-test="grant-pick"][aria-pressed="true"]), entry.name)
      refute has_element?(view, ~s([data-test="grant-change"]))
      refute html =~ "sk-layer-not-shown"

      # The binding in one sentence, and its lifetime, until revoked.
      assert has_element?(
               view,
               ~s([data-row="credential"] .consent-sheet__sentence),
               "#{name_ref} uses #{entry.name}, an entry of this athanor, for its own calls"
             )

      assert has_element?(view, ~s([data-lifetime="standing"][aria-pressed="true"]))
      refute has_element?(view, ~s([data-lifetime="once"][aria-pressed="true"]))
      refute has_element?(view, ~s(button[phx-click="confirm"][disabled]))

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-bind") == :confirmed
      assert open_prompt(view) == nil
      assert entry.id in head_refs(local, name_ref)
    end

    test "a suggestion the home refuses to preview opens the grant with nothing bound, and " <>
           "the grant says why",
         %{view: view, ref: ref, entry: entry, local: local} do
      # The suggested entry is revoked between the plan and the preview:
      # when the gate admits the preview of the suggestion, in this
      # process, before its handler reads the entry.
      test = self()
      handler = "revoke-before-preview-#{System.unique_integer([:positive])}"

      revoke = fn
        _event, _measure, %{tool: "profile", action: "preview"}, _config ->
          if self() == test and Process.get(:revoked) == nil do
            Process.put(:revoked, Sanctum.Vault.revoke(local, entry.id))
          end

        _event, _measure, _meta, _config ->
          :ok
      end

      :ok = :telemetry.attach(handler, [:cyfr, :grimoire, :decision, :admitted], revoke, nil)
      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-refused", ref)
      :telemetry.detach(handler)
      assert {:ok, _affected} = Process.get(:revoked)

      # Opened with nothing bound, and the home's sentence for why.
      assert grant.subject.decisions["bindings"] == []
      assert refused = grant.subject[:suggestion_refused]
      assert is_binary(refused) and refused != ""
      refute refused =~ "sk-layer-not-shown"

      html = prompt(view, grant)
      assert html =~ ~s(data-prompt-id="g-refused")

      assert has_element?(
               view,
               ~s([data-test="grant-needs"] [data-test="grant-refusal"][role="alert"]),
               "The suggested entries were not bound"
             )

      [shown] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test="grant-needs"] [data-test="grant-refusal"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

      assert shown ==
               "The suggested entries were not bound: " <>
                 (refused |> String.replace(~r/\s+/, " ") |> String.trim())

      refute has_element?(view, ~s([data-test="grant-pick"][aria-pressed="true"]))
      refute html =~ "sk-layer-not-shown"
    end

    test "a commit the home refuses is planned again, and the next confirmation commits",
         %{view: view, ref: ref, name_ref: name_ref, entry: entry, local: local} do
      ctx = view_context(view)
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(ctx, "g-again", ref)
      prompt(view, grant)

      view
      |> element(~s([data-test="grant-pick"][phx-value-entry_id="#{entry.id}"]))
      |> render_click()

      render(view)

      # The walk's plan token is spent before the person confirms: the
      # commit is refused, and consumed nothing of the person's choice.
      %{current: %{subject: %{plan: %{plan_token: token}}}} = layer_assigns(view)

      _spent =
        Sanctum.Consent.Proof.consume(token, %{
          kind: :plan,
          commit_digest: "sha256:spent",
          athanor_id: ctx.athanor_id
        })

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert {:refused, _reason} = outcome("g-again")
      html = render(view)
      assert html =~ ~s(role="alert")
      assert open_prompt(view) == "g-again"

      # The sheet planned again, the same entry still bound, and the layer
      # holds the new walk.
      render(view)
      %{current: %{subject: %{plan: %{plan_token: again}}}} = layer_assigns(view)
      assert again != token
      refute has_element?(view, ~s(button[phx-click="confirm"][disabled]))
      assert has_element?(view, ~s([data-test="grant-pick"][aria-pressed="true"]), entry.name)

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-again") == :confirmed
      assert entry.id in head_refs(local, name_ref)
    end

    test "a confirm that arrives with a pick commits the entry the sheet holds then",
         %{view: view, ref: ref, name_ref: name_ref, entry: first, local: local} do
      params = %{
        name: "second key #{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "layer.test",
        fields: %{"LAYER_API_KEY" => "sk-second-not-shown"},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      }

      entering =
        Sanctum.TestContext.confirmed(local, :credential_entry, %{
          operation: "vault.create",
          arguments: params,
          resource: params.name
        })

      {:ok, second} = Sanctum.Vault.create(entering, params)

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-race", ref)
      prompt(view, grant)

      # The person picks the first entry; it is previewed and shown.
      view
      |> element(~s([data-test="grant-pick"][phx-value-entry_id="#{first.id}"]))
      |> render_click()

      render(view)
      assert has_element?(view, ~s([data-test="grant-pick"][aria-pressed="true"]), first.name)

      # Then changes to the second and confirms before the page answered:
      # both events wait in the view's mailbox, in the order a browser sent
      # them, as the client sends them without waiting for a reply.
      {by_cid, _ids, _next} = :sys.get_state(view.pid).components

      cid_of = fn module ->
        Enum.find_value(by_cid, fn {cid, entry} -> if elem(entry, 0) == module, do: cid end)
      end

      {_ref, topic, proxy} = view.proxy
      join_ref = :sys.get_state(proxy).join_ref

      event = fn ref, cid, name, value ->
        %Phoenix.Socket.Message{
          join_ref: join_ref,
          topic: topic,
          event: "event",
          ref: ref,
          payload: %{"type" => "click", "event" => name, "value" => value, "cid" => cid}
        }
      end

      [_, need] = Regex.run(~r/phx-value-need="([^"]+)"/, render(view))
      :ok = :sys.suspend(view.pid)

      send(
        view.pid,
        event.("990001", cid_of.(PrismWeb.ConsentSheetComponent), "pick_entry", %{
          "need" => need,
          "entry_id" => second.id
        })
      )

      send(
        view.pid,
        event.("990002", cid_of.(PrismWeb.SystemLayer), "confirm", %{"id" => "g-race"})
      )

      :ok = :sys.resume(view.pid)

      assert outcome("g-race") == :confirmed
      refs = head_refs(local, name_ref)

      assert second.id in refs,
             "the sheet held the second entry; the layer committed #{inspect(refs)}"

      refute first.id in refs, "the entry the person changed away from was bound"
    end

    test "a grant planned in another athanor commits nothing and ends", %{view: view, ctx: ctx} do
      elsewhere = grant(%{ctx | athanor_id: "ath_elsewhere"}, "g-elsewhere")
      prompt(view, elsewhere)

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-elsewhere") == :dismissed
      assert open_prompt(view) == nil
      no_outcome("g-elsewhere")
    end

    test "a credential entry a grant raised in another athanor sends nothing and ends, as " <>
           "does one whose grant is gone",
         %{view: view, ctx: ctx} do
      connect = fn id, athanor_id, grant_id ->
        %{
          id: id,
          kind: :credential_entry,
          action: :credential_entry,
          subject: %{
            name: "elsewhere.test",
            field: "API_KEY",
            athanor_id: athanor_id,
            provider: "elsewhere.test",
            hosts: ["api.elsewhere.example"],
            paths: [],
            disclose_needed: false,
            return: %{prompt: grant_id, need: "api_key"}
          }
        }
      end

      typed = fn id ->
        view
        |> layer()
        |> render_submit("enter_credential", %{
          "prompt_id" => id,
          "name" => "elsewhere.test",
          "secret" => "sk-elsewhere",
          "destination_hosts" => "api.elsewhere.example"
        })
      end

      # Raised in another athanor, its grant waiting behind it, submitted
      # before the layer is next handed its context: the grant is placed
      # straight in the layer, so the page does not draw it again first.
      prompt(view, connect.("connect-elsewhere", "ath_elsewhere", "g-here"))

      Phoenix.LiveView.send_update(view.pid, PrismWeb.SystemLayer,
        id: "system-layer",
        prompt: grant(ctx, "g-here")
      )

      render(view)

      assert %{current: %{id: "connect-elsewhere"}, queue: [%{id: "g-here"}]} =
               layer_assigns(view)

      typed.("connect-elsewhere")
      assert outcome("connect-elsewhere") == :dismissed
      assert open_prompt(view) == "g-here"

      # Raised here, for a grant no longer waiting.
      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("g-here") == :dismissed
      prompt(view, connect.("connect-orphan", ctx.athanor_id, "g-gone"))
      assert open_prompt(view) == "connect-orphan"
      typed.("connect-orphan")
      assert outcome("connect-orphan") == :dismissed
      assert open_prompt(view) == nil

      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
      {:ok, entries} = Sanctum.Vault.list(ctx)
      refute Enum.any?(entries, &(&1.provider_hint == "elsewhere.test"))
    end
  end

  # A catalyst in the person's athanor with `manifest`, as `ref`.
  defp publish_catalyst!(local, name, manifest) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(local, @wasm, %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A catalyst of the layer's tests",
        manifest: Jason.encode!(manifest)
      })

    "catalyst:local.#{name}"
  end

  defp entry!(local, params) do
    params =
      Map.merge(
        %{name: "layer entry #{System.unique_integer([:positive])}", kind: "api_key"},
        params
      )

    entering =
      Sanctum.TestContext.confirmed(local, :credential_entry, %{
        operation: "vault.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.Vault.create(entering, params)
    entry
  end

  defp head_rows(local, name_ref) do
    {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(local, name_ref)
    {:ok, head} = Sanctum.Consent.head_consent(local, profile_id)
    {profile_id, head}
  end

  defp credential_rows(%{rows: rows}), do: Enum.filter(rows, &(&1["kind"] == "credential"))

  describe "each credential's lifetime" do
    setup [:signed_in, :needing_key]

    test "a lifetime chosen is previewed and committed on its binding's row; this session " <>
           "is the earlier of the session's end and a day on",
         %{view: view, ref: ref, name_ref: name_ref, local: local} do
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-life", ref)

      # The person's session ends: the walk carries when.
      assert {:ok, session_end, 0} = DateTime.from_iso8601(grant.subject.session_expires_at)
      assert DateTime.compare(session_end, DateTime.utc_now()) == :gt

      prompt(view, grant)
      assert has_element?(view, ~s([data-lifetime="session"]), "This session, until")

      click(view, ~s([data-lifetime="1h"]))
      %{current: %{subject: %{decisions: decisions, preview: preview}}} = layer_assigns(view)

      assert [%{"lifetime" => %{"kind" => "until", "until" => until}}] = decisions["bindings"]
      {:ok, at, 0} = DateTime.from_iso8601(until)
      assert_in_delta DateTime.diff(at, DateTime.utc_now()), 3600, 60

      # The preview is of exactly that until, as the commit will be.
      assert [%{"values" => %{"lifetime" => %{"kind" => "until", "until" => ^until}}}] =
               credential_rows(preview)

      assert has_element?(view, ~s([data-lifetime="1h"][aria-pressed="true"]))

      click(view, ~s([data-lifetime="session"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert [%{"lifetime" => %{"kind" => "until", "until" => until}}] = decisions["bindings"]
      {:ok, at, 0} = DateTime.from_iso8601(until)

      held =
        Enum.min_by([session_end, DateTime.add(DateTime.utc_now(), 86_400)], &DateTime.to_unix/1)

      assert_in_delta DateTime.diff(at, held), 0, 60

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-life") == :confirmed

      {_profile, head} = head_rows(local, name_ref)
      assert [%{lifetime_kind: "until", expires_at: expires_at}] = head.vault_refs
      assert DateTime.compare(DateTime.truncate(expires_at, :second), at) == :eq
    end

    test "a once the head's root used is offered to be granted once again, which renews it",
         %{view: view, ref: ref, name_ref: name_ref, entry: entry, local: local} do
      {:ok, _} =
        commit_with!(local, name_ref, %{
          bindings: [%{need: "api_key", entry_id: entry.id, lifetime: %{kind: "once"}}]
        })

      {profile_id, head} = head_rows(local, name_ref)
      [%{binding_key: key}] = head.vault_refs

      :ok =
        Arca.ConsentStorage.consume_once(
          Context.actor(local),
          profile_id,
          head.id,
          key,
          "exec_layer_once"
        )

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-renew", ref)
      assert [%{binding_key: ^key, consumed: true}] = grant.subject.plan.head_bindings

      # A re-grant opens on what the head binds, never wider: the once
      # stays once, not the suggestion's standing.
      assert grant.subject.decisions["bindings"] == [
               %{"need" => "api_key", "entry_id" => entry.id, "lifetime" => %{"kind" => "once"}}
             ]

      prompt(view, grant)
      assert has_element?(view, ~s([data-lifetime="once"][aria-pressed="true"]))
      assert has_element?(view, ~s([data-test="grant-renew"][aria-pressed="false"]))

      click(view, ~s([data-test="grant-renew"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)

      assert decisions["bindings"] == [
               %{
                 "need" => "api_key",
                 "entry_id" => entry.id,
                 "lifetime" => %{"kind" => "once"},
                 "renew" => true
               }
             ]

      assert has_element?(view, ~s([data-test="grant-renew"][aria-pressed="true"]))

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-renew") == :confirmed

      {_profile, head} = head_rows(local, name_ref)
      assert [%{lifetime_kind: "once", consumed_by_root: nil}] = head.vault_refs
    end

    test "a binding the head granted until a time now passed reopens with no lifetime " <>
           "chosen, says why, and is bound again only once the person chooses one",
         %{view: view, ref: ref, name_ref: name_ref, entry: entry, local: local} do
      ahead = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      {:ok, _} =
        commit_with!(local, name_ref, %{
          bindings: [
            %{
              need: "api_key",
              entry_id: entry.id,
              lifetime: %{kind: "until", until: DateTime.to_iso8601(ahead)}
            }
          ]
        })

      # The hour has gone by.
      {_profile_id, head} = head_rows(local, name_ref)
      passed = DateTime.add(DateTime.utc_now(), -60, :second)

      {1, _} =
        Arca.Repo.update_all(
          from(r in Arca.Schemas.ConsentVaultRef,
            where: r.athanor_id == ^local.athanor_id and r.consent_id == ^head.id
          ),
          set: [expires_at: passed]
        )

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-passed", ref)
      assert grant.subject.decisions["bindings"] == []

      prompt(view, grant)
      assert has_element?(view, ~s([data-test="grant-lifetime-pending"]), "has passed")
      refute has_element?(view, ~s([data-lifetime][aria-pressed="true"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert decisions["bindings"] == []

      click(view, ~s([data-test="grant-lifetime-pending"] [data-lifetime="1h"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)

      assert [%{"entry_id" => bound, "lifetime" => %{"kind" => "until", "until" => until}}] =
               decisions["bindings"]

      assert bound == entry.id
      {:ok, at, 0} = DateTime.from_iso8601(until)
      assert_in_delta DateTime.diff(at, DateTime.utc_now()), 3600, 60
      refute has_element?(view, ~s([data-test="grant-lifetime-pending"]))

      assert has_element?(
               view,
               ~s([data-test="grant-lifetime"] [data-lifetime="1h"][aria-pressed="true"])
             )

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-passed") == :confirmed

      {_profile, head} = head_rows(local, name_ref)
      assert [%{lifetime_kind: "until", expires_at: expires_at}] = head.vault_refs
      assert DateTime.compare(DateTime.truncate(expires_at, :second), at) == :eq
    end
  end

  describe "each credential's need" do
    setup :signed_in

    defp local_of(ctx),
      do: %{Sanctum.TestContext.local() | user_id: ctx.user_id, athanor_id: ctx.athanor_id}

    test "an optional need's suggestion is a click away, never bound unasked",
         %{view: view, ctx: ctx} do
      local = local_of(ctx)
      n = System.unique_integer([:positive])

      name_ref =
        publish_catalyst!(local, "layer-optional-#{n}", %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:optional.test",
              "reason" => "to call the service, if you like",
              "fields" => ["OPTIONAL_KEY"],
              "required" => false
            }
          }
        })

      entry =
        entry!(local, %{
          provider_hint: "optional.test",
          fields: %{"OPTIONAL_KEY" => "sk-optional"},
          destination: %{"hosts" => ["api.optional.example"]},
          disclose: true
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-opt", name_ref)
      assert grant.subject.decisions["bindings"] == []

      prompt(view, grant)
      assert has_element?(view, ~s([data-test="grant-pick"][aria-pressed="false"]), entry.name)

      click(view, ~s([data-test="grant-pick"][phx-value-entry_id="#{entry.id}"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert [%{"entry_id" => id}] = decisions["bindings"]
      assert id == entry.id
    end

    test "a dependency's required need opens on its suggestion, selected with its lifetime",
         %{view: view, ctx: ctx} do
      local = local_of(ctx)
      n = System.unique_integer([:positive])

      dep =
        publish_catalyst!(local, "layer-dep-#{n}", %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:dep.test",
              "reason" => "to reach the dependency's service",
              "fields" => ["DEP_KEY"],
              "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}
            }
          },
          "caps" => %{"egress" => %{"domains" => ["api.dep.example"]}}
        })

      app =
        publish_catalyst!(local, "layer-app-#{n}", %{
          "dependencies" => %{"static" => [%{"ref" => dep}]}
        })

      entry =
        entry!(local, %{
          provider_hint: "dep.test",
          fields: %{"DEP_KEY" => "sk-dep"},
          destination: %{"hosts" => ["api.dep.example"]}
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-dep", app)

      assert grant.subject.decisions["selections"] == [
               %{
                 "dep" => dep,
                 "from" => app,
                 "entry_id" => entry.id,
                 "lifetime" => %{"kind" => "standing"}
               }
             ]

      assert [%{"node" => ^app}] = credential_rows(grant.subject.preview)

      prompt(view, grant)

      assert has_element?(
               view,
               ~s([data-dep="#{dep}"] [data-test="grant-pick"][aria-pressed="true"]),
               entry.name
             )

      assert has_element?(
               view,
               ~s([data-row="credential"] .consent-sheet__sentence),
               "#{dep} uses #{entry.name}, an entry of this athanor"
             )

      click(view, ~s([data-row="credential"] [data-lifetime="once"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert [%{"lifetime" => %{"kind" => "once"}}] = decisions["selections"]

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-dep") == :confirmed

      {_profile, head} = head_rows(local, app)
      assert [%{vault_entry_id: id, lifetime_kind: "once"}] = head.vault_refs
      assert id == entry.id
    end

    test "a catalyst asking for other methods is narrowed to its GET and HEAD, and that is " <>
           "what is granted",
         %{view: view, ctx: ctx} do
      local = local_of(ctx)

      node =
        publish_catalyst!(local, "layer-methods-#{System.unique_integer([:positive])}", %{
          "caps" => %{
            "egress" => %{"domains" => ["api.methods.example"], "methods" => ["GET", "POST"]}
          }
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-get", node)
      prompt(view, grant)

      assert has_element?(view, ~s([data-test="grant-get-head-only"]), "GET only")
      refute render(view) |> String.downcase() =~ "read only"

      click(view, ~s([data-test="grant-get-head-only"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert decisions["subset"] == %{node => %{"egress" => %{"methods" => ["GET"]}}}

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-get") == :confirmed

      {_head, ingress, _limits} = head!(local, node)
      assert ingress.egress.methods == ["GET"]
    end

    test "Connect raises the credential entry in front of the grant, prefilled from the need; " <>
           "the entry made comes back bound, and is what is granted",
         %{view: view, ctx: ctx} do
      local = local_of(ctx)
      n = System.unique_integer([:positive])

      name_ref =
        publish_catalyst!(local, "layer-connect-#{n}", %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:connect.test",
              "reason" => "to call the connected service",
              "fields" => ["CONNECT_KEY"],
              "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
              "hosts" => ["api.connect.example"],
              "paths" => ["/v1/"]
            }
          },
          "caps" => %{"egress" => %{"domains" => ["api.connect.example"]}}
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-connect", name_ref)
      assert grant.subject.decisions["bindings"] == []
      prompt(view, grant)

      click(view, ~s([data-test="grant-connect"]))
      id = open_prompt(view)
      assert "connect-" <> _ = id
      html = render(view)
      assert html =~ "Connect your connect.test account"
      assert html =~ "One more prompt is waiting."

      # Prefilled from the need: the name, its hosts and paths; the need
      # takes an attached key, so disclosure stays off.
      assert has_element?(view, ~s(input[name="name"][value="connect.test"]))
      assert has_element?(view, ~s(input[name="destination_hosts"][value="api.connect.example"]))
      assert has_element?(view, ~s(input[name="destination_paths"][value="/v1/"]))
      refute has_element?(view, ~s(input[name="disclose"][checked]))

      name = "Connected #{n}"

      typed = %{
        "prompt_id" => id,
        "name" => name,
        "secret" => "sk-connect-#{n}",
        "destination_hosts" => "api.connect.example",
        "destination_paths" => "/v1/"
      }

      view |> form("#system-layer-credential", typed) |> render_submit()

      assert {:ok, [%{ref: record}]} =
               Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

      wait_until(fn -> render(view) =~ ~s(data-ref="#{record}") end, 2_000, "the waiting record")
      Sanctum.TestContext.prove!(ctx, record)
      assert_push_event(view, "system_layer:resubmit", %{form: "system-layer-credential"}, 2_000)
      view |> form("#system-layer-credential", typed) |> render_submit()
      assert outcome(id) == :confirmed

      {:ok, entries} = Sanctum.Vault.list(ctx)
      entry = Enum.find(entries, &(&1.name == name))
      assert entry.provider_hint == "connect.test"

      assert entry.destination == %{
               "hosts" => ["api.connect.example"],
               "paths" => ["/v1/"],
               "scheme" => "https"
             }

      assert entry.attach_only == true

      # The grant is back, planned again, with the new entry bound.
      assert open_prompt(view) == "g-connect"

      wait_until(
        fn ->
          render(view)
          has_element?(view, ~s([data-test="grant-pick"][aria-pressed="true"]), name)
        end,
        2_000,
        "the grant planned again"
      )

      %{current: %{subject: %{decisions: decisions, preview: %{}}}} = layer_assigns(view)
      assert [%{"entry_id" => bound}] = decisions["bindings"]
      assert bound == entry.id

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-connect") == :confirmed
      assert entry.id in head_refs(local, name_ref)
    end

    test "a lifetime the person chose is pressed again when the grant comes back from Connect",
         %{view: view, ctx: ctx} do
      local = local_of(ctx)
      n = System.unique_integer([:positive])
      attach = %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}

      dep =
        publish_catalyst!(local, "layer-back-dep-#{n}", %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:back-dep.test",
              "reason" => "to reach the dependency's service",
              "fields" => ["DEP_KEY"],
              "attach" => attach
            }
          }
        })

      app =
        publish_catalyst!(local, "layer-back-app-#{n}", %{
          "dependencies" => %{"static" => [%{"ref" => dep}]},
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:back.test",
              "reason" => "to call the app's service",
              "fields" => ["APP_KEY"],
              "attach" => attach
            }
          }
        })

      entry =
        entry!(local, %{
          provider_hint: "back.test",
          fields: %{"APP_KEY" => "sk-back"},
          destination: %{"hosts" => ["api.back.example"]}
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-back", app)
      prompt(view, grant)
      assert has_element?(view, ~s([data-test="grant-pick"][aria-pressed="true"]), entry.name)

      click(view, ~s([data-row="credential"] [data-lifetime="1h"]))
      %{current: %{subject: %{decisions: before}}} = layer_assigns(view)
      assert [%{"lifetime" => %{"kind" => "until", "until" => until}}] = before["bindings"]

      # The dependency's need has nothing to meet it: Connect, then back.
      click(view, ~s([data-dep="#{dep}"] [data-test="grant-connect"]))
      id = open_prompt(view)
      assert "connect-" <> _ = id
      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome(id) == :dismissed
      assert open_prompt(view) == "g-back"
      render(view)

      # The sheet is drawn again, and presses the lifetime chosen before.
      assert has_element?(
               view,
               ~s([data-row="credential"] [data-lifetime="1h"][aria-pressed="true"])
             )

      refute has_element?(view, ~s([data-lifetime="standing"][aria-pressed="true"]))
      %{current: %{subject: %{decisions: after_back}}} = layer_assigns(view)
      assert [%{"lifetime" => %{"kind" => "until", "until" => ^until}}] = after_back["bindings"]
    end

    test "a Connect prompt belongs to its grant's athanor: when the page opens another, it " <>
           "ends with its grant, and no entry is made in either",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      here = seated_athanor()

      {:ok, group} =
        Sanctum.Tenancy.Athanors.create_group(user.user_id, "Elsewhere #{user.namespace}")

      {:ok, view, _html} =
        live_isolated(conn, MovingHost, session: %{"athanor_id" => here.id, "test" => self()})

      ctx = person_context(user, here)
      local = local_of(ctx)

      name_ref =
        publish_catalyst!(local, "layer-move-#{System.unique_integer([:positive])}", %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:move.test",
              "reason" => "to call the service it moves with",
              "fields" => ["MOVE_KEY"],
              "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
              "hosts" => ["api.move.example"]
            }
          },
          "caps" => %{"egress" => %{"domains" => ["api.move.example"]}}
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-move", name_ref)
      prompt(view, grant)
      click(view, ~s([data-test="grant-connect"]))
      id = open_prompt(view)
      assert "connect-" <> _ = id
      assert has_element?(view, ~s(input[name="destination_hosts"][value="api.move.example"]))

      # The page opens the group.
      send(view.pid, {:focus, group.id})
      render(view)
      render(view)

      # A key typed into the prompt, submitted after the move, is stored
      # in neither athanor, nor asked to be.
      view
      |> layer()
      |> render_submit("enter_credential", %{
        "prompt_id" => id,
        "name" => "move.test",
        "secret" => "sk-moved",
        "destination_hosts" => "api.move.example"
      })

      group_ctx = person_context(user, group)

      for at <- [ctx, group_ctx] do
        {:ok, entries} = Sanctum.Vault.list(at)
        refute Enum.any?(entries, &(&1.provider_hint == "move.test"))
        assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(at), user.user_id)
      end

      # The grant and the entry it asked for ended with the move.
      assert outcome("g-move") == :dismissed
      assert outcome(id) == :dismissed
      assert open_prompt(view) == nil
      refute render(view) =~ "Connect your move.test account"
    end

    test "a need the component reads itself is connected with disclosure on; dismissed, " <>
           "the grant comes back as it was",
         %{view: view, ctx: ctx} do
      local = local_of(ctx)

      name_ref =
        publish_catalyst!(local, "layer-reads-#{System.unique_integer([:positive])}", %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:reads.test",
              "reason" => "to call the service with the key it reads",
              "fields" => ["READS_KEY", "READS_ORG"]
            }
          }
        })

      # An attach-only entry of the provider, which the need cannot take.
      _attached =
        entry!(local, %{
          provider_hint: "reads.test",
          fields: %{"READS_KEY" => "sk-attached"},
          destination: %{"hosts" => ["api.reads.example"]}
        })

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-reads", name_ref)
      prompt(view, grant)
      assert has_element?(view, ~s([data-test="grant-why"]), "attach-only")

      click(view, ~s([data-test="grant-connect"]))
      id = open_prompt(view)
      assert "connect-" <> _ = id

      # The need names two fields, so the key is stored under the default.
      assert has_element?(
               view,
               ~s(label[for="system-layer-secret"]),
               "API_KEY for your reads.test"
             )

      assert has_element?(view, ~s(input[name="disclose"][checked]))
      refute has_element?(view, ~s(input[name="destination_hosts"][value]))

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome(id) == :dismissed
      assert open_prompt(view) == "g-reads"
      render(view)
      assert has_element?(view, ~s([data-test="grant-connect"]))
    end
  end

  describe "the person's exact choices" do
    setup [:signed_in, :asking_more]

    test "origins, narrowing and lowered limits are submitted exactly, and are what is granted",
         %{view: view, ref: ref, name_ref: node, local: local} do
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-choose", ref)
      assert grant.subject.decisions["origins"] == ["interactive"]
      prompt(view, grant)

      # Interactive is always named; on a first grant the others are each
      # a visible choice, unticked.
      assert has_element?(view, ~s(input[data-origin="interactive"][checked][disabled]))

      for origin <- ~w(programmatic schedule webhook) do
        assert has_element?(view, ~s(input[data-origin="#{origin}"]))
        refute has_element?(view, ~s(input[data-origin="#{origin}"][checked]))
      end

      # The wildcard ask is one row, every tool, whole or none.
      assert has_element?(view, ~s([data-row="tools"]), "Every tool of the catalog (*)")

      # A browser sends a checkbox's own value under `value` and none for a
      # box unticked, so no box carries its choice there: the test client
      # sends `phx-value-value` as written, and would hide that loss.
      assert has_element?(view, ~s(input[type="checkbox"][phx-value-choice]))
      refute has_element?(view, ~s(input[type="checkbox"][phx-value-value]))

      click(view, ~s(input[phx-click="toggle_origin"][phx-value-origin="programmatic"]))

      click(
        view,
        ~s(input[phx-click="toggle_value"][phx-value-field="domains"][phx-value-choice="b.layer.example"])
      )

      click(
        view,
        ~s(input[phx-click="toggle_value"][phx-value-field="actions"][phx-value-choice="write"])
      )

      click(view, ~s(input[phx-click="toggle_every_tool"]))

      view
      |> form(~s(form[phx-submit="set_limits"]), %{"limits" => %{"timeout" => "10s"}})
      |> render_submit()

      render(view)

      # The layer holds exactly the choices, never a category.
      %{current: %{subject: %{decisions: decisions, preview: preview}}} = layer_assigns(view)
      assert decisions["origins"] == ["interactive", "programmatic"]

      assert decisions["subset"] == %{
               node => %{
                 "egress" => %{"domains" => ["a.layer.example"]},
                 "storage" => %{"actions" => ["read"]},
                 "tools" => [],
                 "limits" => %{"timeout" => "10s"}
               }
             }

      assert preview.origins == ["interactive", "programmatic"]
      assert has_element?(view, ~s([data-row="egress"]), "narrowed by you")
      assert has_element?(view, ~s([data-test="grant-admits"]), "programmatic")

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-choose") == :confirmed

      {head, ingress, limits} = head!(local, node)
      assert head.admitted_origins == [:interactive, :programmatic]
      assert ingress.egress.domains == ["a.layer.example"]
      assert ingress.storage.actions == ["read"]
      assert ingress.tools == []
      assert limits.timeout == "10s"
    end

    test "a narrowing the home refuses keeps every control, and the person can choose again",
         %{view: view, ref: ref, name_ref: node, local: local} do
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-zero", ref)
      prompt(view, grant)
      assert has_element?(view, ~s(form[phx-submit="set_limits"]))

      # Zero bounds nothing a timeout reads: the home refuses it, and says
      # so beside the limits that asked for it.
      view
      |> form(~s(form[phx-submit="set_limits"]), %{"limits" => %{"timeout" => "0s"}})
      |> render_submit()

      render(view)

      assert has_element?(
               view,
               ~s([data-row="limits"] [data-test="grant-refusal"][role="alert"]),
               "name a positive duration"
             )

      # The walk is put back as it last previewed: the controls stay, and
      # the layer holds a preview of exactly its own choices.
      assert has_element?(view, ~s(form[phx-submit="set_limits"]))
      assert has_element?(view, ~s(input[phx-click="toggle_value"]))
      %{current: %{subject: %{decisions: decisions, preview: preview}}} = layer_assigns(view)
      refute Map.has_key?(decisions, "subset")
      assert %{rows: [_ | _]} = preview
      refute has_element?(view, ~s(button[phx-click="confirm"][disabled]))

      # A value the home takes previews, and the refusal goes.
      view
      |> form(~s(form[phx-submit="set_limits"]), %{"limits" => %{"timeout" => "10s"}})
      |> render_submit()

      render(view)
      refute has_element?(view, ~s([data-test="grant-refusal"]))
      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert decisions["subset"] == %{node => %{"limits" => %{"timeout" => "10s"}}}

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-zero") == :confirmed
      {_head, _ingress, limits} = head!(local, node)
      assert limits.timeout == "10s"
    end

    test "a limit above the ask is not offered, and changes nothing",
         %{view: view, ref: ref} do
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-above", ref)
      prompt(view, grant)
      %{current: %{subject: %{preview: before}}} = layer_assigns(view)

      view
      |> form(~s(form[phx-submit="set_limits"]), %{"limits" => %{"timeout" => "2h"}})
      |> render_submit()

      render(view)

      assert has_element?(
               view,
               ~s([data-row="limits"] [data-test="grant-refusal"]),
               "can be at most 30s"
             )

      %{current: %{subject: %{decisions: decisions, preview: after_refusal}}} =
        layer_assigns(view)

      refute Map.has_key?(decisions, "subset")
      assert after_refusal == before
    end

    test "a value the ask does not name is not a choice, and changes nothing",
         %{view: view, ref: ref, name_ref: node} do
      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-forged", ref)
      prompt(view, grant)

      # A forged event naming a domain outside the ask, and an origin
      # outside the three the sheet offers.
      sheet = with_target(view, "#consent-sheet-system-layer-grant-g-forged")

      render_click(sheet, "toggle_value", %{
        "node" => node,
        "kind" => "egress",
        "field" => "domains",
        "choice" => "evil.example"
      })

      render_click(sheet, "toggle_origin", %{"origin" => "interactive"})
      render(view)

      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      refute Map.has_key?(decisions, "subset")
      assert decisions["origins"] == ["interactive"]
    end

    test "a re-grant starts from the origins its head admits",
         %{view: view, ref: ref, name_ref: node, local: local} do
      {:ok, _} = commit_with!(local, node, %{origins: [:interactive, :schedule]})

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-regrant", ref)
      assert grant.subject.decisions["origins"] == ["interactive", "schedule"]
      assert grant.subject.preview.origins == ["interactive", "schedule"]

      prompt(view, grant)
      assert has_element?(view, ~s(input[data-origin="schedule"][checked]))
      refute has_element?(view, ~s(input[data-origin="programmatic"][checked]))
    end

    test "what changed is read against the head as the person narrowed it",
         %{view: view, ref: ref, name: name, name_ref: node, local: local} do
      # The person narrowed b away; the next version asks for c too.
      {:ok, _} =
        commit_with!(local, node, %{
          subset: %{node => %{"egress" => %{"domains" => ["a.layer.example"]}}}
        })

      publish_asking!(local, name, "0.2.0", [
        "a.layer.example",
        "b.layer.example",
        "c.layer.example"
      ])

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-delta", ref)

      assert [%{capability: "egress.domains", added: added}] =
               Enum.filter(grant.subject.plan.shape_diff, &(&1.capability == "egress.domains"))

      assert added == ["b.layer.example", "c.layer.example"]

      html = prompt(view, grant)
      assert has_element?(view, ~s([data-test="grant-delta"]), "which your grant does not give")
      assert has_element?(view, ~s([data-test="grant-delta"]), "c.layer.example")
      refute html =~ "now wants"
    end

    test "a storage path is picked inside the asked folder, in the door's spelling",
         %{view: view, ref: ref, name_ref: node, local: local} do
      {:ok, _} = Arca.Files.write(Sanctum.Context.actor(local), "data/layer/2026/notes.md", "n")

      {:ok, grant} = PrismWeb.SystemLayer.grant_prompt(view_context(view), "g-pick", ref)
      prompt(view, grant)

      click(view, ~s(button[phx-click="open_picker"][phx-value-path="data/layer/"]))
      assert has_element?(view, ~s([data-test="grant-picker"]), "2026/")

      click(view, ~s(button[phx-click="pick_path"][phx-value-path="data/layer/2026/"]))

      %{current: %{subject: %{decisions: decisions}}} = layer_assigns(view)
      assert decisions["subset"] == %{node => %{"storage" => %{"paths" => ["data/layer/2026/"]}}}

      # A folder outside the ask is not offered, whatever an event names.
      sheet = with_target(view, "#consent-sheet-system-layer-grant-g-pick")
      render_click(sheet, "pick_path", %{"node" => node, "path" => "data/other/"})
      render_click(sheet, "open_picker", %{"node" => node, "path" => "data/"})
      render(view)

      %{current: %{subject: %{decisions: again}}} = layer_assigns(view)
      assert again["subset"] == decisions["subset"]
      refute has_element?(view, ~s([data-test="grant-picker"]))

      view |> element(~s(button[phx-click="confirm"])) |> render_click()
      assert outcome("g-pick") == :confirmed
      {_head, ingress, _limits} = head!(local, node)
      assert ingress.storage.paths == ["data/layer/2026/"]
    end
  end

  # A grant committed straight through the walk, as another client would.
  defp commit_with!(local, node, over) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(local, %{ref: node})
    decisions = Map.merge(%{ref: node}, over)
    {:ok, preview} = Sanctum.Consent.Commit.preview(local, decisions)

    Sanctum.Consent.Commit.commit(local, %{
      decisions: decisions,
      plan_token: plan.plan_token,
      proof: preview.proof,
      commit_digest: preview.commit_digest,
      expected_consent_revision: plan.expected_consent_revision
    })
  end

  describe "a nested view's own layer" do
    test "has its own id, opens no stream, and draws what it is shown", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      ctx = person_context(user, athanor)
      other = other_session!(ctx)

      # A record already waiting, and one asked once the layer is up: a
      # listening layer shows both; this one shows neither.
      ask = fn ->
        PrismWeb.Ops.call_tool(other, "vault/create", %{
          "name" => "quiet-#{System.unique_integer([:positive])}",
          "kind" => "api_key",
          "fields" => %{"KEY" => "sk-quiet"},
          "destination" => %{"hosts" => ["api.example.com"]}
        })
      end

      assert {:error, {:confirmation_required, _}} = ask.()

      {:ok, view, html} =
        live_isolated(conn, QuietHost, session: %{"athanor_id" => athanor.id, "test" => self()})

      assert html =~ ~s(id="system-layer-panel")
      assert html =~ ~s(id="system-layer-panel-dialog")
      refute html =~ ~s(id="system-layer")
      assert {:error, {:confirmation_required, _}} = ask.()
      render(view)
      assert open_prompt(view) == nil

      assert %{listen: false, listening: nil} = layer_assigns(view, "system-layer-panel")

      # What it is shown, it draws and reports, under its own id.
      prompt(view, sign_in("quiet-sign-in"))
      assert has_element?(view, ~s(#system-layer-panel-dialog [data-kind="sign_in"]))
      view |> element(~s(#system-layer-panel button[phx-click="dismiss"])) |> render_click()
      assert outcome("quiet-sign-in") == :dismissed
      end_views()
    end
  end

  describe "a malformed prompt" do
    setup :signed_in

    test "is not drawn and is refused as :invalid_prompt", %{view: view, ctx: ctx} do
      malformed = [
        {"m1", %{id: "m1", kind: :grant, action: :grant, subject: %{}}},
        {"m2", %{id: "m2", kind: :teleport, action: nil, subject: %{}}},
        {"m3", %{id: "m3", kind: :sign_in, action: :grant, subject: %{}}},
        {"m4", %{id: "m4", kind: :grant, action: :everything, subject: grant(ctx, "x").subject}},
        {"m4a", grant(ctx, "m4a") |> update_in([:subject], &Map.delete(&1, :athanor_id))},
        {"m5", %{id: "m5", kind: :credential_entry, action: :credential_entry, subject: %{}}},
        {"m6", %{id: "m6", kind: :safe_mode, action: nil, subject: %{reason: :crashed}}},
        {"m7", Map.put(sign_in("m7"), :operation, "vault.delete")},
        {nil, %{kind: :sign_in}},
        {nil, "sign in please"}
      ]

      for {id, bad} <- malformed do
        html = prompt(view, bad)
        assert outcome(id) == {:refused, :invalid_prompt}
        assert html =~ ~s(data-open="false")
      end
    end

    test "a grant opens on a typed preview with no summary, and refuses malformed typed rows",
         %{view: view, ctx: ctx} do
      ref = "tincture:local.system-layer-probe"

      # No sentence at all: the typed rows, the origins, the digest and the
      # proof are the whole preview, and the prompt opens on them.
      refute Map.has_key?(grant(ctx, "typed").subject.preview, :summary)
      html = prompt(view, grant(ctx, "typed"))
      assert html =~ ~s(data-prompt-id="typed")

      assert has_element?(
               view,
               ~s([data-test="grant-rows"] [data-row="egress"]),
               "api.example.com"
             )

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("typed") == :dismissed

      egress = hd(typed_preview(ref).rows)

      credential = %{
        "kind" => "credential",
        "node" => ref,
        "narrowed" => false,
        "values" => %{"name" => "key", "fields" => ["KEY"], "scopes" => []}
      }

      malformed = [
        # The old shape: a sentence and no rows.
        {"p1",
         put_in(grant(ctx, "p1"), [:subject, :preview], %{
           summary: ["Talks to api.example.com"],
           proof: "not-a-proof",
           commit_digest: "sha256:" <> String.duplicate("0", 64)
         })},
        # A row of a kind the preview does not know.
        {"p2",
         put_in(
           grant(ctx, "p2"),
           [:subject, :preview],
           typed_preview(ref, [%{egress | "kind" => "vault_unlock"}])
         )},
        # A credential that names no edge.
        {"p3", put_in(grant(ctx, "p3"), [:subject, :preview], typed_preview(ref, [credential]))},
        # A row carrying a sentence.
        {"p4",
         put_in(
           grant(ctx, "p4"),
           [:subject, :preview],
           typed_preview(ref, [Map.put(egress, "summary", "Talks to api.example.com")])
         )},
        # No proof to commit with, or no origins.
        {"p5", update_in(grant(ctx, "p5"), [:subject, :preview], &Map.delete(&1, :proof))},
        {"p6", put_in(grant(ctx, "p6"), [:subject, :preview, :origins], [])},
        # No preview for a plan that is not unresolved.
        {"p7", put_in(grant(ctx, "p7"), [:subject, :preview], nil)},
        # Decisions naming an origin outside the enum.
        {"p8", put_in(grant(ctx, "p8"), [:subject, :decisions, "origins"], ["cli"])}
      ]

      for {id, bad} <- malformed do
        html = prompt(view, bad)
        assert outcome(id) == {:refused, :invalid_prompt}, id
        assert html =~ ~s(data-open="false")
      end
    end

    test "a grant whose closure is unresolved opens naming what is missing, with nothing to confirm",
         %{view: view, ctx: ctx} do
      unresolved =
        grant(ctx, "unresolved")
        |> put_in([:subject, :preview], nil)
        |> put_in([:subject, :plan, :unresolved], %{
          reason: "unresolvable_dependency",
          missing: "reagent:local.absent"
        })

      html = prompt(view, unresolved)
      assert html =~ ~s(data-prompt-id="unresolved")
      assert has_element?(view, ~s([data-test="grant-unresolved"]), "reagent:local.absent")
      refute has_element?(view, ~s([data-test="grant-rows"]))
      assert has_element?(view, ~s(button[phx-click="confirm"][disabled]))
    end
  end

  describe "a second prompt" do
    setup :signed_in

    test "waits behind the open one in arrival order and never replaces it", %{
      view: view,
      ctx: ctx
    } do
      prompt(view, sign_in("first"))
      prompt(view, grant(ctx, "second"))
      html = prompt(view, credential("third", "queued-entry"))

      assert open_prompt(view) == "first"
      assert html =~ "2 more prompts are waiting."

      # A dismissal meant for a waiting prompt does not act on the open one.
      view |> layer() |> render_click("dismiss", %{"id" => "second"})
      assert open_prompt(view) == "first"
      no_outcome("second")

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("first") == :dismissed
      assert open_prompt(view) == "second"

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("second") == :dismissed
      assert open_prompt(view) == "third"
    end

    test "the same prompt sent twice is taken once", %{view: view} do
      prompt(view, sign_in("once"))
      html = prompt(view, sign_in("once"))

      refute html =~ "waiting"
      no_outcome("once")
    end

    test "clearing the open prompt shows the next one and reports nothing", %{view: view} do
      prompt(view, sign_in("a"))
      prompt(view, sign_in("b"))
      prompt(view, nil)

      assert open_prompt(view) == "b"
      no_outcome("a")
    end
  end

  describe "sign-in" do
    setup :signed_in

    test "confirming leaves for the sign-in page", %{view: view} do
      prompt(view, sign_in("s1"))

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element(~s(button[phx-click="confirm"])) |> render_click()
    end
  end

  # ---------------------------------------------------------------------------
  # Credential entry
  # ---------------------------------------------------------------------------

  describe "credential entry" do
    setup :signed_in

    # Entering a credential is a sensitive change: the entry waits on its
    # record, the person proves it with a passkey here, the browser types
    # the value again once the record reads confirmed, and the value goes
    # to the vault and nowhere else.
    test "the value goes to the vault and nowhere else, once its record is confirmed",
         %{view: view, ctx: ctx, user: user} do
      authenticator = Sanctum.TestContext.passkey!(user.user_id)
      name = "system-layer-#{System.unique_integer([:positive])}"
      secret = "sk-system-layer-#{System.unique_integer([:positive])}-sentinel"

      html = prompt(view, credential("c1", name))

      assert has_element?(
               view,
               ~s(input#system-layer-secret[type="password"][autocomplete="off"][name="secret"])
             )

      assert has_element?(view, ~s(label[for="system-layer-secret"]), "API_KEY for #{name}")
      assert has_element?(view, ~s(button[type="submit"][form="system-layer-credential"]))
      refute html =~ secret

      # Where the value may go is asked, with nothing prefilled, and the
      # app reading it is off until the person turns it on.
      assert has_element?(view, ~s(input[name="destination_hosts"][required]))
      refute has_element?(view, ~s(input[name="destination_hosts"][value]))
      assert has_element?(view, ~s(input[type="checkbox"][name="disclose"]))
      refute has_element?(view, ~s(input[type="checkbox"][name="disclose"][checked]))

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {id, log} =
        with_log([level: :debug], fn ->
          view
          |> form("#system-layer-credential", %{
            "secret" => secret,
            "destination_hosts" => "API.example.com"
          })
          |> render_submit()

          # The prompt stays, waiting on its record, and reports nothing.
          no_outcome("c1")
          assert open_prompt(view) == "c1"
          held_secret(view)
        end)

      # The page shows the change waiting, with the home's preview and this
      # client as the asker, never the request's secret or the value.
      html = render(view)
      assert html =~ ~s(data-status="waiting")
      assert html =~ ~s(data-own="true")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), name)
      assert has_element?(view, ~s([data-test="confirmation-asker"]), "a browser signed in")
      refute html =~ id
      refute log =~ id
      refute html =~ secret

      # The asking submission was logged, with the value under its redacted
      # name, and the value nowhere.
      assert log =~ ~s("secret" => "[FILTERED]")
      refute log =~ secret

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               secret

      # Nothing sealed; the open record binds the change by its keyed
      # digest and names the entry, never the value.
      {:ok, entries} = Sanctum.Vault.list(ctx)
      refute Enum.any?(entries, &(&1.name == name))

      assert {:ok, [%{ref: ref} = record]} =
               Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

      assert ref == Prima.Confirmation.ref(id)
      refute inspect(record, limit: :infinity, printable_limit: :infinity) =~ secret
      refute inspect(record, limit: :infinity, printable_limit: :infinity) =~ id

      # The person proves it here with a passkey, over the record's digest,
      # naming it by its ref.
      prove_here!(view, ref, authenticator)

      # The record reads confirmed: approved, and the browser is asked to
      # type the value again, which it still holds.
      assert_push_event(view, "system_layer:resubmit", %{form: "system-layer-credential"}, 2_000)
      assert render(view) =~ ~s(data-status="approved")

      # A fact delivered again repeats nothing: the change is made once.
      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      Sanctum.Consent.Authz.announce(:confirmed, row)
      refute_push_event(view, "system_layer:resubmit", _again, 200)

      log =
        capture_log([level: :debug], fn ->
          view
          |> form("#system-layer-credential", %{
            "secret" => secret,
            "destination_hosts" => "API.example.com"
          })
          |> render_submit()

          assert outcome("c1") == :confirmed
          render(view)
        end)

      Logger.configure(level: previous)

      # The event was logged, with the value under its redacted name.
      assert log =~ ~s("secret" => "[FILTERED]")
      refute log =~ secret
      refute log =~ id
      assert open_prompt(view) == nil
      refute render(view) =~ secret

      {:ok, entries} = Sanctum.Vault.list(ctx)
      assert %{field_names: ["API_KEY"]} = entry = Enum.find(entries, &(&1.name == name))

      # Bound where the person said, and attach-only: they did not let the
      # app read it.
      assert entry.destination == %{"hosts" => ["api.example.com"], "scheme" => "https"}
      assert entry.attach_only == true

      # The secret reached no request-log row or decision.
      refute logged() =~ id
      refute logged() =~ secret
      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    end

    test "a repeat before the proof keeps waiting on the same record", %{view: view, ctx: ctx} do
      name = "system-layer-early-#{System.unique_integer([:positive])}"
      prompt(view, credential("c3", name))

      submit = fn ->
        view
        |> form("#system-layer-credential", %{
          "secret" => "sk-early",
          "destination_hosts" => "api.example.com"
        })
        |> render_submit()
      end

      submit.()
      id = held_secret(view)

      # Submitted again before anyone proved it: the same record, still
      # waiting, and nothing new opened.
      submit.()
      assert held_secret(view) == id
      assert render(view) =~ ~s(data-status="waiting")

      assert {:ok, [_one]} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
      no_outcome("c3")
    end

    test "a request cancelled from its prompt ends the wait and says so", %{view: view, ctx: ctx} do
      prompt(view, credential("c4", "system-layer-cancel-#{System.unique_integer([:positive])}"))

      view
      |> form("#system-layer-credential", %{
        "secret" => "sk-cancel",
        "destination_hosts" => "api.example.com"
      })
      |> render_submit()

      ref = Prima.Confirmation.ref(held_secret(view))

      view |> element(~s([data-test="confirm-cancel"])) |> render_click()

      wait_until(
        fn -> render(view) =~ ~s(data-status="cancelled") end,
        2_000,
        "the cancelled fact"
      )

      assert render(view) =~ "Cancelled. Nothing was changed."
      assert {:ok, %{state: "cancelled"}} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      end_views()
    end

    test "an empty value is asked for again and dispatches nothing", %{view: view} do
      prompt(view, credential("c2", "empty-entry"))

      html = view |> form("#system-layer-credential", %{"secret" => "   "}) |> render_submit()

      assert html =~ "Enter the credential to save it."
      assert open_prompt(view) == "c2"
      no_outcome("c2")
    end

    test "a value with no host to go to is asked for again and dispatches nothing",
         %{view: view, ctx: ctx} do
      name = "no-host-entry-#{System.unique_integer([:positive])}"
      prompt(view, credential("c5", name))

      html =
        view
        |> form("#system-layer-credential", %{
          "secret" => "sk-nowhere",
          "destination_hosts" => " "
        })
        |> render_submit()

      assert html =~ "Name the host the credential may be sent to."
      refute html =~ "sk-nowhere"
      assert open_prompt(view) == "c5"
      no_outcome("c5")
      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    end

    test "the form's destination is what the person typed, and disclosure only an explicit yes" do
      assert PrismWeb.SystemLayer.destination_params(%{
               "destination_hosts" => "API.example.com, *.cdn.example.com\nother.example",
               "destination_scheme" => "http",
               "destination_port" => " 8443 ",
               "destination_methods" => "get post",
               "destination_paths" => "/v1/ /v2/"
             }) == %{
               "hosts" => ["api.example.com", "*.cdn.example.com", "other.example"],
               "scheme" => "http",
               "port" => 8443,
               "methods" => ["GET", "POST"],
               "paths" => ["/v1/", "/v2/"]
             }

      # Nothing named is nothing sent, and https unless http is chosen; a
      # port that is not a number goes as typed, for the vault to refuse.
      assert PrismWeb.SystemLayer.destination_params(%{}) == %{"hosts" => [], "scheme" => "https"}

      assert %{"port" => "eighty"} =
               PrismWeb.SystemLayer.destination_params(%{
                 "destination_hosts" => "api.example.com",
                 "destination_port" => "eighty"
               })

      assert PrismWeb.SystemLayer.disclose_param(%{"disclose" => "true"})
      assert PrismWeb.SystemLayer.disclose_param(%{"disclose" => "on"})
      refute PrismWeb.SystemLayer.disclose_param(%{"disclose" => "false"})
      refute PrismWeb.SystemLayer.disclose_param(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # An instance entry's value
  # ---------------------------------------------------------------------------

  describe "an instance entry's value" do
    setup :signed_in_admin

    @instance_destination %{
      "hosts" => ["api.example.com"],
      "scheme" => "https",
      "methods" => ["GET", "POST"],
      "paths" => ["/v1/chat/completions", "/v1/models"]
    }

    # What the administrator's card collected for a new entry: everything
    # but the value.
    defp instance_arguments(name, over \\ %{}) do
      Map.merge(
        %{
          "name" => name,
          "kind" => "api_key",
          "provider_hint" => "example.com",
          "destination" => @instance_destination,
          "component_policy" => "shipped",
          "audience" => "everyone",
          "members" => []
        },
        over
      )
    end

    defp instance_value(id, name, operation, arguments, field \\ "API_KEY") do
      %{
        id: id,
        kind: :credential_entry,
        action: :credential_entry,
        subject: %{
          name: name,
          field: field,
          target: :instance,
          operation: operation,
          arguments: arguments
        }
      }
    end

    defp instance_entry(name) do
      {:ok, entries} = Arca.InstanceEntries.list(Prima.Actor.system())
      Enum.find(entries, &(&1.name == name))
    end

    test "the key goes to instance_entry.create with the card's arguments, once its record " <>
           "is confirmed, and is held nowhere",
         %{view: view, ctx: ctx, user: user} do
      authenticator = Sanctum.TestContext.passkey!(user.user_id)
      name = "instance-layer-#{System.unique_integer([:positive])}"
      secret = "sk-instance-layer-#{System.unique_integer([:positive])}-sentinel"

      html = prompt(view, instance_value("ie1", name, :create, instance_arguments(name)))

      # The value alone is asked: the card named where it goes, and an
      # instance entry is never disclosed.
      assert has_element?(view, ~s(form#system-layer-credential[data-target="instance"]))
      assert has_element?(view, ~s(input#system-layer-secret[type="password"][name="secret"]))
      refute has_element?(view, ~s(input[name="destination_hosts"]))
      refute has_element?(view, ~s(input[name="disclose"]))
      assert html =~ "Enter the key for the instance entry #{name}"

      assert has_element?(
               view,
               ~s([data-test="credential-attach"]),
               "CYFR attaches it to requests bound for the entry's destination"
             )

      assert has_element?(
               view,
               ~s(button[form="system-layer-credential"]),
               "Save to this instance"
             )

      submit = fn ->
        view |> form("#system-layer-credential", %{"secret" => secret}) |> render_submit()
      end

      submit.()

      # Waiting on its record: nothing created, and the value nowhere.
      no_outcome("ie1")
      assert render(view) =~ ~s(data-status="waiting")
      assert instance_entry(name) == nil

      assert {:ok, [%{ref: ref, operation: "instance_entry.create"}]} =
               Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               secret

      prove_here!(view, ref, authenticator)
      assert_push_event(view, "system_layer:resubmit", %{form: "system-layer-credential"}, 2_000)

      submit.()
      assert outcome("ie1") == :confirmed
      assert open_prompt(view) == nil

      entry = instance_entry(name)
      assert entry.provider_hint == "example.com"
      assert entry.component_policy == "shipped"
      assert entry.audience == "everyone"
      assert entry.attach_only == true
      assert Jason.decode!(entry.field_names) == ["API_KEY"]
      assert Jason.decode!(entry.destination) == @instance_destination

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               secret

      refute render(view) =~ secret
      refute logged() =~ secret
    end

    test "a rotation's key goes to instance_entry.rotate of the entry the card named, " <>
           "under its own confirmation",
         %{view: view, ctx: ctx, user: user} do
      authenticator = Sanctum.TestContext.passkey!(user.user_id)
      name = "instance-rotate-#{System.unique_integer([:positive])}"

      params = %{
        name: name,
        kind: "api_key",
        provider_hint: "example.com",
        fields: %{"API_KEY" => "sk-first"},
        destination: @instance_destination,
        audience: "everyone"
      }

      admin =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "instance_entry.create",
          arguments: params,
          resource: name
        })

      {:ok, created} = Sanctum.InstanceEntries.create(admin, params)
      arguments = %{"entry_id" => created.id, "expected_payload_rev" => created.payload_rev}

      prompt(view, instance_value("ie2", name, :rotate, arguments))
      assert render(view) =~ "Rotate the instance entry #{name}"

      submit = fn ->
        view |> form("#system-layer-credential", %{"secret" => "sk-rotated"}) |> render_submit()
      end

      submit.()

      assert {:ok, [%{ref: ref, operation: "instance_entry.rotate"}]} =
               Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

      assert instance_entry(name).payload_rev == created.payload_rev

      prove_here!(view, ref, authenticator)
      assert_push_event(view, "system_layer:resubmit", %{form: "system-layer-credential"}, 2_000)
      submit.()

      assert outcome("ie2") == :confirmed
      assert instance_entry(name).payload_rev == created.payload_rev + 1
    end

    test "an empty key is asked for again and dispatches nothing", %{view: view, ctx: ctx} do
      name = "instance-empty-#{System.unique_integer([:positive])}"
      prompt(view, instance_value("ie3", name, :create, instance_arguments(name)))

      html = view |> form("#system-layer-credential", %{"secret" => " "}) |> render_submit()

      assert html =~ "Enter the credential to save it."
      no_outcome("ie3")
      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    end

    test "a subject that carries a value, names another operation or mixes in a grant's " <>
           "prefill is no prompt" do
      valid = instance_value("v", "n", :create, instance_arguments("n"))
      assert {:ok, %{subject: %{target: :instance, operation: :create}}} = Prompt.validate(valid)

      rotate =
        instance_value("v", "n", :rotate, %{"entry_id" => "ine_1", "expected_payload_rev" => 0})

      assert {:ok, %{subject: %{operation: :rotate}}} = Prompt.validate(rotate)

      for subject <- [
            %{
              valid.subject
              | arguments: Map.put(instance_arguments("n"), "fields", %{"K" => "v"})
            },
            %{valid.subject | arguments: Map.put(instance_arguments("n"), "secret", "v")},
            %{valid.subject | arguments: Map.delete(instance_arguments("n"), "name")},
            %{valid.subject | operation: :delete},
            %{valid.subject | target: :elsewhere},
            Map.put(valid.subject, :athanor_id, "ath_1"),
            %{rotate.subject | arguments: %{"entry_id" => "ine_1"}},
            %{rotate.subject | arguments: %{"entry_id" => "ine_1", "expected_payload_rev" => -1}},
            Map.delete(valid.subject, :arguments)
          ] do
        assert {:error, :invalid_prompt} = Prompt.validate(%{valid | subject: subject}),
               inspect(subject)
      end

      # Naming the vault, or nothing, is the vault's prompt as before.
      vault = %{
        id: "v",
        kind: :credential_entry,
        action: :credential_entry,
        subject: %{name: "n"}
      }

      assert {:ok, %{subject: %{name: "n", field: "API_KEY"}}} = Prompt.validate(vault)

      assert {:ok, %{subject: %{target: :vault}}} =
               Prompt.validate(put_in(vault.subject[:target], :vault))
    end
  end

  # ---------------------------------------------------------------------------
  # A confirmation another client asked for
  # ---------------------------------------------------------------------------

  describe "a confirmation another client of the person asked for" do
    setup :signed_in

    test "opens on every client from the stream, shows the preview and the asker before the proof, and is confirmed by its ref",
         %{view: view, ctx: ctx, user: user} do
      authenticator = Sanctum.TestContext.passkey!(user.user_id)
      other = other_session!(ctx)
      name = "asked-elsewhere-#{System.unique_integer([:positive])}"

      args = %{
        "name" => name,
        "kind" => "api_key",
        "fields" => %{"KEY" => "sk-elsewhere"},
        "destination" => %{"hosts" => ["api.example.com"]}
      }

      # Another session of the person asks; it alone holds the secret.
      assert {:error, {:confirmation_required, %{id: id}}} =
               PrismWeb.Ops.call_tool(other, "vault/create", args)

      ref = Prima.Confirmation.ref(id)
      prompt_id = Prompt.confirmation_id(ref)
      wait_until(fn -> open_prompt(view) == prompt_id end, 2_000, "the opened fact")

      # Before any proof: what it would change, where, and which client
      # asked; this client did not.
      html = render(view)
      assert html =~ ~s(data-kind="confirmation")
      assert html =~ ~s(data-own="false")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), "vault.create")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), name)
      assert has_element?(view, ~s([data-test="confirmation-asker"]), "a browser signed in")
      assert has_element?(view, ~s([data-test="confirm-passkey"]))
      refute html =~ id
      refute html =~ "sk-elsewhere"

      prove_here!(view, ref, authenticator)
      wait_until(fn -> render(view) =~ ~s(data-status="confirmed") end, 2_000, "confirmed")

      # The asker repeats under its secret; the record is consumed and the
      # prompt here goes.
      assert {:ok, _entry} =
               PrismWeb.Ops.call_tool(other, "vault/create", args, confirmation_id: id)

      wait_until(fn -> open_prompt(view) == nil end, 2_000, "the consumed fact")
      no_outcome(prompt_id)
      end_views()
    end

    test "an assertion that does not prove the record is refused, and the prompt still waits",
         %{view: view, ctx: ctx} do
      other = other_session!(ctx)

      assert {:error, {:confirmation_required, %{id: id}}} =
               PrismWeb.Ops.call_tool(other, "vault/create", %{
                 "name" => "ref-alone-#{System.unique_integer([:positive])}",
                 "kind" => "api_key",
                 "fields" => %{"KEY" => "x"},
                 "destination" => %{"hosts" => ["api.example.com"]}
               })

      ref = Prima.Confirmation.ref(id)
      wait_until(fn -> open_prompt(view) == Prompt.confirmation_id(ref) end, 2_000, "opened")

      # An assertion this person's passkey never made is refused, and the
      # prompt says so.
      view
      |> layer()
      |> render_hook("webauthn_result", %{
        "purpose" => "confirmation",
        "id" => ref,
        "credential" => %{"id" => "nobody", "response" => %{}}
      })

      assert render(view) =~ ~s(role="alert")
      assert render(view) =~ ~s(data-status="pending")
      end_views()
    end
  end

  describe "a record pending before the layer listened" do
    test "is shown as the layer mounts, with its preview and the client that asked",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      other = other_session!(person_context(user, athanor))
      name = "asked-before-#{System.unique_integer([:positive])}"

      # Asked, and announced, before any layer of this person listened.
      assert {:error, {:confirmation_required, %{id: id}}} =
               PrismWeb.Ops.call_tool(other, "vault/create", %{
                 "name" => name,
                 "kind" => "api_key",
                 "fields" => %{"KEY" => "sk-before"},
                 "destination" => %{"hosts" => ["api.example.com"]}
               })

      {:ok, view, _html} =
        live_isolated(conn, Host, session: %{"athanor_id" => athanor.id, "test" => self()})

      ref = Prima.Confirmation.ref(id)
      assert open_prompt(view) == Prompt.confirmation_id(ref)
      html = render(view)
      assert html =~ ~s(data-own="false")
      assert html =~ ~s(data-status="pending")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), name)
      assert has_element?(view, ~s([data-test="confirmation-asker"]), "a browser signed in")
      refute html =~ id
      end_views()
    end
  end

  describe "while the store cannot answer" do
    test "a safe-mode prompt is drawn, and trying again is reported", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      built = person_context(user, athanor)
      {:ok, session} = Sanctum.TestContext.create_session(%{built | provider: "github"})

      {:ok, ctx} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      safe = %{id: "safe-outage", kind: :safe_mode, action: nil, subject: safe_mode(ctx)}

      {:ok, view, _html} =
        live_isolated(conn, BareHost, session: %{"context" => ctx, "test" => self()})

      # Every context is revalidated, and the sessions it is read from are
      # gone for the moment.
      bound = Application.get_env(:sanctum, :caller_memo_ttl_ms)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 0)
      on_exit(fn -> restore_env(:sanctum, :caller_memo_ttl_ms, bound) end)
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")
      assert CyfrWeb.ContextGuard.check(ctx) == {:error, :unavailable}

      html = prompt(view, safe)
      assert html =~ ~s(data-kind="safe_mode")
      assert html =~ "Your desktop stopped working."
      assert open_prompt(view) == "safe-outage"

      view |> element(~s(button[phx-value-offer="retry"])) |> render_click()
      assert outcome("safe-outage") == :confirmed
      assert open_prompt(view) == nil
    end
  end

  describe "a confirmation prompt on a client with no person behind it" do
    setup :none_client

    test "shows the record and no confirm control", %{view: view} do
      ref = Prima.Confirmation.ref("cnf_" <> String.duplicate("A", 43))

      {:ok, confirmation} =
        Prompt.confirmation(
          %{
            ref: ref,
            operation: "vault.create",
            action: "credential_entry",
            preview: %{
              "home" => "https://home.example",
              "athanor" => "Home",
              "operation" => "vault.create"
            },
            asker: %{"kind" => "session", "name" => "github"},
            expires_at: DateTime.add(DateTime.utc_now(), 300),
            webauthn: %{"challenge" => "AAAA"},
            methods: ["passkey", "oidc", "email"]
          },
          false
        )

      html = prompt(view, confirmation)

      assert html =~ ~s(data-kind="confirmation")
      assert html =~ ~s(data-standing="none")
      assert has_element?(view, ~s([data-test="confirmation-preview"]), "vault.create")
      refute has_element?(view, ~s([data-test="confirm-passkey"]))
      refute has_element?(view, ~s([data-test="confirm-reauth"]))
      refute has_element?(view, ~s([data-test="confirm-email"]))
    end
  end

  # ---------------------------------------------------------------------------
  # Safe mode
  # ---------------------------------------------------------------------------

  describe "safe mode" do
    setup :signed_in

    defp arranged(ctx, desktop, revision) do
      document = %{
        "version" => 1,
        "postures" => %{
          "desk" => %{
            "desktop" => desktop,
            "slots" => [
              %{
                "id" => "vault",
                "tincture" => "tincture:local.vault",
                "size" => "icon",
                "order" => 0
              }
            ],
            "floating" => []
          }
        }
      }

      {:ok, %{revision: published}} =
        Compendium.Providers.Layout.handle("layout", ctx, %{
          "action" => "edit",
          "document" => document,
          "revision" => revision
        })

      published
    end

    defp safe_mode(ctx) do
      {:ok, read} = Compendium.layout(ctx, "desk")
      Prism.SafeMode.enter(:crashed, read)
    end

    defp desk(ctx) do
      {:ok, read} = Compendium.layout(ctx, "desk")
      {read.arrangement, read.revision}
    end

    test "offers trying again and the default, as a non-modal alert with no dismissal", %{
      view: view,
      ctx: ctx
    } do
      arranged(ctx, "tincture:acme.broken-desk", 0)
      html = prompt(view, %{id: "safe", kind: :safe_mode, action: nil, subject: safe_mode(ctx)})

      assert html =~ ~s(role="alertdialog")
      assert html =~ ~s(popover="manual")
      assert html =~ ~s(data-dismissable="false")
      assert html =~ ~s(data-mode="popover")
      assert html =~ "Your desktop stopped working."
      assert html =~ "No app runs while safe mode is on."

      assert has_element?(
               view,
               ~s(button[phx-click="choose"][phx-value-offer="retry"]),
               "Try again"
             )

      assert has_element?(
               view,
               ~s(button[phx-click="choose"][phx-value-offer="default"]),
               "Use the default desktop"
             )

      refute has_element?(view, ~s([phx-click="dismiss"]))

      # Escape reaches the layer as a dismissal, which safe mode refuses.
      view |> layer() |> render_click("dismiss", %{"id" => "safe"})
      assert open_prompt(view) == "safe"
      no_outcome("safe")
    end

    test "choosing the default publishes it through layout.edit", %{view: view, ctx: ctx} do
      revision = arranged(ctx, "tincture:acme.broken-desk", 0)
      prompt(view, %{id: "safe", kind: :safe_mode, action: nil, subject: safe_mode(ctx)})

      view |> element(~s(button[phx-value-offer="default"])) |> render_click()

      assert outcome("safe") == :confirmed
      assert open_prompt(view) == nil

      {arrangement, published} = desk(ctx)
      assert arrangement.desktop == "tincture:local.desktop"
      assert [%{id: "vault"}] = arrangement.slots
      assert published == revision + 1
    end

    test "a layout published since safe mode opened is reported and nothing is merged", %{
      view: view,
      ctx: ctx
    } do
      revision = arranged(ctx, "tincture:acme.broken-desk", 0)
      safe_mode = safe_mode(ctx)
      newer = arranged(ctx, "tincture:acme.other-desk", revision)

      prompt(view, %{id: "safe", kind: :safe_mode, action: nil, subject: safe_mode})
      html = view |> element(~s(button[phx-value-offer="default"])) |> render_click()

      assert {:refused, _reason} = outcome("safe")
      assert html =~ "Your layout changed since safe mode opened, so nothing was changed."
      assert open_prompt(view) == "safe"

      {arrangement, published} = desk(ctx)
      assert arrangement.desktop == "tincture:acme.other-desk"
      assert published == newer

      view |> element(~s(button[phx-value-offer="retry"])) |> render_click()
      assert outcome("safe") == :confirmed
    end
  end
end
