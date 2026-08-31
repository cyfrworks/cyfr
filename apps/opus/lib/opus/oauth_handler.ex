# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthHandler do
  @moduledoc """
  Host function handler for OAuth token access.

  Provides the `cyfr:oauth/token@0.1.0` WASI host function import that
  enables Catalyst components to obtain OAuth access tokens without
  ever seeing client credentials or refresh tokens.

  ## Security Model

  - Client credentials and refresh tokens live sealed in vault entries —
    never exposed to WASM
  - Access tokens are the ONLY thing exposed to WASM, and they're masked in output
  - Provider matching happens at dispense: the bound vault entry refuses
    any provider it wasn't authorized for

  ## Architecture

  Follows the same pattern as `Opus.HttpHandler` and `Opus.StorageHandler`.
  Dispensed tokens are tracked by `Opus.OAuthTokenTracker`, a supervised
  process owning a `:private` ETS table — the host-function closure (running
  in the Wasmex process) records a token via a synchronous call, and
  `finalize_execution` (in the executor process) drains it for masking.
  """

  alias Sanctum.Context

  @doc """
  Build the WASI host function imports for OAuth token access.

  Returns a map suitable for merging into the Wasmex imports.

  ## Options

  - `:resolver` (required) - `(provider -> {:ok, token} | {:error, term})`,
    vault-reader-backed from the consent edge. A component whose edge
    carries no vault binding gets a resolver that denies every request.
  - `:limits` - the node's `Sanctum.Limits`; the consented rate limit meters
    dispensing under its own bucket.
  """
  @spec build_oauth_imports(Context.t(), String.t(), String.t(), keyword()) :: map()
  def build_oauth_imports(%Context{} = ctx, component_ref, execution_id, opts \\ []) do
    # The resolver is edge-supplied (vault-reader-backed). Provider
    # matching and endpoint integrity live behind it: the vault entry is
    # provider-checked at dispense and its endpoints are covered by the
    # consent's binding digest.
    resolver = Keyword.fetch!(opts, :resolver)
    limits = opts[:limits]

    %{
      "cyfr:oauth/token@0.1.0" => %{
        "get-access-token" =>
          {:fn,
           fn provider ->
             case check_dispense_rate(ctx, component_ref, limits) do
               :ok -> get_access_token(provider, resolver, component_ref, execution_id)
               {:error, message} -> {:error, message}
             end
           end}
      }
    }
  end

  @doc """
  Collect and delete all dispensed tokens for an execution.
  Returns a list of token strings for use with SecretMasker.
  Safe to call multiple times (second call returns empty list).
  """
  @spec collect_dispensed(String.t() | nil) :: [String.t()]
  def collect_dispensed(execution_id), do: Opus.OAuthTokenTracker.collect(execution_id)

  # ============================================================================
  # Internal
  # ============================================================================

  # This import had no rate limit at all, so a guest loop drove one vault
  # unseal — and a possible provider token refresh — per call, for as long as
  # the execution ran. It meters under its own `"oauth:"` bucket rather than
  # sharing the egress one, so a component that legitimately fetches a token
  # and then makes many HTTP calls is not throttled by its own success.
  #
  # A dead limiter fails CLOSED, matching the executor and the egress gate: an
  # unmetered dispense is the condition this exists to prevent.
  defp check_dispense_rate(%Context{} = ctx, component_ref, %Sanctum.Limits{} = limits) do
    case Opus.RateLimiter.check(ctx.athanor_id, "oauth:" <> component_ref, %{
           rate_limit: limits.rate_limit
         }) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, "token dispense rate limit exceeded; retry in #{retry_after}ms"}

      {:error, :missing_tenant} ->
        {:error, "token dispense refused: no resolved athanor"}
    end
  catch
    :exit, _reason ->
      {:error, "token dispense refused: rate limiter unavailable"}
  end

  # No limits means no consented rate to enforce (the capability-scoped import
  # is only built when the edge carries a vault binding; a nil here is a
  # direct caller, not a consented run).
  defp check_dispense_rate(_ctx, _component_ref, _limits), do: :ok

  # The WIT declares `result<string, string>`, so both arms must be strings
  # and neither may raise: a fault here takes the Wasmex process and the guest
  # gets an opaque failure instead of the `err(…)` it was promised. The
  # resolver answers in the vault reader's typed vocabulary (atoms and
  # tuples), so it is rendered here — by shape, never by `inspect`, which
  # would put the payload it refused into guest hands.
  defp get_access_token(provider, resolver, component_ref, execution_id) do
    provider = bound_provider(provider)
    start_time = System.monotonic_time(:millisecond)

    case safe_resolve(resolver, provider) do
      {:ok, token} ->
        case Opus.OAuthTokenTracker.put(execution_id, token) do
          :ok ->
            duration = System.monotonic_time(:millisecond) - start_time

            :telemetry.execute(
              [:cyfr, :opus, :oauth, :token_request],
              %{duration_ms: duration},
              %{component_ref: component_ref, provider: provider, status: :ok}
            )

            {:ok, token}

          {:error, :untracked} ->
            # A token the tracker never saw can never be masked out of the
            # execution's output, events or audit rows — the dispense fails
            # closed rather than handing the guest an unmaskable secret.
            duration = System.monotonic_time(:millisecond) - start_time

            :telemetry.execute(
              [:cyfr, :opus, :oauth, :token_request],
              %{duration_ms: duration},
              %{
                component_ref: component_ref,
                provider: provider,
                status: :error,
                reason: "token tracking unavailable"
              }
            )

            {:error, "the credential store is unavailable"}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:cyfr, :opus, :oauth, :token_request],
          %{duration_ms: duration},
          %{
            component_ref: component_ref,
            provider: provider,
            status: :error,
            reason: String.slice(refusal_message(reason), 0, 100)
          }
        )

        {:error, refusal_message(reason)}
    end
  end

  # Guest input, and it reaches a telemetry tag and a log line. A provider
  # name is a short identifier; nothing bounded it.
  @provider_max 128

  defp bound_provider(provider) when is_binary(provider),
    do: binary_part(provider, 0, min(byte_size(provider), @provider_max))

  defp bound_provider(other), do: other |> to_string() |> bound_provider()

  defp safe_resolve(resolver, provider) do
    resolver.(provider)
  rescue
    e -> {:error, {:resolver_raised, Exception.message(e)}}
  catch
    :exit, _reason -> {:error, :resolver_unavailable}
    _kind, _value -> {:error, :resolver_unavailable}
  end

  # One sentence per shape. The vault reader's reasons name what went wrong
  # and sometimes quote the material that did — `{:invalid_payload, payload}`
  # carries the payload itself — so the guest is told the shape of the
  # failure and never its contents.
  defp refusal_message(reason) when is_binary(reason), do: reason
  defp refusal_message(:anonymous_denied), do: "anonymous callers may not dispense tokens"
  defp refusal_message(:binding_mismatch), do: "the credential no longer matches its consent"
  defp refusal_message(:unseal_failed), do: "the credential could not be unsealed"
  defp refusal_message(:no_oauth_material), do: "this credential carries no OAuth material"
  defp refusal_message(:resolver_unavailable), do: "the credential store is unavailable"
  defp refusal_message({:resolver_raised, _}), do: "the credential store is unavailable"
  defp refusal_message({:entry_unavailable, status}), do: "the credential is #{status}"

  defp refusal_message({:provider_mismatch, provider}),
    do: "this credential is not for #{bound_provider(provider)}"

  defp refusal_message({:scope_projection_unsatisfiable, _scopes}),
    do: "the granted scopes do not cover this request"

  defp refusal_message(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp refusal_message({tag, _detail}) when is_atom(tag), do: refusal_message(tag)
  defp refusal_message(_other), do: "the token could not be dispensed"
end
