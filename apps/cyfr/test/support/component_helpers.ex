defmodule Sanctum.Test.ComponentHelpers do
  @moduledoc false

  @doc """
  Registers a test component in the component_store with the given manifest.
  Used by tests that need a registered component for manifest-driven policy validation.
  """
  def register_test_component(name, version, type, manifest) do
    ctx = Sanctum.Context.local()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: "test_#{:crypto.hash(:sha256, "#{name}#{version}#{type}") |> Base.encode16(case: :lower) |> binary_part(0, 16)}",
      name: name,
      version: version,
      component_type: type,
      description: "Test component",
      tags: "[]",
      digest: "sha256:test",
      size: 100,
      exports: "[]",
      manifest: Jason.encode!(manifest),
      publisher: "local",
      publisher_id: ctx.user_id,
      source: "local",
      signature_verified: false,
      inserted_at: now,
      updated_at: now
    }

    Arca.ComponentStorage.put_component(ctx, attrs)
  end

  @doc """
  Standard manifest with all capability fields declared in setup.policy.
  Useful for tests that don't care about field validation restrictions.
  """
  def full_capability_manifest(type \\ "catalyst") do
    policy = case type do
      "formula" ->
        %{
          "allowed_tools" => [],
          "batch_timeout" => "5m",
          "max_concurrent_tasks" => 10
        }
      _ ->
        %{
          "allowed_domains" => [],
          "allowed_methods" => [],
          "allowed_paths" => [],
          "allowed_actions" => [],
          "allowed_private_ips" => [],
          "allowed_tools" => [],
          "batch_timeout" => "5m",
          "max_concurrent_tasks" => 10
        }
    end

    %{"setup" => %{"policy" => policy}}
  end
end
