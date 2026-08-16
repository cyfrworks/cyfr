# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaBaselineTest do
  @moduledoc """
  Pins the shape the baseline migration produces on the active adapter: the
  athanor is the only tenant column, there is no org/project anywhere, and
  exactly one Home athanor is seeded.
  """

  use ExUnit.Case, async: false

  @tenant_tables ~w(
    api_keys components component_dependencies executions mcp_logs policy_logs
    vault_entries profiles consents consent_vault_refs consent_proofs
    oauth_provider_credentials mcp_servers webhooks cron_schedules
  )

  @expected_tables ~w(
    athanors users server_allowlist memberships sessions api_keys registry_tokens components
    component_dependencies executions mcp_logs policy_logs vault_entries profiles
    consents consent_vault_refs consent_proofs oauth_provider_credentials
    mcp_servers webhooks webhook_deliveries cron_schedules
  )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  test "the schema has exactly the athanor-shaped tables" do
    tables = table_names()

    assert MapSet.subset?(MapSet.new(@expected_tables), tables)
    refute "orgs" in tables
    refute "projects" in tables
  end

  test "every tenant table carries athanor_id NOT NULL and no org/project column" do
    for table <- @tenant_tables do
      columns = columns(table)
      names = Enum.map(columns, & &1.name)

      assert "athanor_id" in names, "#{table} lacks athanor_id"
      refute "org_id" in names, "#{table} still has org_id"
      refute "project_id" in names, "#{table} still has project_id"

      athanor = Enum.find(columns, &(&1.name == "athanor_id"))
      assert athanor.not_null?, "#{table}.athanor_id must be NOT NULL"
      assert athanor.default == nil, "#{table}.athanor_id must have no default"
    end
  end

  test "sessions and memberships carry a nullable athanor_id (resolved after sign-in)" do
    for table <- ~w(sessions memberships) do
      athanor = Enum.find(columns(table), &(&1.name == "athanor_id"))
      assert athanor, "#{table} lacks athanor_id"
      refute athanor.not_null?
    end
  end

  test "sessions carry no scope; the person's standing is a users + memberships fact" do
    refute "scope" in Enum.map(columns("sessions"), & &1.name)
    user_names = Enum.map(columns("users"), & &1.name)

    for col <- ~w(email email_verified namespace personal_athanor_id status prefs),
        do: assert(col in user_names)

    membership_names = Enum.map(columns("memberships"), & &1.name)
    for col <- ~w(email status added_by), do: assert(col in membership_names)
    refute Enum.find(columns("memberships"), &(&1.name == "user_id")).not_null?
  end

  test "api_keys and webhooks have no scope_type; vault_entries has no system column" do
    refute "scope_type" in Enum.map(columns("api_keys"), & &1.name)
    refute "scope_type" in Enum.map(columns("webhooks"), & &1.name)
    refute "system" in Enum.map(columns("vault_entries"), & &1.name)
  end

  test "exactly one Home athanor is seeded, with a generated id and slug home" do
    # `home = TRUE` compares a real boolean on both adapters — a flag stored as
    # the text 'true' (what a typeless insert produces on SQLite) would not
    # match, and neither would the partial unique index protecting it.
    %{rows: rows} =
      Arca.Repo.query!("SELECT id, kind, slug, status FROM athanors WHERE home = TRUE")

    assert [[id, "group", "home", "active"]] = rows
    assert String.starts_with?(id, "ath_")
    assert {:ok, %{slug: "home", home: true}} = Sanctum.Tenancy.Athanors.home()
  end

  # --------------------------------------------------------------------------
  # Adapter-aware introspection

  defp sqlite?, do: Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.SQLite3

  defp table_names do
    rows =
      if sqlite?() do
        Arca.Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table'").rows
      else
        Arca.Repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
        ).rows
      end

    rows |> List.flatten() |> MapSet.new()
  end

  defp columns(table) do
    if sqlite?() do
      # cid, name, type, notnull, dflt_value, pk
      Arca.Repo.query!("PRAGMA table_info(#{table})").rows
      |> Enum.map(fn [_cid, name, _type, notnull, default, _pk] ->
        %{name: name, not_null?: notnull == 1, default: default}
      end)
    else
      Arca.Repo.query!(
        """
        SELECT column_name, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table]
      ).rows
      |> Enum.map(fn [name, nullable, default] ->
        %{name: name, not_null?: nullable == "NO", default: default}
      end)
    end
  end
end
