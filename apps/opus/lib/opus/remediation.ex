# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Remediation do
  @moduledoc """
  Detect setup-related errors and generate machine-readable fix actions.

  When a sub-component invocation fails due to a missing policy, missing
  secret grant, or missing allowed_domains, this module detects the error
  pattern and calls `component.setup_plan` to produce structured remediation
  info that consumers (Prism, SSE clients) can render as one-click fix buttons.
  """

  require Logger

  alias Sanctum.Context

  @type issue :: %{
          String.t() => term()
        }

  @type remediation :: %{
          String.t() => term()
        }

  @doc """
  Analyze an error string from a sub-component execution.

  If it's a setup issue, calls `setup_plan` to get exact issues and fix actions.
  Returns `{:setup_required, remediation_map}` or `:not_setup_error`.
  """
  @spec analyze(Context.t(), String.t()) :: {:setup_required, remediation()} | :not_setup_error
  def analyze(%Context{} = ctx, error_reason) when is_binary(error_reason) do
    case detect_setup_error(error_reason) do
      {:match, component_ref} ->
        remediation = build_remediation(ctx, component_ref, error_reason)
        {:setup_required, remediation}

      :no_match ->
        :not_setup_error
    end
  end

  def analyze(_ctx, _reason), do: :not_setup_error

  # ============================================================================
  # Detection Heuristics
  # ============================================================================

  # Pattern match on known error message patterns and extract component_ref.
  defp detect_setup_error(reason) do
    cond do
      # "Catalyst 'catalyst:local.stripe:0.1.0' has no capabilities configured."
      match = Regex.run(~r/'([^']+)' has no capabilities configured/, reason) ->
        {:match, Enum.at(match, 1)}

      # "Catalyst 'X' has no allowed_domains configured"
      match = Regex.run(~r/'([^']+)' has no allowed_domains configured/, reason) ->
        {:match, Enum.at(match, 1)}

      # "access-denied: SECRET_NAME not granted to component_ref"
      match = Regex.run(~r/access-denied: \S+ not granted to (\S+)/, reason) ->
        {:match, Enum.at(match, 1)}

      # "Secret 'X' not granted to component 'ref'"
      match = Regex.run(~r/not granted to component '([^']+)'/, reason) ->
        {:match, Enum.at(match, 1)}

      # "Failed to resolve N secret(s) for component_ref: ..."
      match = Regex.run(~r/Failed to resolve \d+ secret\(s\) for (\S+):/, reason) ->
        {:match, Enum.at(match, 1)}

      # "authorization_required: run oauth.authorize for catalyst:local.gmail:0.1.0 provider google"
      match = Regex.run(~r/authorization_required:.*for (\S+) provider/, reason) ->
        {:match, Enum.at(match, 1)}

      true ->
        :no_match
    end
  end

  # ============================================================================
  # Remediation Building
  # ============================================================================

  defp build_remediation(ctx, component_ref, error_reason) do
    base = %{
      "component_ref" => component_ref,
      "message" => error_reason,
      "setup_command" => "cyfr setup #{component_ref}"
    }

    case fetch_setup_plan(ctx, component_ref) do
      {:ok, plan} ->
        issues = build_issues_from_plan(plan, component_ref)
        Map.put(base, "issues", issues)

      :error ->
        # Fallback: return base info without detailed issues
        Map.put(base, "issues", [])
    end
  end

  defp fetch_setup_plan(ctx, component_ref) do
    case Compendium.Component.setup_plan(ctx, component_ref) do
      {:ok, plan} ->
        {:ok, plan}

      {:error, reason} ->
        Logger.debug(
          "[Opus.Remediation] setup_plan failed for #{component_ref}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp build_issues_from_plan(plan, component_ref) do
    secret_issues = build_secret_issues(plan, component_ref)
    policy_issues = build_policy_issues(plan, component_ref)
    oauth_issues = build_oauth_issues(plan, component_ref)
    secret_issues ++ policy_issues ++ oauth_issues
  end

  defp build_secret_issues(plan, component_ref) do
    secrets = plan[:secrets] || plan["secrets"] || []

    secrets
    |> Enum.filter(fn s ->
      not (get_field(s, :already_granted) == true)
    end)
    |> Enum.map(fn secret ->
      name = get_field(secret, :name)
      already_set = get_field(secret, :already_set) == true

      %{
        "type" => if(already_set, do: "missing_secret_grant", else: "missing_secret"),
        "secret_name" => name,
        "description" => get_field(secret, :description),
        "already_set" => already_set,
        "fix" => %{
          "tool" => "secret",
          "action" => "grant",
          "args" => %{
            "name" => name,
            "component_ref" => component_ref
          }
        }
      }
    end)
  end

  defp build_policy_issues(plan, component_ref) do
    policy_current = plan[:policy_current] || plan["policy_current"]
    policy_recommended = plan[:policy_recommended] || plan["policy_recommended"]

    issues = []

    # Check if policy exists at all
    if is_nil(policy_current) and not is_nil(policy_recommended) do
      # No policy exists — recommend setting up the full policy
      recommended = policy_recommended

      domain_issue =
        if domains = recommended["allowed_domains"] || recommended[:allowed_domains] do
          [
            %{
              "type" => "missing_policy",
              "field" => "allowed_domains",
              "recommended" => domains,
              "fix" => %{
                "tool" => "policy",
                "action" => "patch",
                "args" => %{
                  "component_ref" => component_ref,
                  "field" => "allowed_domains",
                  "value" =>
                    case Jason.encode(domains) do
                      {:ok, j} -> j
                      {:error, _} -> "[]"
                    end
                }
              }
            }
          ]
        else
          []
        end

      path_issue =
        if paths = recommended["allowed_paths"] || recommended[:allowed_paths] do
          [
            %{
              "type" => "missing_policy",
              "field" => "allowed_paths",
              "recommended" => paths,
              "fix" => %{
                "tool" => "policy",
                "action" => "patch",
                "args" => %{
                  "component_ref" => component_ref,
                  "field" => "allowed_paths",
                  "value" =>
                    case Jason.encode(paths) do
                      {:ok, j} -> j
                      {:error, _} -> "[]"
                    end
                }
              }
            }
          ]
        else
          []
        end

      issues ++ domain_issue ++ path_issue
    else
      if not is_nil(policy_current) and not is_nil(policy_recommended) do
        # Policy exists but may be missing fields
        check_policy_field_gaps(policy_current, policy_recommended, component_ref)
      else
        issues
      end
    end
  end

  defp check_policy_field_gaps(current, recommended, component_ref) do
    current_domains = get_field(current, :allowed_domains) || []
    rec_domains = get_field(recommended, :allowed_domains) || []

    domain_issue =
      if rec_domains != [] and current_domains == [] do
        [
          %{
            "type" => "missing_policy",
            "field" => "allowed_domains",
            "recommended" => rec_domains,
            "fix" => %{
              "tool" => "policy",
              "action" => "patch",
              "args" => %{
                "component_ref" => component_ref,
                "field" => "allowed_domains",
                "value" =>
                  case Jason.encode(rec_domains) do
                    {:ok, j} -> j
                    {:error, _} -> "[]"
                  end
              }
            }
          }
        ]
      else
        []
      end

    current_paths = get_field(current, :allowed_paths) || []
    rec_paths = get_field(recommended, :allowed_paths) || []

    path_issue =
      if rec_paths != [] and current_paths == [] do
        [
          %{
            "type" => "missing_policy",
            "field" => "allowed_paths",
            "recommended" => rec_paths,
            "fix" => %{
              "tool" => "policy",
              "action" => "patch",
              "args" => %{
                "component_ref" => component_ref,
                "field" => "allowed_paths",
                "value" =>
                  case Jason.encode(rec_paths) do
                    {:ok, j} -> j
                    {:error, _} -> "[]"
                  end
              }
            }
          }
        ]
      else
        []
      end

    domain_issue ++ path_issue
  end

  defp build_oauth_issues(plan, component_ref) do
    oauth = plan[:oauth] || plan["oauth"] || []

    oauth
    |> Enum.filter(fn provider_status ->
      not (get_field(provider_status, :ready) == true)
    end)
    |> Enum.map(fn provider_status ->
      provider = get_field(provider_status, :provider)

      %{
        "type" => "oauth_authorization_required",
        "provider" => provider,
        "fix" => %{
          "tool" => "oauth",
          "action" => "authorize",
          "args" => %{
            "component_ref" => component_ref,
            "provider" => provider
          }
        }
      }
    end)
  end

  # Helper to get a field from a map with either atom or string keys.
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
