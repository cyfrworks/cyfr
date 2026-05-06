defmodule Sanctum.Edition do
  @moduledoc """
  Edition gate for CYFR.

  Single source of truth for "is this an Arx-edition deployment?". Use this
  in any `Sanctum.*` / `Arca.*` / `Emissary.*` / `Prism.*` / `Compendium.*`
  / `Cyfr.*` module that needs to gate behaviour on edition — it has no
  compile-time dependency on the (optional) `apps/arx/` umbrella app, so
  Core builds compile cleanly even when Arx is absent from the umbrella.

  ## Usage

      if Sanctum.Edition.arx?() do
        # Arx-only branch
      end

  Arx-only modules under `apps/arx/lib/arx/` may use `Arx.License.edition/0`
  directly — they know their app is loaded.

  ## Why a runtime check, not `Application.compile_env/3`

  `compile_env` would let the BEAM dead-code-eliminate the inactive branch
  and is conceptually cleaner (edition is chosen at release-build time).
  We don't use it today because the existing test suite mutates edition
  via `Application.put_env(:cyfr, :edition, :arx)` in setup hooks, which
  would silently no-op under `compile_env`. Switching to compile-time
  gating is a separate refactor that would also rework those tests.
  """

  # Bound at compile time for the macro variants below (Phoenix router DSL,
  # etc.). The runtime functions read from Application config so tests that
  # mutate edition via `Application.put_env/3` continue to work.
  @compile_edition Application.compile_env(:cyfr, :edition, :core)

  @spec arx?() :: boolean()
  def arx?, do: Application.get_env(:cyfr, :edition, :core) == :arx

  @spec core?() :: boolean()
  def core?, do: not arx?()

  @doc """
  Compile-time gate for code that only exists in Arx builds.

  Required (vs the runtime `arx?/0`) for cases where the conditional must be
  resolved at compile time — Phoenix router DSL is the canonical example,
  since `scope`/`get`/`post` macros register routes at compile time and
  cannot be wrapped in a runtime `if`.

  Edition is bound from `Application.compile_env(:cyfr, :edition, :core)`.
  Switching editions requires recompilation, which is expected: edition is
  chosen at release-build time (Core release vs cyfr_arx release).

  ## Usage

      require Sanctum.Edition

      defmodule EmissaryWeb.Router do
        use EmissaryWeb, :router
        require Sanctum.Edition

        Sanctum.Edition.arx_only do
          scope "/admin", ArxWeb.Admin do
            pipe_through [:browser, :require_arx_admin]
            live "/orgs", OrgsLive
          end
        end
      end
  """
  defmacro arx_only(do: block) do
    if @compile_edition == :arx do
      block
    end
  end

  @doc """
  Compile-time gate for Core-only code (the inverse of `arx_only/1`).
  """
  defmacro core_only(do: block) do
    if @compile_edition != :arx do
      block
    end
  end
end
