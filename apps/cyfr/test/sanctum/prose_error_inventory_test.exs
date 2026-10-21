# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProseErrorInventoryTest do
  @moduledoc """
  The prose errors Sanctum answers, listed, so their number can only fall.

  A bare sentence, `{:error, "…"}`, is classed `internal` by the refusal
  vocabulary (`Prima.Refusal`): a person told a rate limit or a duplicate
  that way reads a failure of the server, and nothing can branch on it.
  Every such return in `apps/sanctum/lib` — an `{:error, …}` whose reason
  is a string, an interpolation or a concatenation starting with one, in
  any function, on any number of lines — is counted by the function that
  returns it. A count that grows fails, naming the function: answer a
  typed reason instead. A count that fell fails too until it is lowered
  here, so the number in front of a reader is the number in the tree, and
  a function at zero leaves the list.

  Sanctum's sites are counted here alone: `Sanctum.Gate.ErrorAdoptionTest`
  counts the rest of the umbrella's.
  """

  use ExUnit.Case, async: true

  # {file, function} => prose `{:error, …}` returns remaining.
  @inventory %{
    {"apps/sanctum/lib/sanctum/api_key.ex", "Sanctum.ApiKey.create/3"} => 1,
    {"apps/sanctum/lib/sanctum/catalog.ex", "Sanctum.Catalog.in_chain_reachability/2"} => 2,
    {"apps/sanctum/lib/sanctum/consent/blob_builder.ex",
     "Sanctum.Consent.BlobBuilder.narrow_limit/3"} => 14,
    {"apps/sanctum/lib/sanctum/consent/normalize.ex",
     "Sanctum.Consent.Normalize.exact_duration/1"} => 2,
    {"apps/sanctum/lib/sanctum/consent/normalize.ex", "Sanctum.Consent.Normalize.subset_limit/2"} =>
      6,
    {"apps/sanctum/lib/sanctum/dispatch.ex", "Sanctum.Dispatch.in_chain_target/3"} => 1,
    {"apps/sanctum/lib/sanctum/provider.ex", "Sanctum.Provider.handle/3"} => 1,
    {"apps/sanctum/lib/sanctum/provider_credentials.ex",
     "Sanctum.ProviderCredentials.fetch_for_oauth/2"} => 1,
    {"apps/sanctum/lib/sanctum/provider_credentials.ex", "Sanctum.ProviderCredentials.unseal/1"} =>
      1,
    {"apps/sanctum/lib/sanctum/provider_credentials.ex",
     "Sanctum.ProviderCredentials.validate_client_id/1"} => 1,
    {"apps/sanctum/lib/sanctum/provider_credentials.ex",
     "Sanctum.ProviderCredentials.validate_provider/1"} => 2,
    {"apps/sanctum/lib/sanctum/providers/athanor.ex", "Sanctum.Providers.Athanor.handle/2"} => 1,
    {"apps/sanctum/lib/sanctum/providers/door.ex", "Sanctum.Providers.Door.handle/2"} => 1,
    {"apps/sanctum/lib/sanctum/providers/key.ex", "Sanctum.Providers.Key.handle/2"} => 10,
    {"apps/sanctum/lib/sanctum/providers/key.ex", "Sanctum.Providers.Key.parse_key_type_arg/1"} =>
      1,
    {"apps/sanctum/lib/sanctum/providers/oauth.ex", "Sanctum.Providers.OAuth.handle/2"} => 3,
    {"apps/sanctum/lib/sanctum/providers/profile.ex",
     "Sanctum.Providers.Profile.decode_bindings/1"} => 1,
    {"apps/sanctum/lib/sanctum/providers/profile.ex",
     "Sanctum.Providers.Profile.decode_tool_servers/1"} => 1,
    {"apps/sanctum/lib/sanctum/providers/profile.ex", "Sanctum.Providers.Profile.enum/3"} => 1,
    {"apps/sanctum/lib/sanctum/providers/profile.ex", "Sanctum.Providers.Profile.handle/2"} => 6,
    {"apps/sanctum/lib/sanctum/providers/session.ex", "Sanctum.Providers.Session.handle/2"} => 4,
    {"apps/sanctum/lib/sanctum/providers/system.ex", "Sanctum.Providers.System.handle/3"} => 5,
    {"apps/sanctum/lib/sanctum/providers/system.ex", "Sanctum.Providers.System.handle_notify/2"} =>
      3,
    {"apps/sanctum/lib/sanctum/providers/system.ex", "Sanctum.Providers.System.handle_status/2"} =>
      1,
    {"apps/sanctum/lib/sanctum/providers/system.ex",
     "Sanctum.Providers.System.handle_tools_list_for/2"} => 1,
    {"apps/sanctum/lib/sanctum/providers/system.ex", "Sanctum.Providers.System.send_webhook/2"} =>
      2,
    {"apps/sanctum/lib/sanctum/providers/tincture_visibility.ex",
     "Sanctum.Providers.TinctureVisibility.handle/2"} => 1,
    {"apps/sanctum/lib/sanctum/providers/webhook.ex", "Sanctum.Providers.Webhook.handle/2"} => 19,
    {"apps/sanctum/lib/sanctum/vault.ex", "Sanctum.Vault.rotation_oauth/2"} => 1,
    {"apps/sanctum/lib/sanctum/vault/oauth.ex", "Sanctum.Vault.OAuth.http_post/3"} => 3,
    {"apps/sanctum/lib/sanctum/vault/oauth.ex", "Sanctum.Vault.OAuth.require_https/1"} => 1,
    {"apps/sanctum/lib/sanctum/vault/oauth_grant.ex",
     "Sanctum.Vault.OAuthGrant.malformed_response/0"} => 1,
    {"apps/sanctum/lib/sanctum/vault/oauth_grant.ex", "Sanctum.Vault.OAuthGrant.seal/2"} => 1,
    {"apps/sanctum/lib/sanctum/vault/oauth_grant.ex",
     "Sanctum.Vault.OAuthGrant.validate_redirect_uri/2"} => 1,
    {"apps/sanctum/lib/sanctum/webhook.ex", "Sanctum.Webhook.authorize_profile_binding/3"} => 3,
    {"apps/sanctum/lib/sanctum/webhook.ex", "Sanctum.Webhook.create/2"} => 1,
    {"apps/sanctum/lib/sanctum/webhook.ex", "Sanctum.Webhook.maybe_authorize_profile_binding/4"} =>
      1,
    {"apps/sanctum/lib/sanctum/webhook.ex", "Sanctum.Webhook.validate_target_ref/2"} => 3
  }

  defp root, do: Path.expand("../../../..", __DIR__)

  defp sanctum_lib do
    for path <- Prima.Test.SourceTree.files!(Path.join(root(), "apps/sanctum/lib/**/*.ex")),
        do: {Path.relative_to(path, root()), Prima.Test.SourceTree.read(path)}
  end

  # `{file, "Module.function/arity"} => count` over `sources`.
  defp inventory(sources) do
    sources
    |> Enum.flat_map(fn {path, source} ->
      for function <- prose_returns(source), do: {path, function}
    end)
    |> Enum.frequencies()
  end

  defp prose_returns(source), do: source |> Code.string_to_quoted!() |> modules([])

  # Each module's functions, once per prose return, a nested module under
  # its own full name.
  defp modules(ast, outer) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, acc ->
          name = outer ++ parts
          module = Enum.map_join(name, ".", &Atom.to_string/1)
          {nil, acc ++ functions(module, body) ++ modules(body, name)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp functions(module, body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:defmodule, _, _}, acc ->
          {nil, acc}

        # The body with its `rescue`, `catch`, `else` and `after` blocks.
        {kind, _, [head, [{:do, _} | _] = blocks]}, acc when kind in [:def, :defp] ->
          {name, arity} = function_of(head)
          returns = blocks |> Keyword.values() |> prose()
          {nil, acc ++ List.duplicate("#{module}.#{name}/#{arity}", length(returns))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp function_of({:when, _, [head | _guards]}), do: function_of(head)
  defp function_of({name, _, params}), do: {name, length(List.wrap(params))}

  # Every `{:error, prose}` the body answers. The left of a clause is a
  # pattern, which answers nothing, so only its right is read.
  defp prose(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:->, _, [_pattern, right]}, acc -> {{:__block__, [], [right]}, acc}
        {:error, reason} = node, acc -> {node, if(prose?(reason), do: [reason | acc], else: acc)}
        node, acc -> {node, acc}
      end)

    found
  end

  defp prose?(reason) when is_binary(reason), do: true
  defp prose?({:<<>>, _, _interpolated}), do: true
  defp prose?({:<>, _, [left, _right]}), do: prose?(left)
  defp prose?(_reason), do: false

  test "Sanctum answers no more prose errors than listed, and the list is the tree" do
    now = inventory(sanctum_lib())

    differ =
      for key <- Enum.uniq(Map.keys(now) ++ Map.keys(@inventory)),
          {count, listed} = {Map.get(now, key, 0), Map.get(@inventory, key, 0)},
          count != listed,
          do: "  #{inspect(key)}: #{count} now, #{listed} listed"

    assert differ == [], """
    Sanctum's prose errors differ from the inventory:

    #{Enum.join(Enum.sort(differ), "\n")}

    A count that grew is a new sentence classed internal: answer a reason
    the refusal vocabulary types (`{:conflict, msg}`, `{:rate_limited, s}`,
    `{:invalid_argument, msg}`, `{:unavailable, what}`, …). A count that fell
    is lowered here, and a function at zero leaves the list.
    """
  end

  test "the scan counts a prose return however it is written, and no pattern or typed reason" do
    source = ~S"""
    defmodule Planted do
      def single(_), do: {:error, "a sentence"}
      def interpolated(name), do: {:error, "No #{name}"}
      def joined(name), do: {:error, "No " <> name}

      def multiline(name) do
        {:error,
         "a sentence long enough to " <>
           "wrap: #{name}"}
      end

      def typed(name), do: {:error, {:conflict, "Taken: #{name}"}}
      def matched({:error, "Too many" <> _}), do: :ok

      def cased(result) do
        case result do
          {:error, "exact"} -> :ok
          other -> other
        end
      end

      defp private(_), do: {:error, "a helper's"}

      def rescued(fun) do
        fun.()
      rescue
        _ -> {:error, "it raised"}
      end

      defmodule Inner do
        def inner(_), do: {:error, "its own"}
      end
    end
    """

    assert inventory([{"planted.ex", source}]) == %{
             {"planted.ex", "Planted.single/1"} => 1,
             {"planted.ex", "Planted.interpolated/1"} => 1,
             {"planted.ex", "Planted.joined/1"} => 1,
             {"planted.ex", "Planted.multiline/1"} => 1,
             {"planted.ex", "Planted.private/1"} => 1,
             {"planted.ex", "Planted.rescued/1"} => 1,
             {"planted.ex", "Planted.Inner.inner/1"} => 1
           }
  end
end
