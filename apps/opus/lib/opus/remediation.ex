# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Remediation do
  @moduledoc """
  Turn setup-related failures into machine-readable fix actions.

  Typed §4.3 error terms are the only source: an unbound need or a
  drifted consent is known exactly at resolution time, so nothing needs
  to be recovered from prose. Every fix points at the consent walk
  (`profile.plan`) — granting is the sheet's job, not a per-field patch.
  """

  alias Sanctum.Context

  @type issue :: %{
          String.t() => term()
        }

  @type remediation :: %{
          String.t() => term()
        }

  @doc """
  Analyze a failed sub-component execution into operator remediation.
  """
  @spec analyze(Context.t(), String.t() | tuple()) ::
          {:setup_required, remediation()} | :not_setup_error
  def analyze(ctx, error)

  def analyze(%Context{}, {:setup_required, %{} = payload}) do
    component_ref = payload[:node_ref] || payload["node_ref"] || ""
    need = payload[:need] || payload["need"] || ""
    reason = payload[:reason] || payload["reason"]

    base = %{
      "component_ref" => component_ref,
      "message" => setup_message(need, reason),
      "setup_command" => grant_command(component_ref),
      "profile_id" => payload[:profile_id] || payload["profile_id"]
    }

    issues =
      if need != "" do
        [
          %{
            "type" => "unbound_need",
            "need" => need,
            "message" => "The need #{inspect(need)} has no live credential bound",
            "fix" => %{
              "tool" => "profile",
              "action" => "plan",
              "args" => %{"ref" => component_ref}
            }
          }
        ]
      else
        []
      end

    {:setup_required, Map.put(base, "issues", issues)}
  end

  def analyze(%Context{}, {:consent_required, %{} = payload}) do
    profile_id = payload[:profile_id] || payload["profile_id"]
    revision = payload[:current_revision] || payload["current_revision"]

    {:setup_required,
     %{
       "component_ref" => "",
       "profile_id" => profile_id,
       "message" =>
         "This app's permissions changed since you approved them " <>
           "(consent revision #{inspect(revision)}). Review and approve to continue.",
       "setup_command" => "cyfr profile grant",
       "issues" => [
         %{
           "type" => "consent_required",
           "message" => "A new consent revision is required before this can run",
           "fix" => %{
             "tool" => "profile",
             "action" => "plan",
             "args" => %{"profile_id" => profile_id}
           }
         }
       ]
     }}
  end

  def analyze(_ctx, _reason), do: :not_setup_error

  defp setup_message("", reason),
    do: "This app needs setup before it can run (#{inspect(reason)})"

  defp setup_message(need, reason),
    do: "This app needs a connection for #{inspect(need)} (#{inspect(reason)})"

  defp grant_command(""), do: "cyfr profile grant"
  defp grant_command(ref), do: "cyfr profile grant #{ref}"
end
