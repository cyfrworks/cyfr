defmodule Compendium.OCI.Auth do
  @moduledoc """
  OCI Distribution authentication — push-token only.

  cyfr talks to a single registry (cyfr.run apex or a self-deployed cyfr.run).
  The only credential shape is the opaque push token issued by cyfr.run. There
  is no realm-exchange dance, no basic/oauth2-client/key-pair dispatch, and no
  cross-registry fallback — the pre-refactor branches were removed when the
  registry surface collapsed to a single peer.

  Authentication flow:

  1. Client resolves the per-namespace push token from `CredentialStore`.
  2. Client emits `Authorization: Bearer <cyfr_pt_...>` on every request.
  3. On 401, caller surfaces `:token_revoked` (or similar) and prompts the
     user to re-probe — no automatic refresh.

  `Authorization: Basic base64(anyuser:token)` is also accepted server-side
  for Docker/OCI client compatibility; cyfr itself always uses Bearer.
  """

  require Logger

  alias Compendium.Registry.CredentialStore

  @doc """
  Build authorization headers for an OCI registry request.

  The `namespace_slug` is extracted from the repository path (first segment
  of the OCI name) and used to scope credential lookup. When no credential
  is available for the user/namespace pair, returns anonymous (`[]`) — the
  server will return 401 for authenticated-only operations.
  """
  # `_repository` is retained in the signature because `OCI.Transport.request/5`
  # passes the repository path at every call site; pre-refactor it scoped the
  # token cache (now deleted). Keeping the arg avoids a transport-level churn
  # for a purely cosmetic rename. Prefixed with `_` to signal no current use.
  @spec auth_headers(String.t(), String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, [{String.t(), String.t()}]}
  def auth_headers(registry, _repository, namespace_slug, ctx \\ nil) do
    case fetch_credential(registry, namespace_slug, ctx) do
      {:ok, %{type: :push_token, token: token}} when is_binary(token) and token != "" ->
        {:ok, [{"authorization", "Bearer #{token}"}]}

      _ ->
        # No credential → anonymous. Server will 401 if auth is required.
        {:ok, []}
    end
  end

  @doc """
  Fetch the per-namespace push-token credential for a user.

  Returns `{:ok, credential}` or `:anonymous`. When `ctx` is nil or has no
  user_id, returns `:anonymous` — there is no cross-user fallback (that was
  a privacy leak in multi-user Core, removed at refactor time).
  """
  @spec fetch_credential(String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, map()} | :anonymous
  def fetch_credential(registry, namespace_slug, ctx)
      when is_binary(registry) and is_binary(namespace_slug) do
    case ctx do
      %Sanctum.Context{user_id: user_id} when is_binary(user_id) and user_id != "" ->
        case CredentialStore.get(user_id, registry, namespace_slug) do
          {:ok, cred} -> {:ok, cred}
          :not_found -> :anonymous
        end

      _ ->
        :anonymous
    end
  end
end
