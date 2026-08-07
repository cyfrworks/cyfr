# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.RegistrationBindingTest do
  # D5: binding a webhook or schedule to a profile mints a standing,
  # attacker-timed invocation conduit carrying the profile's consented
  # resources — so it takes the consent authorization class, and the
  # profile must belong to the registration's own target.
  use ExUnit.Case, async: false

  alias Sanctum.Consent.RegistrationBinding
  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @target "reagent:local.bind-target"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    start_supervised!(Source.Memory)

    ctx = %Context{
      user_id: "bind_user",
      org_id: "local",
      project_id: "default",
      scope: :project,
      permissions: MapSet.new([:*]),
      authenticated: true,
      auth_method: :oidc
    }

    :ok =
      Source.Memory.put_profile(ctx, %{
        id: "prof-bind",
        kind: :owner,
        source_ref: @target,
        label: "default",
        status: :active
      })

    :ok =
      Source.Memory.put_head_consent(ctx, "prof-bind", %{
        id: "consent-bind",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-bind",
        commit_digest: "sha256:commit-bind",
        resolved_policy: "{}",
        activation: %{@target => "sha256:act"},
        vault_refs: []
      })

    {:ok, ctx: ctx}
  end

  test "an interactive operator may bind a profile to its own component", %{ctx: ctx} do
    assert :ok = RegistrationBinding.authorize(ctx, "#{@target}:1.0.0", "prof-bind")
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
      Source.Memory.put_profile(ctx, %{
        id: "prof-headless",
        kind: :owner,
        source_ref: @target,
        label: "extra",
        status: :active
      })

    assert {:error, {:no_head_consent, "prof-headless"}} =
             RegistrationBinding.authorize(ctx, @target, "prof-headless")
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
      original_base_path = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, test_path)
      Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

      admin_ctx = Sanctum.TestContext.local()

      {:ok, _} =
        publish_fixture(
          admin_ctx,
          File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
        )

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original_base_path,
          do: Application.put_env(:cyfr, :base_path, original_base_path),
          else: Application.delete_env(:cyfr, :base_path)
      end)

      {:ok, ctx: ctx}
    end

    test "webhook create with a profile binding requires the consent class", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, message} =
               Sanctum.Webhook.create(key_ctx, %{
                 name: "bound-hook",
                 target_ref: "#{@target}:1.0.0",
                 profile_id: "prof-bind"
               })

      assert message =~ "profile binding refused"

      assert {:ok, created} =
               Sanctum.Webhook.create(ctx, %{
                 name: "bound-hook",
                 target_ref: "#{@target}:1.0.0",
                 profile_id: "prof-bind"
               })

      {:ok, row} =
        Arca.WebhookStorage.get_by_slug(created.slug)

      assert row.profile_id == "prof-bind"
    end

    test "webhook update cannot re-point to a profile without the class", %{ctx: ctx} do
      {:ok, _} =
        Sanctum.Webhook.create(ctx, %{name: "plain-hook", target_ref: "#{@target}:1.0.0"})

      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, message} =
               Sanctum.Webhook.update(key_ctx, "plain-hook", %{profile_id: "prof-bind"})

      assert message =~ "profile binding refused"

      assert {:ok, _} = Sanctum.Webhook.update(ctx, "plain-hook", %{profile_id: "prof-bind"})
    end

    test "schedule create with a profile binding requires the consent class", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, message} =
               Opus.CronMCP.handle("schedule", key_ctx, %{
                 "action" => "create",
                 "name" => "bound-sched",
                 "cron_expression" => "0 * * * *",
                 "reference" => "#{@target}:1.0.0",
                 "profile_id" => "prof-bind"
               })

      assert message =~ "profile binding refused"

      assert {:ok, created} =
               Opus.CronMCP.handle("schedule", ctx, %{
                 "action" => "create",
                 "name" => "bound-sched",
                 "cron_expression" => "0 * * * *",
                 "reference" => "#{@target}:1.0.0",
                 "profile_id" => "prof-bind"
               })

      schedule = Arca.CronSchedule.get_by_user(ctx, created.schedule_id)
      assert schedule.profile_id == "prof-bind"
    end
  end
end
