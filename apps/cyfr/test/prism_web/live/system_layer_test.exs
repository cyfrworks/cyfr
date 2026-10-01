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

defmodule PrismWeb.SystemLayerTest do
  @moduledoc """
  The system layer presents a prompt and never decides it: it shows no
  confirm control to a client with no person behind it, dispatches the
  same operations the consent sheet and the vault page dispatch through
  the gate, so the operation decides every confirmation that arrives,
  reports each outcome to its parent, a refusal and the confirmation
  signal as their sentences, queues a second prompt behind the open one,
  keeps a typed credential out of the page, the socket and the logs, and
  offers safe mode's ways out with no dismissal.

  Each test mounts the layer the way the shell does, in a small host view
  that forwards what the layer tells its parent to the test.
  """

  use PrismWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PrismWeb.SystemLayerTest.{BareHost, Host}
  alias Sanctum.Context

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

  defp grant(id, attrs \\ %{}) do
    ref = "tincture:local.system-layer-probe"

    Map.merge(
      %{
        id: id,
        kind: :grant,
        action: :grant,
        subject: %{
          ref: ref,
          plan: %{plan_token: "not-a-plan-token", expected_consent_revision: 0},
          preview: %{
            summary: ["Talks to api.example.com", "Keeps its own private storage"],
            proof: "not-a-proof",
            commit_digest: "sha256:" <> String.duplicate("0", 64)
          },
          decisions: %{"ref" => ref, "bindings" => []}
        }
      },
      attrs
    )
  end

  defp sign_in(id), do: %{id: id, kind: :sign_in, action: nil, subject: %{}}

  defp credential(id, name),
    do: %{id: id, kind: :credential_entry, action: :credential_entry, subject: %{name: name}}

  defp outcome(id) do
    assert_receive {:host, {:system_layer, ^id, outcome}}
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

    test "a prompt is a labelled, described modal dialog with real buttons", %{view: view} do
      html = prompt(view, grant("g1"))

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="system-layer-title")
      assert html =~ ~s(aria-describedby="system-layer-description")
      assert html =~ ~s(id="system-layer-title")
      assert html =~ ~s(id="system-layer-description")
      assert html =~ ~s(data-open="true")
      assert html =~ ~s(data-dismissable="true")
      assert html =~ "Talks to api.example.com"

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
      view: view
    } do
      for action <- Sanctum.Pairing.actions() do
        id = "act-#{action}"
        html = prompt(view, grant(id, %{action: action}))

        assert has_element?(view, ~s(button[phx-click="confirm"]), "Grant"), inspect(action)
        refute html =~ ~s(data-standing="none")

        view |> element(~s(button[phx-click="dismiss"])) |> render_click()
        assert outcome(id) == :dismissed
      end
    end

    test "a confirmation is decided by the operation it dispatches, not by the layer", %{
      view: view
    } do
      # A sensitive action: the layer dispatches it like any other, and
      # the commit, not the layer, refuses the stale plan token.
      prompt(view, grant("sensitive", %{action: :home_transfer}))

      html = view |> element(~s(button[phx-click="confirm"])) |> render_click()

      assert {:refused, reason} = outcome("sensitive")
      sentence = reason |> PrismWeb.Ops.error_message() |> Phoenix.HTML.html_escape()
      assert html =~ Phoenix.HTML.safe_to_string(sentence)
      assert open_prompt(view) == "sensitive"
    end
  end

  describe "a client with no person behind it" do
    setup :none_client

    test "is shown no confirm control and told where to confirm", %{view: view} do
      html = prompt(view, grant("n1"))

      refute has_element?(view, ~s([phx-click="confirm"]))
      assert html =~ ~s(data-standing="none")
      assert html =~ "Confirm it from a"
      assert html =~ "signed-in browser."
    end

    test "a confirmation sent anyway is dispatched, and the operation refuses it", %{view: view} do
      prompt(view, grant("n2"))

      html = view |> layer() |> render_click("confirm", %{"id" => "n2"})

      assert {:refused, reason} = outcome("n2")
      sentence = reason |> PrismWeb.Ops.error_message() |> Phoenix.HTML.html_escape()
      assert html =~ Phoenix.HTML.safe_to_string(sentence)
      assert open_prompt(view) == "n2"
    end

    test "is offered no credential input, and a sent credential is refused by the vault", %{
      view: view,
      ctx: ctx
    } do
      name = "none-client-entry-#{System.unique_integer([:positive])}"
      prompt(view, credential("n3", name))

      refute has_element?(view, ~s(input[type="password"]))

      view
      |> layer()
      |> render_submit("enter_credential", %{"prompt_id" => "n3", "secret" => "sk-none"})

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

    test "shows the refusal's sentence, reports it, and stays dismissable", %{view: view} do
      prompt(view, grant("g-refused"))

      html = view |> element(~s(button[phx-click="confirm"])) |> render_click()

      assert {:refused, reason} = outcome("g-refused")
      assert html =~ ~s(role="alert")
      sentence = reason |> PrismWeb.Ops.error_message() |> Phoenix.HTML.html_escape()
      assert html =~ Phoenix.HTML.safe_to_string(sentence)
      assert open_prompt(view) == "g-refused"

      view |> element(~s(button[phx-click="dismiss"])) |> render_click()
      assert outcome("g-refused") == :dismissed
    end
  end

  describe "a malformed prompt" do
    setup :signed_in

    test "is not drawn and is refused as :invalid_prompt", %{view: view} do
      malformed = [
        {"m1", %{id: "m1", kind: :grant, action: :grant, subject: %{}}},
        {"m2", %{id: "m2", kind: :teleport, action: nil, subject: %{}}},
        {"m3", %{id: "m3", kind: :sign_in, action: :grant, subject: %{}}},
        {"m4", %{id: "m4", kind: :grant, action: :everything, subject: grant("x").subject}},
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
  end

  describe "a second prompt" do
    setup :signed_in

    test "waits behind the open one in arrival order and never replaces it", %{view: view} do
      prompt(view, sign_in("first"))
      prompt(view, grant("second"))
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

    # Entering a credential is a sensitive change: from a session with no
    # proof, the entry meets the `confirmation_required` signal, the
    # prompt stays open showing it, and the value reaches neither the
    # vault nor the page, its state, the log or the confirmation record.
    test "the value meets the confirmation signal and goes nowhere else",
         %{view: view, ctx: ctx} do
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

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {id, log} =
        with_log([level: :debug], fn ->
          view
          |> form("#system-layer-credential", %{"secret" => secret})
          |> render_submit()

          assert {:refused, {:confirmation_required, %{id: id, operation: "vault.create"}}} =
                   outcome("c1")

          render(view)
          id
        end)

      Logger.configure(level: previous)

      # The page shows the change waiting, never the request's secret.
      html = render(view)
      assert html =~ "Confirmation required"
      refute html =~ id
      refute log =~ id
      refute html =~ secret

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               secret

      # The event was logged, with the value under its redacted name.
      assert log =~ ~s("secret" => "[FILTERED]")
      refute log =~ secret
      assert open_prompt(view) == "c1"

      # Nothing sealed; the open record binds the change by its keyed
      # digest and names the entry, never the value.
      {:ok, entries} = Sanctum.Vault.list(ctx)
      refute Enum.any?(entries, &(&1.name == name))

      assert {:ok, [%{ref: ref} = record]} =
               Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

      assert ref == Prima.Confirmation.ref(id)
      refute inspect(record, limit: :infinity, printable_limit: :infinity) =~ secret
      refute inspect(record, limit: :infinity, printable_limit: :infinity) =~ id
    end

    test "an empty value is asked for again and dispatches nothing", %{view: view} do
      prompt(view, credential("c2", "empty-entry"))

      html = view |> form("#system-layer-credential", %{"secret" => "   "}) |> render_submit()

      assert html =~ "Enter the credential to save it."
      assert open_prompt(view) == "c2"
      no_outcome("c2")
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
