defmodule Opus.Runtime.TestHelper do
  @moduledoc false

  @doc """
  Build the imports map for a given component type, exposing the
  secret-gating logic for test assertions.
  """
  def build_imports(component_type, preloaded_secrets, component_ref) do
    if component_type == :catalyst do
      Opus.Runtime.build_secrets_imports_for_test(preloaded_secrets, component_ref)
    else
      %{}
    end
  end
end
