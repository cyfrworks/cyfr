# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerRecoveryTest.Host do
  @moduledoc false
  # A page mounted through the context guard, holding the layer as a
  # settings page does, and forwarding what the layer tells it.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, test: session["test"], listen: Map.get(session, "listen", true))}

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
    <.live_component
      module={PrismWeb.SystemLayer}
      id="system-layer"
      context={@context}
      listen={@listen}
    />
    """
  end
end

defmodule PrismWeb.SystemLayerRecoveryTest do
  @moduledoc """
  The system layer's recovery prompts: enrollment, a printed kit again,
  and another printed kit, each drawn only in the layer and each change
  confirmed fresh where Sanctum decides it.

  The material never rests on the server: the browser submits a seed it
  drew and holds, the layer dispatches it and keeps none of it, the
  browser submits the same once the record is confirmed, and a kit's
  lines go to the browser in a push to the layer alone, never an assign,
  a rendered page or a log. The acknowledgment erases the seed at the
  home, and the end of a prompt, however it ends, has the browser forget
  what it held. A prompt never names a seed, and a frame never reaches
  any of it.

  After a declared restore the layer draws the person's restore
  checklist: what the restore suspended, each with its re-enable control
  where the page reaches it, the profiles to consent to again and the
  entries to rotate. A re-enable is the layer's own sensitive change,
  confirmed while the recovery is open by a door or an emailed code and
  never by a passkey, and made again by the layer once confirmed.

  The directory is a scripted one this home reaches through the client's
  test seam (`Sanctum.Test.DirectoryServer`).
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Arca.Schemas.IdentityAttempt
  alias Prima.Identity
  alias Prima.Identity.Encoding
  alias PrismWeb.SystemLayer.{Prompt, Recovery}
  alias PrismWeb.SystemLayerRecoveryTest.Host
  alias Sanctum.Context
  alias Sanctum.Test.DirectoryServer, as: Directory
  alias Sanctum.TestContext.{Authenticator, MailSink}

  setup_all do
    %{tls: Directory.tls()}
  end

  setup %{tls: tls} do
    Directory.listen!()
    Directory.seam!(tls)
    directory = Directory.start!(tls)
    prior = Application.fetch_env(:sanctum, :directory_url)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:sanctum, :directory_url, value)
        :error -> Application.delete_env(:sanctum, :directory_url)
      end
    end)

    Application.put_env(:sanctum, :directory_url, directory.url)
    %{directory: directory}
  end

  # ---- fixtures ------------------------------------------------------------------

  defp signed_in(%{conn: conn}) do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"athanor_id" => athanor.id, "test" => self()})

    # Another session of the same person, established as a request
    # establishes one: what a change made outside the page is made under.
    built =
      Context.build(
        user_id: user.user_id,
        provider: "github",
        athanor_id: athanor.id,
        permissions: Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    %{view: view, ctx: ctx, user: user, authenticator: Sanctum.TestContext.passkey!(user.user_id)}
  end

  defp prompt(view, prompt) do
    send(view.pid, {:prompt, prompt})
    render(view)
    render(view)
  end

  defp layer(view), do: with_target(view, "#system-layer")

  defp seed, do: Encoding.b64(:crypto.strong_rand_bytes(32))
  defp request_id, do: "req_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp state_of(view),
    do: inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

  defp held_secret(view) do
    [secret] = Regex.run(~r/cnf_[A-Za-z0-9_-]{43}/, state_of(view))
    secret
  end

  defp prove_here!(view, ref, authenticator) do
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()

    assert_push_event(view, "webauthn:get", %{
      layer: "system-layer",
      purpose: "confirmation",
      id: ^ref,
      public_key: %{"challenge" => challenge}
    })

    {:ok, digest} = Encoding.unb64(challenge, 32)

    view
    |> layer()
    |> render_hook("webauthn_result", %{
      "purpose" => "confirmation",
      "id" => ref,
      "credential" => Authenticator.assertion(authenticator, digest)
    })
  end

  defp outcome(id) do
    assert_receive {:host, {:system_layer, ^id, outcome}}, 2_000
    outcome
  end

  defp open_prompt(view) do
    case Regex.run(~r/data-prompt-id="([^"]+)"/, render(view)) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp logged do
    inspect(
      {Arca.Repo.all(from(l in Arca.Schemas.McpLog, select: {l.input, l.output, l.error})),
       Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, select: {d.reason, d.tool, d.action}))},
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  defp attempts(user_id, kind) do
    Arca.Repo.all(from(a in IdentityAttempt, where: a.user_id == ^user_id and a.kind == ^kind))
  end

  defp debug_logs do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  # An enrollment the directory accepted, made as the operation makes it.
  defp enrolled!(ctx) do
    seed = seed()
    args = %{"recovery_secret" => seed, "request_id" => request_id()}

    {:ok, %{phase: "accepted", attempt_id: attempt_id, identifier: identifier}} =
      Sanctum.TestContext.confirming(ctx, &Sanctum.Recovery.enroll(&1, args))

    %{seed: seed, attempt_id: attempt_id, identifier: identifier}
  end

  # ---- the prompts' shape --------------------------------------------------------

  describe "a recovery prompt" do
    test "names no seed: enrollment the pinned https directory, a kit its attempt" do
      assert {:ok, %{kind: :enrollment, action: :recovery_material}} =
               Recovery.enrollment("r1", "https://dir.example")

      assert {:error, :invalid_prompt} = Recovery.enrollment("r1", "http://dir.example")
      assert {:error, :invalid_prompt} = Recovery.enrollment("r1", "https://dir.example?x=1")
      assert {:ok, %{subject: %{attempt_id: "att_1"}}} = Recovery.kit("r2", "att_1")
      assert {:ok, %{kind: :holder, subject: %{}}} = Recovery.holder("r3")

      for {kind, subject} <- [
            {:enrollment, %{directory_url: "https://dir.example", recovery_secret: seed()}},
            {:kit, %{attempt_id: "att_1", kit: %{recovery_secret: seed()}}},
            {:holder, %{recovery_secret: seed()}}
          ] do
        assert {:error, :invalid_prompt} =
                 Prompt.validate(%{
                   id: "r",
                   kind: kind,
                   action: :recovery_material,
                   subject: subject
                 })
      end

      # Under no other action.
      assert {:error, :invalid_prompt} =
               Prompt.validate(%{
                 id: "r",
                 kind: :kit,
                 action: :grant,
                 subject: %{attempt_id: "a"}
               })

      assert Prompt.recovery_kinds() == [:enrollment, :kit, :holder]
    end
  end

  # ---- enrollment ----------------------------------------------------------------

  describe "enrollment" do
    setup :signed_in

    test "its form says what enrolling commits to, at the pinned directory, before anything is asked",
         %{view: view, ctx: ctx, user: user, directory: directory} do
      {:ok, enrollment} = Recovery.enrollment("r1", directory.url)
      html = prompt(view, enrollment)

      assert has_element?(view, ~s([data-test="recovery"][data-kind="enrollment"]))
      assert has_element?(view, ~s([data-test="recovery-directory"]), directory.url)
      assert html =~ "cannot be reached"
      assert html =~ "If every kit is lost, nothing can add one"
      assert html =~ "never your private data or the CYFR addresses your devices saved"
      assert html =~ "no device holds recovery material"

      # The form is the browser's: no input it could submit by itself, and
      # the kit's place empty.
      assert has_element?(view, ~s(form#system-layer-recovery[data-recovery="enrollment"]))
      refute has_element?(view, ~s(form#system-layer-recovery input[name]))
      assert has_element?(view, ~s([data-recovery-kit="r1"][hidden]))

      # Nothing is asked until the browser submits.
      assert attempts(user.user_id, "enrollment") == []
      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), user.user_id)
    end

    test "the browser's seed waits on its record, is sent again once confirmed, and its kit goes to the browser alone",
         %{view: view, ctx: ctx, user: user, directory: directory, authenticator: authenticator} do
      debug_logs()
      {:ok, enrollment} = Recovery.enrollment("r1", directory.url)
      prompt(view, enrollment)
      seed = seed()
      params = %{"prompt_id" => "r1", "recovery_secret" => seed, "request_id" => request_id()}

      log =
        capture_log([level: :debug], fn ->
          view |> layer() |> render_hook("recovery_submit", params)
        end)

      # Waiting on its record, with nothing opened and nothing sent.
      assert render(view) =~ ~s(data-status="waiting")
      assert open_prompt(view) == "r1"
      assert attempts(user.user_id, "enrollment") == []
      assert Directory.requests() |> Enum.filter(&(&1.method == "POST")) == []
      ref = Prima.Confirmation.ref(held_secret(view))
      refute state_of(view) =~ seed
      refute log =~ seed
      assert log =~ ~s("recovery_secret" => "[FILTERED]")

      # The preview the record stores says what the form said (the
      # enrollment's record; the person's passkey registration was confirmed
      # by one of its own).
      [%{preview: preview}] =
        Arca.Repo.all(
          from(c in "pending_confirmations",
            where: c.user_id == ^user.user_id and c.action == "recovery_material",
            select: %{preview: c.preview}
          )
        )

      assert Jason.decode!(preview)["details"]["effect"] =~ directory.url

      prove_here!(view, ref, authenticator)

      # Confirmed: the browser is asked to send the same material again.
      assert_push_event(view, "recovery:resubmit", %{layer: "system-layer", prompt: "r1"}, 2_000)

      log =
        capture_log([level: :debug], fn ->
          view |> layer() |> render_hook("recovery_submit", params)
        end)

      assert_push_event(view, "recovery:kit", %{
        layer: "system-layer",
        prompt: "r1",
        kit: %{identifier: identifier, directory_url: kit_directory, recovery_secret: ^seed}
      })

      assert kit_directory == directory.url

      assert [%{phase: "accepted", identifier: ^identifier}] =
               attempts(user.user_id, "enrollment")

      # The kit is the browser's alone: not in the page, the layer's state,
      # a log or the request log.
      html = render(view)
      refute html =~ seed
      refute state_of(view) =~ seed
      refute log =~ seed
      refute logged() =~ seed
      assert has_element?(view, ~s([data-test="recovery"][data-phase="kit"]))

      # Saved: the seed is erased at the home, and the browser forgets it.
      view |> element(~s([data-test="recovery-ack"])) |> render_click()
      assert outcome("r1") == :confirmed
      assert_push_event(view, "recovery:clear", %{layer: "system-layer", prompt: "r1"})
      assert open_prompt(view) == nil

      assert [%{phase: "completed", kit_seed_sealed: nil}] =
               attempts(user.user_id, "enrollment")

      assert {:ok, identifier} == Sanctum.Tenancy.Users.identifier(ctx.user_id)
    end

    test "with no directory pinned, enrollment names the setting and opens nothing",
         %{view: view, user: user} do
      {:ok, enrollment} = Recovery.enrollment("r1", "https://dir.example")
      prompt(view, enrollment)
      Application.delete_env(:sanctum, :directory_url)

      view
      |> layer()
      |> render_hook("recovery_submit", %{
        "prompt_id" => "r1",
        "recovery_secret" => seed(),
        "request_id" => request_id()
      })

      assert {:refused, _reason} = outcome("r1")
      assert render(view) =~ "CYFR_DIRECTORY_URL"
      assert open_prompt(view) == "r1"
      assert attempts(user.user_id, "enrollment") == []
    end

    test "a submission with no seed the browser drew asks for nothing",
         %{view: view, ctx: ctx, user: user} do
      {:ok, enrollment} = Recovery.enrollment("r1", "https://dir.example")
      prompt(view, enrollment)

      html = view |> layer() |> render_hook("recovery_submit", %{"prompt_id" => "r1"})
      assert html =~ "could not draw the kit"
      assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), user.user_id)
    end

    test "dismissed while it waits, its request is cancelled and the browser forgets the material",
         %{view: view, ctx: ctx, directory: directory} do
      {:ok, enrollment} = Recovery.enrollment("r1", directory.url)
      prompt(view, enrollment)

      view
      |> layer()
      |> render_hook("recovery_submit", %{
        "prompt_id" => "r1",
        "recovery_secret" => seed(),
        "request_id" => request_id()
      })

      ref = Prima.Confirmation.ref(held_secret(view))

      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()
      assert outcome("r1") == :dismissed
      assert_push_event(view, "recovery:clear", %{layer: "system-layer", prompt: "r1"})

      assert {:ok, %{state: "cancelled"}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), ref)
    end
  end

  # ---- a kit again, and another kit ----------------------------------------------

  describe "a kit not yet saved" do
    setup :signed_in

    test "is shown again under a fresh proof each time, which the layer asks for again itself",
         %{view: view, ctx: ctx, authenticator: authenticator} do
      enrolled = enrolled!(ctx)
      {:ok, kit} = Recovery.kit("k1", enrolled.attempt_id)
      prompt(view, kit)

      view |> layer() |> render_hook("recovery_submit", %{"prompt_id" => "k1"})
      assert render(view) =~ ~s(data-status="waiting")
      ref = Prima.Confirmation.ref(held_secret(view))

      prove_here!(view, ref, authenticator)

      # The layer holds nothing secret for a kit: it asks again itself.
      seed = enrolled.seed

      assert_push_event(
        view,
        "recovery:kit",
        %{prompt: "k1", kit: %{recovery_secret: ^seed}},
        2_000
      )

      refute_push_event(view, "recovery:resubmit", _any, 100)
      refute render(view) =~ seed

      view |> element(~s([data-test="recovery-ack"])) |> render_click()
      assert outcome("k1") == :confirmed
    end
  end

  describe "another printed kit" do
    setup :signed_in

    test "is signed by a kit the person holds, typed, beside a seed the browser drew",
         %{view: view, ctx: ctx, directory: directory, authenticator: authenticator} do
      enrolled = enrolled!(ctx)
      {:ok, holder} = Recovery.holder("h1")
      prompt(view, holder)
      assert has_element?(view, ~s|[data-test="recovery-signer"]:not([name])|)

      added = seed()

      params = %{
        "prompt_id" => "h1",
        "recovery_secret" => enrolled.seed,
        "holder" => %{"kind" => "kit", "recovery_secret" => added},
        "request_id" => request_id()
      }

      view |> layer() |> render_hook("recovery_submit", params)
      ref = Prima.Confirmation.ref(held_secret(view))
      refute state_of(view) =~ added
      refute state_of(view) =~ enrolled.seed

      prove_here!(view, ref, authenticator)
      assert_push_event(view, "recovery:resubmit", %{prompt: "h1"}, 2_000)
      view |> layer() |> render_hook("recovery_submit", params)

      assert_push_event(view, "recovery:kit", %{prompt: "h1", kit: %{recovery_secret: ^added}})

      # The directory holds the added kit as a holder of the identity.
      {:ok, state} = Identity.verify_chain(Directory.log(directory.dir, enrolled.identifier))

      {:ok, {added_key, _}} =
        Identity.derive_recovery_key(Base.url_decode64!(added, padding: false))

      assert added_key in state.recovery_keys
    end

    test "with no signing kit typed, asks for one and sends nothing", %{view: view} do
      {:ok, holder} = Recovery.holder("h1")
      prompt(view, holder)

      html =
        view
        |> layer()
        |> render_hook("recovery_submit", %{
          "prompt_id" => "h1",
          "holder" => %{"kind" => "kit", "recovery_secret" => seed()},
          "request_id" => request_id()
        })

      assert html =~ "Type the recovery secret of a kit you hold now."
    end
  end

  # ---- after a declared restore --------------------------------------------------

  defp now, do: DateTime.utc_now()
  defp uniq, do: System.unique_integer([:positive])

  defp insert!(schema, row) do
    {1, _} = Arca.Repo.insert_all(schema, [row])
    row.id
  end

  defp key!(athanor_id, user_id) do
    insert!(Arca.Schemas.ApiKey, %{
      id: Prima.UUID7.generate_id("key"),
      name: "key-#{uniq()}",
      key_hash: :crypto.strong_rand_bytes(32),
      key_prefix: "cyfr_sk_rs",
      type: "service",
      scope: "[]",
      revoked: false,
      suspended: false,
      created_by: user_id,
      athanor_id: athanor_id,
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp profile!(athanor_id) do
    insert!(Arca.Schemas.Profile, %{
      id: Prima.UUID7.generate_id("prf"),
      athanor_id: athanor_id,
      source_ref: "local:acme/restored-#{uniq()}",
      kind: "owner",
      label: "default",
      status: "active",
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp webhook!(athanor_id, user_id, profile_id) do
    insert!(Arca.Schemas.Webhook, %{
      id: Prima.UUID7.generate_id("whk"),
      name: "hook-#{uniq()}",
      slug: "hook-#{uniq()}",
      target_ref: "local:acme/tool",
      secret_encrypted: "sealed-webhook-secret",
      athanor_id: athanor_id,
      profile_id: profile_id,
      created_by: user_id,
      suspended: false,
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp paired!(athanor_id, user_id) do
    insert!(Arca.Schemas.PairedClient, %{
      id: Prima.UUID7.generate_id("pcl"),
      athanor_id: athanor_id,
      user_id: user_id,
      source_kind: "session",
      source_id: "src_#{uniq()}",
      standing: "active",
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp vault!(athanor_id) do
    insert!(Arca.Schemas.VaultEntry, %{
      id: Prima.UUID7.generate_id("vlt"),
      athanor_id: athanor_id,
      name: "restored-entry-#{uniq()}",
      kind: "api_key",
      destination: ~s({"hosts":["api.example.com"],"scheme":"https"}),
      status: "active",
      inserted_at: now(),
      updated_at: now()
    })
  end

  defp row!(schema, id), do: Arca.Repo.get!(schema, id)

  defp pending_records(user_id) do
    Arca.Repo.all(
      from(c in "pending_confirmations",
        where: c.user_id == ^user_id,
        select: %{ref: c.ref, operation: c.operation, action: c.action, state: c.state}
      )
    )
  end

  defp host!(conn, athanor, opts \\ []) do
    session = %{
      "athanor_id" => athanor.id,
      "test" => self(),
      "listen" => Keyword.get(opts, :listen, true)
    }

    {:ok, view, _html} = live_isolated(conn, Host, session: session)
    view
  end

  # A person whose home was restored from a backup with the marker: their
  # passkey, a paired device, an API key and a webhook of theirs and a
  # profile and a vault entry of their own athanor, and an API key in a
  # group they sit in, each standing before the restore; then signed in
  # again with a door, since the restore ended every session.
  defp restored(%{conn: conn}) do
    user = test_user()
    _before = log_in_user(conn, user)
    athanor = seated_athanor()
    authenticator = Sanctum.TestContext.passkey!(user.user_id)
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Restored #{uniq()}")

    passkey_id =
      Arca.Repo.one!(
        from(p in Arca.Schemas.Passkey, where: p.user_id == ^user.user_id, select: p.id)
      )

    profile_id = profile!(athanor.id)

    ids = %{
      passkey: passkey_id,
      client: paired!(athanor.id, user.user_id),
      key: key!(athanor.id, user.user_id),
      webhook: webhook!(athanor.id, user.user_id, profile_id),
      profile: profile_id,
      vault: vault!(athanor.id),
      group_key: key!(group.id, user.user_id)
    }

    {:ok, _marked} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    {:ok, %{restore_id: restore_id}} = Arca.SecurityTransitions.restore(slot: :none)

    conn = log_in_user(conn, user)

    %{
      conn: conn,
      view: host!(conn, athanor),
      user: user,
      athanor: athanor,
      group: group,
      authenticator: authenticator,
      restore_id: restore_id,
      ids: ids
    }
  end

  defp reenable!(view, operation, id) do
    view
    |> element(~s([data-test="restore-reenable"][data-operation="#{operation}"][data-id="#{id}"]))
    |> render_click()
  end

  describe "the restore checklist" do
    setup :restored

    test "lists what the restore suspended and asks for again, with nothing secret and no prompt",
         %{view: view, athanor: athanor, ids: ids} do
      assert has_element?(view, ~s([data-test="restore-checklist"][data-recovering="true"]))
      assert render(view) =~ "This CYFR was restored from a backup"
      assert has_element?(view, ~s([data-test="restore-checklist-recovering"]))

      for {operation, id} <- [
            {"passkey.reenable", ids.passkey},
            {"pairing.reenable", ids.client},
            {"key.reenable", ids.key},
            {"webhook.reenable", ids.webhook}
          ] do
        assert has_element?(
                 view,
                 ~s([data-test="restore-reenable"][data-operation="#{operation}"][data-id="#{id}"])
               ),
               operation
      end

      profile = row!(Arca.Schemas.Profile, ids.profile)

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-profile"][data-id="#{ids.profile}"]),
               profile.source_ref
             )

      consent =
        PrismWeb.Focus.path(
          athanor,
          "/components?" <> URI.encode_query(%{"ref" => profile.source_ref, "setup" => "true"})
        )

      assert has_element?(view, ~s([data-test="restore-checklist-consent"][href="#{consent}"]))

      entry = row!(Arca.Schemas.VaultEntry, ids.vault)

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-entry"][data-kind="vault"][data-id="#{ids.vault}"]),
               entry.name
             )

      # The checklist holds no secret: a webhook's sealed secret and a
      # key's hash never reach the page.
      html = render(view)
      key = row!(Arca.Schemas.ApiKey, ids.key)
      refute html =~ "sealed-webhook-secret"
      refute html =~ Base.encode16(key.key_hash, case: :lower)
      assert open_prompt(view) == nil
      Cyfr.Test.Sandbox.end_views()
    end

    test "a key in another athanor is re-enabled there: the checklist links to it",
         %{view: view, group: group, ids: ids} do
      refute has_element?(view, ~s([data-test="restore-reenable"][data-id="#{ids.group_key}"]))

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-item"][data-id="#{ids.group_key}"] ) <>
                 ~s([data-test="restore-checklist-elsewhere"][href="#{PrismWeb.Focus.path(group, "/api-keys")}"])
             )

      Cyfr.Test.Sandbox.end_views()
    end

    test "a re-enable the checklist does not offer here dispatches nothing",
         %{view: view, user: user, ids: ids} do
      for {operation, id} <- [
            {"key.reenable", ids.group_key},
            {"key.reenable", "key_not_listed"},
            {"vault.delete", ids.vault},
            {"passkey.reenable", ids.key}
          ] do
        view
        |> layer()
        |> render_hook("restore_reenable", %{"operation" => operation, "id" => id})
      end

      assert open_prompt(view) == nil
      assert pending_records(user.user_id) == []
      refute has_element?(view, ~s([data-test="restore-checklist-error"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "is drawn by the page's own layer alone: a layer that does not listen draws none",
         %{conn: conn, athanor: athanor} do
      quiet = host!(conn, athanor, listen: false)
      refute has_element?(quiet, ~s([data-test="restore-checklist"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # Needs the four re-enable operations and the confirmation provider's
    # restore rule.
    test "a re-enable raises its record's prompt, offering an emailed code and never a passkey",
         %{view: view, user: user, ids: ids} do
      reenable!(view, "passkey.reenable", ids.passkey)

      assert [%{ref: ref, operation: "passkey.reenable", action: "restore_reenable"}] =
               pending_records(user.user_id)

      assert open_prompt(view) == Prompt.confirmation_id(ref)

      assert has_element?(
               view,
               ~s([data-test="confirmation"][data-ref="#{ref}"][data-own="true"])
             )

      refute has_element?(view, ~s([data-test="confirm-passkey"]))
      assert has_element?(view, ~s([data-test="confirm-email"]))

      # The secret is the layer's own, never drawn.
      refute render(view) =~ held_secret(view)

      # Dismissed, the request is cancelled; the page asked for nothing,
      # so it is told nothing.
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()
      assert open_prompt(view) == nil
      assert [%{state: "cancelled"}] = pending_records(user.user_id)
      refute_received {:host, {:system_layer, _id, _outcome}}
      Cyfr.Test.Sandbox.end_views()
    end

    # Needs the four re-enable operations and the confirmation provider's
    # restore rule.
    test "an emailed code re-enables a passkey, which ends the recovery; the passkey then confirms",
         %{view: view, user: user, ids: ids, authenticator: authenticator} do
      reenable!(view, "passkey.reenable", ids.passkey)
      view |> element(~s([data-test="confirm-email"])) |> render_click()
      assert_receive {:confirmation_code_mail, mail}, 2_000
      view |> form("#system-layer-code", %{"code" => MailSink.code(mail)}) |> render_submit()

      wait_until(
        fn ->
          has_element?(view, ~s([data-test="restore-checklist"][data-recovering="false"]))
        end,
        2_000,
        "the recovery's end"
      )

      assert open_prompt(view) == nil

      assert has_element?(
               view,
               ~s([data-test="restore-checklist-notice"]),
               "passkey is re-enabled"
             )

      refute has_element?(
               view,
               ~s([data-test="restore-checklist-item"][data-id="#{ids.passkey}"])
             )

      assert row!(Arca.Schemas.Passkey, ids.passkey).state == "active"

      assert {:ok, nil} =
               Arca.SecurityTransitions.restore_open(Prima.Actor.system(), user.user_id)

      # The device stays suspended until it is re-enabled itself.
      assert has_element?(view, ~s([data-test="restore-reenable"][data-id="#{ids.client}"]))
      assert row!(Arca.Schemas.PairedClient, ids.client).standing == "suspended"

      # The recovery over, the re-enabled passkey confirms the next one.
      reenable!(view, "key.reenable", ids.key)
      ref = Prima.Confirmation.ref(held_secret(view))
      prove_here!(view, ref, authenticator)

      wait_until(
        fn ->
          not has_element?(view, ~s([data-test="restore-checklist-item"][data-id="#{ids.key}"]))
        end,
        2_000,
        "the key's re-enable"
      )

      refute row!(Arca.Schemas.ApiKey, ids.key).suspended
      refute_received {:host, {:system_layer, _id, _outcome}}
      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "a person with nothing to recover" do
    setup :signed_in

    test "sees no restore checklist", %{view: view, ctx: ctx} do
      assert {:ok, nil} = Sanctum.Recovery.checklist(ctx)
      refute has_element?(view, ~s([data-test="restore-checklist"]))
    end
  end

  # ---- a frame -------------------------------------------------------------------

  describe "a frame" do
    # A tincture's frame acts through its per-open credential, on the
    # tincture plane: every person action is interactive, so the gate
    # refuses each before its handler, and no recovery material is ever
    # answered into a frame.
    test "reaches no recovery material: every person action is refused it" do
      issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.TestContext.create_session(issuer)
      {:ok, source} = Sanctum.Caller.establish(session.token)

      reference = %{publisher: "local", name: "recovery-probe", version: "1.0.0"}

      {:ok, %{credential: bearer}} =
        Sanctum.TinctureAuth.mint_frame_credential(
          source,
          reference,
          "sha256:" <> String.duplicate("0", 64),
          0,
          "frm_recovery_#{System.unique_integer([:positive])}"
        )

      {:ok, frame} = Sanctum.Caller.establish({:frame_credential, bearer})

      for args <- [
            %{"action" => "status"},
            %{"action" => "kit", "attempt_id" => "att_1"},
            %{"action" => "enroll", "recovery_secret" => seed(), "request_id" => request_id()}
          ] do
        assert {:error, reason} = Sanctum.Gate.call_external("person", frame, args)
        refute match?({:ok, _}, reason)
        refute inspect(reason) =~ "recovery_secret"
      end
    end
  end
end
