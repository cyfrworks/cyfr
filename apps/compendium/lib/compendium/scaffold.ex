defmodule Compendium.Scaffold do
  @moduledoc """
  Scaffolds new component projects with directory structure, WIT files,
  manifest, and starter Rust source.

  Creates the standard layout under `components/{type}s/local/{name}/{version}/`.
  """

  require Logger

  alias Sanctum.Context

  @name_pattern ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
  @valid_types ~w(reagent catalyst formula)

  @doc """
  Create a new component scaffold.

  ## Parameters

  - `ctx` - Sanctum context
  - `name` - Component name (lowercase alphanumeric + hyphens)
  - `type` - Component type: "reagent", "catalyst", or "formula"
  - `version` - Semver version string (e.g. "0.1.0")

  ## Returns

  - `{:ok, result}` with status, reference, and list of created files
  - `{:error, reason}` on validation failure or write error
  """
  @spec create(Context.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def create(%Context{} = ctx, name, type, version) do
    with :ok <- validate_name(name),
         :ok <- validate_type(type),
         :ok <- validate_version(version),
         :ok <- check_not_exists(ctx, name, type, version) do
      type_atom = String.to_existing_atom(type)
      base_path = component_base_path(name, type, version)

      files = [
        {base_path ++ ["cyfr-manifest.json"], manifest_for(name, type, version)},
        {base_path ++ ["src", "Cargo.toml"], Locus.Builder.cargo_toml_for(type_atom)},
        {base_path ++ ["src", "src", "lib.rs"], lib_rs_for(type_atom)}
      ] ++ wit_files(base_path, type_atom)

      case write_all(ctx, files) do
        :ok ->
          reference = "#{type}:local.#{name}:#{version}"
          file_list = Enum.map(files, fn {path, _} -> Path.join(path) end)

          {:ok,
           %{
             status: "created",
             reference: reference,
             files: file_list,
             next_steps: next_steps(type, reference)
           }}

        {:error, reason} ->
          {:error, "Failed to write scaffold files: #{inspect(reason)}"}
      end
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name) do
      :ok
    else
      {:error, "Invalid component name: '#{name}'. Must be lowercase alphanumeric with hyphens, e.g. 'my-api'"}
    end
  end

  defp validate_name(_), do: {:error, "Missing required argument: name"}

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(nil), do: {:error, "Missing required argument: type"}

  defp validate_type(type),
    do: {:error, "Invalid component type: '#{type}'. Must be: reagent, catalyst, or formula"}

  defp validate_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _} -> :ok
      :error -> {:error, "Invalid version: '#{version}'. Must be valid semver (e.g. 0.1.0)"}
    end
  end

  defp validate_version(_), do: {:error, "Missing required argument: version"}

  defp check_not_exists(ctx, name, type, version) do
    path = component_base_path(name, type, version) ++ ["cyfr-manifest.json"]

    case Arca.get(ctx, path) do
      {:ok, _} ->
        {:error, "Component already exists: #{type}:local.#{name}:#{version}"}

      {:error, _} ->
        :ok
    end
  end

  # ============================================================================
  # Path Helpers
  # ============================================================================

  defp component_base_path(name, type, version) do
    ["components", "#{type}s", "local", name, version]
  end

  # ============================================================================
  # Templates
  # ============================================================================

  defp manifest_for(name, "catalyst", version) do
    Jason.encode!(
      %{
        name: name,
        type: "catalyst",
        version: version,
        publisher: "local",
        description: "TODO: Describe your catalyst",
        setup: %{
          policy: %{
            allowed_domains: [],
            allowed_methods: ["GET", "POST"],
            timeout: "30s"
          },
          secrets: []
        },
        wasi: %{
          http: true,
          secrets: true
        }
      },
      pretty: true
    )
  end

  defp manifest_for(name, "formula", version) do
    Jason.encode!(
      %{
        name: name,
        type: "formula",
        version: version,
        publisher: "local",
        description: "TODO: Describe your formula",
        setup: %{
          policy: %{
            allowed_tools: [],
            timeout: "5m"
          }
        },
        dependencies: %{
          static: []
        }
      },
      pretty: true
    )
  end

  defp manifest_for(name, "reagent", version) do
    Jason.encode!(
      %{
        name: name,
        type: "reagent",
        version: version,
        publisher: "local",
        description: "TODO: Describe your reagent"
      },
      pretty: true
    )
  end

  defp lib_rs_for(:reagent) do
    """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::reagent::compute::Guest;

    struct Component;
    bindings::export!(Component with_types_in bindings);

    impl Guest for Component {
        fn compute(input: String) -> String {
            let data: serde_json::Value = match serde_json::from_str(&input) {
                Ok(v) => v,
                Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
            };
            // Pure computation here
            serde_json::to_string(&data).unwrap_or_else(|e|
                serde_json::json!({"error": e.to_string()}).to_string()
            )
        }
    }
    """
  end

  defp lib_rs_for(:catalyst) do
    """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::catalyst::run::Guest;

    struct Component;
    bindings::export!(Component with_types_in bindings);

    impl Guest for Component {
        fn run(input: String) -> String {
            let request: serde_json::Value = match serde_json::from_str(&input) {
                Ok(v) => v,
                Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
            };
            // TODO: Implement catalyst logic
            serde_json::json!({"error": "not implemented"}).to_string()
        }
    }
    """
  end

  defp lib_rs_for(:formula) do
    """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::formula::run::Guest;
    use bindings::cyfr::formula::invoke;
    use serde_json::{json, Value};

    struct Component;
    bindings::export!(Component with_types_in bindings);

    impl Guest for Component {
        fn run(input: String) -> String {
            match handle_request(&input) {
                Ok(output) => output,
                Err(e) => json!({"error": e}).to_string(),
            }
        }
    }

    fn handle_request(input: &str) -> Result<String, String> {
        let parsed: Value = serde_json::from_str(input)
            .map_err(|e| format!("Invalid JSON: {e}"))?;
        // TODO: Implement formula logic using invoke::call
        Ok(json!({"error": "not implemented"}).to_string())
    }
    """
  end

  # ============================================================================
  # WIT Files — copy from canonical wit/{type}/ directory
  # ============================================================================

  defp wit_files(base_path, type_atom) do
    wit_source = wit_source_path(type_atom)

    if File.dir?(wit_source) do
      wit_source
      |> list_files_recursive()
      |> Enum.map(fn file_path ->
        relative = Path.relative_to(file_path, wit_source)
        dest_path = base_path ++ ["src", "wit" | Path.split(relative)]
        content = File.read!(file_path)
        {dest_path, content}
      end)
    else
      Logger.warning("[Scaffold] WIT source directory not found: #{wit_source}")
      []
    end
  end

  defp wit_source_path(type_atom) do
    wit_base = Application.get_env(:locus, :wit_path, "./wit") |> Path.expand()
    Path.join(wit_base, to_string(type_atom))
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      if File.dir?(full) do
        list_files_recursive(full)
      else
        [full]
      end
    end)
  end

  # ============================================================================
  # File Writing
  # ============================================================================

  defp write_all(ctx, files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case Arca.put(ctx, path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ============================================================================
  # Next Steps
  # ============================================================================

  defp next_steps("catalyst", reference) do
    [
      "Edit cyfr-manifest.json to configure allowed_domains and secrets",
      "Edit src/src/lib.rs to implement your catalyst logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("formula", reference) do
    [
      "Edit cyfr-manifest.json to configure allowed_tools and dependencies",
      "Edit src/src/lib.rs to implement your formula logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("reagent", reference) do
    [
      "Edit src/src/lib.rs to implement your compute logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end
end
