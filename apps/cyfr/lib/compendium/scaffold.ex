# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Scaffold do
  @moduledoc """
  Scaffolds new component projects with directory structure, WIT files,
  manifest, and starter Rust source.

  Creates the standard layout under the athanor's
  `components/{type}s/local/{name}/{version}/`.
  """

  alias Sanctum.Context

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
  @spec create(Context.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def create(%Context{} = ctx, name, type, version, opts \\ []) do
    with :ok <- validate_name(name),
         :ok <- validate_type(type),
         :ok <- validate_version(version),
         :ok <- check_not_exists(ctx, name, type, version) do
      type_atom = String.to_existing_atom(type)
      template = Keyword.get(opts, :template)
      base_path = component_base_path(name, type, version)

      files =
        case {type, template} do
          {"tincture", "react"} ->
            react_tincture_files(base_path, name, version)

          {"tincture", _} ->
            [
              {base_path ++ [Compendium.ComponentPath.manifest_name()],
               manifest_for(name, type, version)},
              {base_path ++ ["index.html"], tincture_index_html(name)},
              {base_path ++ ["app.js"], tincture_app_js()},
              {base_path ++ ["style.css"], tincture_style_css()},
              {base_path ++ Cyfr.TinctureHelpers.default_icon(), placeholder_icon_svg()},
              {base_path ++ Cyfr.TinctureHelpers.default_preview(), placeholder_preview_svg()}
            ]

          _ ->
            [
              {base_path ++ [Compendium.ComponentPath.manifest_name()],
               manifest_for(name, type, version)},
              {base_path ++ ["src", "Cargo.toml"], cargo_toml_for(type_atom)},
              {base_path ++ ["src", "src", "lib.rs"], lib_rs_for(type_atom)}
            ] ++ wit_files(base_path, type_atom)
        end

      rel_files =
        Enum.map(files, fn {path, content} -> {Enum.drop(path, length(base_path)), content} end)

      # Scaffolds stay cap-exempt — the enforcement roster in
      # `Sanctum.Tenancy.Caps` is unchanged by the commit migration.
      case Arca.Overlay.commit_unit(ctx, base_path, {:files, rel_files}, cap: :exempt) do
        {:ok, written} ->
          reference = local_ref(type, name, version)
          # In write order — the manifest (the unit's completion sentinel)
          # is last, and the list is the witness.
          file_list = Enum.map(written, &Path.join(base_path ++ &1))

          {:ok,
           %{
             status: "created",
             reference: reference,
             files: file_list,
             next_steps: next_steps(type, reference, template)
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
    # The component name grammar lives in one place; a scaffold that accepted
    # a name registration refuses would strand the user one step later.
    case Sanctum.ComponentRef.validate_name(name) do
      :ok -> :ok
      {:error, reason} -> {:error, "Invalid component name: '#{name}'. #{reason}"}
    end
  end

  defp validate_name(_), do: {:error, "Missing required argument: name"}

  defp validate_type(nil), do: {:error, "Missing required argument: type"}

  defp validate_type(type) when is_binary(type) do
    if type in Sanctum.ComponentRef.valid_types() do
      :ok
    else
      {:error,
       "Invalid component type: '#{type}'. Must be: reagent, catalyst, formula, or tincture"}
    end
  end

  defp validate_type(type),
    do:
      {:error,
       "Invalid component type: '#{type}'. Must be: reagent, catalyst, formula, or tincture"}

  defp validate_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _} -> :ok
      :error -> {:error, "Invalid version: '#{version}'. Must be valid semver (e.g. 0.1.0)"}
    end
  end

  defp validate_version(_), do: {:error, "Missing required argument: version"}

  defp check_not_exists(ctx, name, type, version) do
    path =
      component_base_path(name, type, version) ++ [Compendium.ComponentPath.manifest_name()]

    cond do
      not Arca.exists?(ctx, path) ->
        :ok

      version in Compendium.Provenance.shipped_versions(type, name) ->
        {:error,
         "#{local_ref(type, name, version)} is bundled with the server — edit it in place " <>
           "(your athanor gets its own copy on first write), or scaffold a new version or name"}

      true ->
        {:error, "Component already exists: #{local_ref(type, name, version)}"}
    end
  end

  # ============================================================================
  # Path Helpers
  # ============================================================================

  # The one spelling of a local reference — never hand-interpolated.
  defp local_ref(type, name, version) do
    Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
      type: type,
      namespace: Compendium.ComponentPath.default_publisher(),
      name: name,
      version: version
    })
  end

  defp component_base_path(name, type, version) do
    Compendium.ComponentPath.version_dir(
      type,
      Compendium.ComponentPath.default_publisher(),
      name,
      version
    )
  end

  # ============================================================================
  # Templates
  # ============================================================================

  defp manifest_for(name, "catalyst", version) do
    safe_encode_pretty(%{
      name: name,
      type: "catalyst",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your catalyst",
      caps: %{
        egress: %{
          domains: [],
          methods: ["GET", "POST"]
        },
        limits: %{timeout: "30s"}
      },
      dependencies: %{
        static: []
      }
    })
  end

  defp manifest_for(name, "formula", version) do
    safe_encode_pretty(%{
      name: name,
      type: "formula",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your formula",
      caps: %{
        tools: [],
        limits: %{timeout: "5m"}
      },
      dependencies: %{
        static: []
      }
    })
  end

  defp manifest_for(name, "reagent", version) do
    safe_encode_pretty(%{
      name: name,
      type: "reagent",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your reagent",
      dependencies: %{
        static: []
      }
    })
  end

  defp manifest_for(name, "tincture", version) do
    safe_encode_pretty(%{
      name: name,
      type: "tincture",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your tincture",
      tincture: %{
        entry: "index.html",
        icon: "palette",
        window: %{width: 800, height: 600, resizable: true}
      },
      dependencies: %{
        static: []
      }
    })
  end

  defp safe_encode_pretty(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
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
  # Cargo.toml Templates
  # ============================================================================

  @doc """
  Canonical Cargo.toml template for a component type.

  Single source of truth for the template — `Locus.Builder` delegates here.
  `include_oauth_wit: false` omits the `cyfr:oauth` WIT dependency from the
  catalyst template: the build path materializes only the WIT worlds every
  catalyst needs, and a user project that uses oauth declares it in its own
  Cargo.toml (which the builder treats as authoritative for WIT deps).
  """
  def cargo_toml_for(type, opts \\ [])

  def cargo_toml_for(:reagent, _opts) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:reagent"

    [package.metadata.component.target]
    world = "reagent"
    path = "wit"

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  def cargo_toml_for(:catalyst, opts) do
    wit_deps =
      [
        ~s("cyfr:vault" = { path = "wit/deps/cyfr-vault" }),
        ~s("cyfr:http" = { path = "wit/deps/cyfr-http" }),
        ~s("cyfr:storage" = { path = "wit/deps/cyfr-storage" })
      ] ++
        if Keyword.get(opts, :include_oauth_wit, true),
          do: [~s("cyfr:oauth" = { path = "wit/deps/cyfr-oauth" })],
          else: []

    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:catalyst"

    [package.metadata.component.target]
    world = "catalyst"
    path = "wit"

    [package.metadata.component.target.dependencies]
    #{Enum.join(wit_deps, "\n")}

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  def cargo_toml_for(:formula, _opts) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:formula"

    [package.metadata.component.target]
    world = "formula"
    path = "wit"

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  # ============================================================================
  # WIT Files
  # ============================================================================

  # The embedded WIT tree (`Compendium.WITSource` — the one source the
  # Locus build sandbox consumes too), mapped into the scaffold's layout.
  defp wit_files(base_path, type_atom) do
    type_atom
    |> Compendium.WITSource.files()
    |> Enum.map(fn {rel_segments, content} ->
      {base_path ++ ["src", "wit" | rel_segments], content}
    end)
  end

  # ============================================================================
  # Next Steps
  # ============================================================================

  defp next_steps("catalyst", reference, _template) do
    [
      "Edit cyfr-manifest.json to declare the needs and caps blocks " <>
        "(storage grants default to none; 'data/' is the component-private scope — " <>
        "grant 'components/' only when the component genuinely manages component trees)",
      "Edit src/src/lib.rs to implement your catalyst logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("formula", reference, _template) do
    [
      "Edit cyfr-manifest.json to declare the needs and caps blocks " <>
        "(storage grants default to none; 'data/' is the component-private scope — " <>
        "grant 'components/' only when the component genuinely manages component trees)",
      "Edit src/src/lib.rs to implement your formula logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("reagent", reference, _template) do
    [
      "Edit src/src/lib.rs to implement your compute logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("tincture", reference, "react") do
    [
      "Edit src/App.tsx to build your UI",
      "Add backend components to dependencies.static in cyfr-manifest.json",
      "Replace #{Path.join(Cyfr.TinctureHelpers.default_icon())} and " <>
        "#{Path.join(Cyfr.TinctureHelpers.default_preview())} to brand the picker card " <>
        "(add up to #{Cyfr.TinctureHelpers.preview_count()} previews)",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the built tincture"
    ]
  end

  defp next_steps("tincture", reference, _template) do
    [
      "Edit index.html, app.js, and style.css to build your UI",
      "The cyfr SDK (window.cyfr) is auto-injected — use cyfr.invoke() to call backend components",
      "Add backend components to dependencies.static in cyfr-manifest.json",
      "Replace #{Path.join(Cyfr.TinctureHelpers.default_icon())} and " <>
        "#{Path.join(Cyfr.TinctureHelpers.default_preview())} to brand the picker card " <>
        "(add up to #{Cyfr.TinctureHelpers.preview_count()} previews)",
      "Register: use component.register with reference '#{reference}'"
    ]
  end

  # ============================================================================
  # Tincture Templates
  # ============================================================================

  defp tincture_index_html(name) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{name}</title>
      <link rel="stylesheet" href="style.css">
    </head>
    <body>
      <div id="app">
        <h1>#{name}</h1>
        <p>Edit this tincture to build your UI.</p>
        <div id="data"></div>
      </div>
      <script src="app.js"></script>
    </body>
    </html>
    """
  end

  defp tincture_app_js do
    """
    // Tincture app entry point
    // cyfr.mode is "shell" (inside Prism) or "public" (standalone page)
    console.log("cyfr mode:", cyfr.mode)

    // Example: invoke a backend component
    // cyfr.invoke("c:local.my-component", { key: "value" })
    //   .then(result => console.log(result.output))
    //   .catch(err => console.error(err))

    cyfr.ready()
    """
  end

  defp tincture_style_css do
    """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: system-ui, sans-serif; padding: 1rem; color: #1a1a2e; }
    h1 { margin-bottom: 0.5rem; }
    #data { margin-top: 1rem; }
    """
  end

  # Placeholder media files written into `public/media/` so newly scaffolded
  # tinctures show *something* in the picker before the author replaces them.
  # The discovery helper finds them via the fixed convention paths.

  defp placeholder_icon_svg do
    ~S"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
      <rect width="256" height="256" rx="48" fill="#6366f1"/>
      <text x="128" y="160" font-family="system-ui, sans-serif" font-size="120"
            font-weight="600" fill="#ffffff" text-anchor="middle">T</text>
    </svg>
    """
  end

  defp placeholder_preview_svg do
    ~S"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360" width="640" height="360">
      <rect width="640" height="360" fill="#1e1b4b"/>
      <text x="320" y="170" font-family="system-ui, sans-serif" font-size="36"
            font-weight="600" fill="#a5b4fc" text-anchor="middle">Preview 1</text>
      <text x="320" y="210" font-family="system-ui, sans-serif" font-size="14"
            fill="#818cf8" fill-opacity="0.7" text-anchor="middle">replace with a screenshot · add preview-2.svg, preview-3.svg, …</text>
    </svg>
    """
  end

  # ============================================================================
  # React Tincture Templates
  # ============================================================================

  defp react_tincture_files(base_path, name, version) do
    [
      {base_path ++ [Compendium.ComponentPath.manifest_name()],
       react_manifest_for(name, version)},
      {base_path ++ ["package.json"], react_package_json(name)},
      {base_path ++ ["tsconfig.json"], react_tsconfig()},
      {base_path ++ ["vite.config.ts"], react_vite_config()},
      {base_path ++ ["index.html"], react_index_html(name)},
      {base_path ++ ["src", "main.tsx"], react_main_tsx()},
      {base_path ++ ["src", "App.tsx"], react_app_tsx(name)},
      {base_path ++ ["src", "index.css"], tincture_style_css()},
      {base_path ++ Cyfr.TinctureHelpers.default_icon(), placeholder_icon_svg()},
      {base_path ++ Cyfr.TinctureHelpers.default_preview(), placeholder_preview_svg()}
    ]
  end

  defp react_manifest_for(name, version) do
    safe_encode_pretty(%{
      name: name,
      type: "tincture",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your tincture",
      tincture: %{
        entry: "index.html",
        icon: "palette",
        build: %{tool: "vite"},
        window: %{width: 800, height: 600, resizable: true}
      },
      dependencies: %{
        static: []
      }
    })
  end

  defp react_package_json(name) do
    safe_encode_pretty(%{
      name: name,
      private: true,
      type: "module",
      scripts: %{
        dev: "vite",
        build: "tsc -b && vite build",
        preview: "vite preview"
      },
      dependencies: %{
        react: "^19.1.0",
        "react-dom": "^19.1.0"
      },
      devDependencies: %{
        "@vitejs/plugin-react": "^4.4.1",
        "@types/react": "^19.1.0",
        "@types/react-dom": "^19.1.0",
        typescript: "^5.8.3",
        vite: "^6.3.5"
      }
    })
  end

  defp react_tsconfig do
    safe_encode_pretty(%{
      compilerOptions: %{
        target: "ES2020",
        module: "ESNext",
        lib: ["ES2020", "DOM", "DOM.Iterable"],
        jsx: "react-jsx",
        moduleResolution: "bundler",
        strict: true,
        noUnusedLocals: true,
        noUnusedParameters: true,
        noFallthroughCasesInSwitch: true,
        skipLibCheck: true
      },
      include: ["src"]
    })
  end

  defp react_vite_config do
    ~S"""
    import { defineConfig } from "vite";
    import react from "@vitejs/plugin-react";

    export default defineConfig({
      plugins: [react()],
      base: "./",
      build: {
        target: "esnext",
        minify: "esbuild",
      },
    });
    """
  end

  defp react_index_html(name) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{name}</title>
    </head>
    <body>
      <div id="root"></div>
      <script type="module" src="/src/main.tsx"></script>
    </body>
    </html>
    """
  end

  defp react_main_tsx do
    ~S"""
    import { StrictMode } from "react";
    import { createRoot } from "react-dom/client";
    import App from "./App";
    import "./index.css";

    createRoot(document.getElementById("root")).render(
      <StrictMode>
        <App />
      </StrictMode>
    );
    """
  end

  defp react_app_tsx(name) do
    """
    import { useState, useEffect } from "react";

    declare const cyfr: {
      mode: "shell" | "public";
      ready(): Promise<{ ok: true }>;
      invoke(reference: string, input?: Record<string, unknown>): Promise<{
        status: string;
        output: Record<string, unknown>;
        execution_id: string;
        duration_ms: number;
      }>;
      setTitle(title: string): Promise<{ ok: true }>;
      close(): Promise<{ ok: true }>;
      getContext(): Promise<{ tincture_id: string; window_id: string }>;
      on(event: string, callback: (data: unknown) => void): void;
      off(event: string, callback: (data: unknown) => void): void;
    };

    export default function App() {
      const [data, setData] = useState<Record<string, unknown>[] | null>(null);

      useEffect(() => {
        // Example: invoke a backend component
        // cyfr.invoke("c:local.my-component", { key: "value" })
        //   .then(result => setData([result.output]))
        //   .catch(err => console.error(err));
        cyfr.ready();
      }, []);

      return (
        <div>
          <h1>#{name}</h1>
          <p>Edit src/App.tsx to build your UI.</p>
        </div>
      );
    }
    """
  end
end
