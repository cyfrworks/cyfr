# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.RegistrationBindingTest do
  # Binding a webhook or schedule requires consent authority and a profile matching its target.
  use ExUnit.Case, async: false

  alias Sanctum.Consent.RegistrationBinding
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @target "reagent:local.bind-target"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    ctx = %Context{
      user_id: "bind_user",
      athanor_id: "ath_test",
      scope: :athanor,
      permissions: MapSet.new([:*]),
      authenticated: true,
      auth_method: :oidc
    }

    profile = %{
      id: "prof-bind",
      kind: :owner,
      source_ref: @target,
      label: "default",
      status: :active
    }

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-bind",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-bind",
        commit_digest: "sha256:commit-bind",
        blob_digest: Prima.JCS.hash_binary("{}"),
        resolved_policy: "{}",
        activation: %{@target => "sha256:act"},
        vault_refs: []
      })

    {:ok, ctx: ctx}
  end

  test "an interactive operator may bind a profile to its own component", %{ctx: ctx} do
    assert :ok = RegistrationBinding.authorize(ctx, "#{@target}:1.0.0", "prof-bind")
  end

  # A binding's lifetime and a run's origin are separate facts: a
  # schedule binds to any profile under the same rule, whatever lifetime
  # the bindings it will use carry. Where the binding is used, its
  # lifetime is checked at each fire (`Sanctum.Attach`, the disclosed
  # dispense), so the fire after it expires is refused there, never here.
  test "a schedule binds to a profile whose binding lives until a time; the row carries " <>
         "its expiry, and the binding rule is unchanged",
       %{ctx: ctx} do
    expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    key = "#{@target}|@ingress|default"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof-until",
          kind: :owner,
          source_ref: @target,
          label: "until",
          status: :active
        },
        %{
          id: "consent-until",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-until",
          commit_digest: "sha256:commit-until",
          resolved_policy: "{}",
          activation: %{@target => "sha256:act"},
          vault_refs: [
            %{
              binding_key: key,
              scope: "athanor",
              vault_entry_id: "vlt_until",
              binding_digest: "sha256:until",
              lifetime_kind: "until",
              expires_at: expires
            }
          ]
        }
      )

    assert :ok = RegistrationBinding.authorize(ctx, "#{@target}:1.0.0", "prof-until")

    {:ok, head} = Arca.ConsentStorage.head_consent(Context.actor(ctx), "prof-until")

    assert [%{binding_key: ^key, lifetime_kind: "until", expires_at: at}] = head.vault_refs
    assert DateTime.compare(at, expires) == :eq
  end

  test "a profile cannot be aimed at another component's registration", %{ctx: ctx} do
    assert {:error, :profile_not_for_target} =
             RegistrationBinding.authorize(ctx, "reagent:local.other:1.0.0", "prof-bind")
  end

  test "a wildcard API key cannot bind — the consent class is not a permission", %{ctx: ctx} do
    key_ctx = %{ctx | auth_method: :api_key}

    assert {:error, {:consent_refused, :no_capability}} =
             RegistrationBinding.authorize(key_ctx, @target, "prof-bind")
  end

  test "a guest-planed context can never bind", %{ctx: ctx} do
    guest = Context.enter_guest(ctx)

    assert {:error, {:consent_refused, :guest_plane}} =
             RegistrationBinding.authorize(guest, @target, "prof-bind")
  end

  test "a profile without a head consent cannot be bound", %{ctx: ctx} do
    :ok =
      ConsentFixtures.seed_profile!(ctx, %{
        id: "prof-headless",
        kind: :owner,
        source_ref: @target,
        label: "extra",
        status: :active
      })

    assert {:error, {:no_head_consent, "prof-headless"} = reason} =
             RegistrationBinding.authorize(ctx, @target, "prof-headless")

    assert RegistrationBinding.message(reason) == "the profile has no live consent"
  end

  # A head stored outside the closed vocabulary, or one the store cannot
  # answer, is not a profile with no consent: each refusal says which.
  @tag :capture_log
  test "a damaged head and an unanswered one are refused apart from an absent one",
       %{ctx: ctx} do
    :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-bind", scope: "sideways")

    assert {:error, {:head_corrupt, "prof-bind"} = damaged} =
             RegistrationBinding.authorize(ctx, @target, "prof-bind")

    assert RegistrationBinding.message(damaged) ==
             "the profile's consent is damaged and cannot be used"

    :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-bind", scope: "versionless")
    assert :ok = RegistrationBinding.authorize(ctx, @target, "prof-bind")

    Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

    assert {:error, {:head_unavailable, "prof-bind"} = unanswered} =
             RegistrationBinding.authorize(ctx, @target, "prof-bind")

    assert RegistrationBinding.message(unanswered) ==
             "the profile's consent cannot be read right now — try again"
  end

  # Publishing the target is fixture setup, not the thing under test. The
  # shared sandbox lets app-level processes write concurrently, and SQLite
  # answers a concurrent writer with a busy error that the storage layer
  # rescues to :database_error — so retry the fixture rather than fail an
  # assertion about authorization gates on a storage hiccup.
  defp publish_fixture(ctx, wasm, attempts \\ 3) do
    result =
      Compendium.Registry.publish_bytes(ctx, wasm, %{
        name: "bind-target",
        version: "1.0.0",
        type: "reagent",
        description: "bind test"
      })

    case result do
      {:error, :database_error} when attempts > 1 ->
        Process.sleep(50)
        publish_fixture(ctx, wasm, attempts - 1)

      other ->
        other
    end
  end

  describe "write-surface gates" do
    setup %{ctx: ctx} do
      test_path = Path.join(System.tmp_dir!(), "reg_bind_#{:rand.uniform(1_000_000)}")
      original_base_path = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, test_path)

      admin_ctx = Sanctum.TestContext.local()

      {:ok, _} =
        publish_fixture(
          admin_ctx,
          File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
        )

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original_base_path,
          do: Application.put_env(:arca, :base_path, original_base_path),
          else: Application.delete_env(:arca, :base_path)
      end)

      {:ok, ctx: ctx}
    end

    test "webhook create with a profile binding requires the consent class", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, message} =
               Sanctum.Webhook.create(key_ctx, %{
                 name: "bound-hook",
                 replay_protection: "none",
                 target_ref: "#{@target}:1.0.0",
                 profile_id: "prof-bind"
               })

      assert message =~ "profile binding refused"

      assert {:ok, created} =
               Sanctum.TestContext.create_webhook(ctx, %{
                 name: "bound-hook",
                 replay_protection: "none",
                 target_ref: "#{@target}:1.0.0",
                 profile_id: "prof-bind"
               })

      {:ok, row} =
        Arca.WebhookStorage.get_by_slug(created.slug)

      assert row.profile_id == "prof-bind"
    end

    test "an unbound webhook cannot be created at all", %{ctx: ctx} do
      assert {:error, message} =
               Sanctum.Webhook.create(ctx, %{
                 name: "unbound",
                 replay_protection: "none",
                 target_ref: "#{@target}:1.0.0"
               })

      assert message =~ "profile_id is required"
    end

    test "webhook update cannot re-point to a profile without the class", %{ctx: ctx} do
      {:ok, _} =
        Sanctum.TestContext.create_webhook(ctx, %{
          name: "plain-hook",
          replay_protection: "none",
          target_ref: "#{@target}:1.0.0",
          profile_id: "prof-bind"
        })

      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, message} =
               Sanctum.Webhook.update(key_ctx, "plain-hook", %{profile_id: "prof-bind"})

      assert message =~ "profile binding refused"

      assert {:ok, _} = Sanctum.Webhook.update(ctx, "plain-hook", %{profile_id: "prof-bind"})
    end

    test "schedule create with a profile binding requires the consent class", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      # The class refuses the key: the schedule tool answers the class's
      # own refusal.
      assert {:error, {:consent_class_required, _refusal}} =
               Crucible.Schedules.Provider.handle("schedule", key_ctx, %{
                 "action" => "create",
                 "name" => "bound-sched",
                 "cron_expression" => "0 * * * *",
                 "reference" => "#{@target}:1.0.0",
                 "profile_id" => "prof-bind"
               })

      assert {:ok, created} =
               Crucible.Schedules.Provider.handle("schedule", ctx, %{
                 "action" => "create",
                 "name" => "bound-sched",
                 "cron_expression" => "0 * * * *",
                 "reference" => "#{@target}:1.0.0",
                 "profile_id" => "prof-bind"
               })

      {:ok, schedule} =
        Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), created.schedule_id)

      assert schedule.profile_id == "prof-bind"
    end
  end
end
