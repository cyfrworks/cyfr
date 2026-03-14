defmodule Locus.Validator do
  @moduledoc """
  WASM artifact validation for Locus import pipeline.

  Delegates to `Compendium.WasmValidator` — the canonical implementation
  lives in the cyfr app to avoid cross-app dependency violations.
  """

  defdelegate validate(bytes), to: Compendium.WasmValidator
  defdelegate quick_check(bytes), to: Compendium.WasmValidator
  defdelegate compute_digest(bytes), to: Compendium.WasmValidator
  defdelegate suggest_type(exports), to: Compendium.WasmValidator
  defdelegate extract_exports(bytes), to: Compendium.WasmValidator
end
