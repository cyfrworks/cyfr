# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningClosureTest do
  @moduledoc """
  Provisioning against the real tracked bundle. Everything the bundle
  depends on ships in the seed — the two hands and the five model
  catalysts — so an athanor fills with no registry at all, AQUA is
  consented with its whole closure present, and each model catalyst waits
  only for a key. Both registry endpoints are pinned, because they are
  separate settings and a pull dials the OCI one: `:registry_url` decides
  whether a registry is configured at all, `:oci_registry_url` is what a
  blob fetch resolves against.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Source
  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  @repo_root Path.expand("../../../..", __DIR__)
  @bundle Path.join(@repo_root, "seed/components")
  @providers ~w(claude openai gemini grok openrouter)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_closure_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    copy_bundle!(Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    keys = [:base_path, :seed_path, :oci_registry_url, :registry_url]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)

    on_exit(fn ->
      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(test_dir)
    end)

    :ok
  end

  for {label, rest_host, oci_host} <- [
        {"no registry is configured", "none", "none"},
        {"the registry does not answer", "127.0.0.1:19", "127.0.0.1:19"}
      ] do
    test "the real bundle provisions from its seed alone when #{label}" do
      Application.put_env(:cyfr, :registry_url, unquote(rest_host))
      Application.put_env(:cyfr, :oci_registry_url, unquote(oci_host))

      n = System.unique_integer([:positive])

      ctx =
        Sanctum.Context.build(
          user_id: "github|https://github.com|offline-#{n}",
          athanor_id: Sanctum.TestContext.athanor_id(),
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      assert {:ok, group} = Athanors.create_group(ctx.user_id, "Offline #{n}")
      in_group = %{ctx | athanor_id: group.id}
      :ok = Provisioning.start_provisioning(in_group)

      {:ok, group} = Athanors.get(group.id)

      assert %DateTime{} = group.provisioned_at,
             "the estate did not provision: #{inspect(Athanors.settings(group))}"

      refute Athanors.provisioning_failure(group)

      # Every model catalyst is a row of the estate: shipped, never pulled.
      for name <- @providers do
        assert {:ok, %{publisher: "local"}} =
                 Compendium.Registry.get_latest(in_group, name, "local", "catalyst"),
               "catalyst:local.#{name} is not registered"
      end

      # The soul is consented and loads: its whole closure is the local seed.
      assert {:ok, [_profile]} = Source.DB.profiles(in_group, "agent:local.aqua")

      assert {:ok, %Cyfr.Authority{} = auth} =
               Cyfr.Execution.authority_for(in_group, :default, "agent:local.aqua",
                 consent_source: Source.DB
               )

      assert auth.cursor == {:bound, "agent:local.aqua"}

      # A second provisioning is a no-op.
      assert {:ok, %{provisioned_at: at}} = Provisioning.provision(group, in_group)
      assert at == group.provisioned_at
    end
  end

  # The tracked bundle, minus Rust build output that may sit beside a source tree.
  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Cyfr.Test.SourceTree.files!(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      rel = Path.relative_to(src, @bundle)
      target = Path.join(dest, rel)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
