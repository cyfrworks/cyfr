# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Remediation do
  @moduledoc """
  Turn setup-related failures into machine-readable fix actions.

  Builds remediation from typed consent errors and directs callers to `profile.plan`.
  """

  @type issue :: %{
          String.t() => term()
        }

  @type remediation :: %{
          String.t() => term()
        }

  @doc """
  Analyze a failed sub-component execution into operator remediation.
  """
  @spec analyze(String.t() | tuple()) ::
          {:setup_required, remediation()} | :not_setup_error
  def analyze(error)

  def analyze({:setup_required, %{} = payload}) do
    component_ref = payload[:node_ref] || payload["node_ref"] || ""
    need = payload[:need] || payload["need"] || ""

    base = %{
      "component_ref" => component_ref,
      "message" => setup_message(need),
      "setup_command" => grant_command(component_ref),
      "profile_id" => payload[:profile_id] || payload["profile_id"]
    }

    issues =
      if need != "" do
        [
          %{
            "type" => "unbound_need",
            "need" => need,
            "message" => "The need \"#{need}\" has no live credential bound",
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

  def analyze({:consent_required, %{} = payload}) do
    component_ref = payload[:ref] || payload["ref"] || ""
    cause = to_string(payload[:cause] || payload["cause"])

    {:setup_required,
     %{
       "component_ref" => component_ref,
       "profile_id" => payload[:profile_id] || payload["profile_id"],
       "message" => consent_message(cause),
       "setup_command" => grant_command(component_ref),
       "issues" => [
         %{
           "type" => "consent_required",
           "message" => consent_message(cause),
           "fix" => %{
             "tool" => "profile",
             "action" => "plan",
             "args" => %{"ref" => component_ref}
           }
         }
       ]
     }}
  end

  def analyze(_reason), do: :not_setup_error

  # The payload's reason is the vault's own term for what is missing; the
  # issues carry the fix, so the sentence names only the need.
  defp setup_message(""), do: "This app needs setup before it can run"
  defp setup_message(need), do: "This app needs a vault entry for \"#{need}\""

  # Why a run has no grant to stand on (`Sanctum.Consent`'s errors).
  defp consent_message("no_grant"), do: "This app has not been granted yet"
  defp consent_message("revoked"), do: "This app's grant was revoked; grant it again to continue"

  defp consent_message(_moved),
    do: "This app asks for more than its grant holds; review and grant it again to continue"

  defp grant_command(""), do: "cyfr profile grant"
  defp grant_command(ref), do: "cyfr profile grant #{ref}"
end
