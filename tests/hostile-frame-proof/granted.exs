# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The containment proof's flowed control, granted: evaluated inside the
# running server by `bin/cyfr rpc` (tests/hostile-frame-proof/run.sh), the
# person's grant of their local tincture NAME as the consent walk makes it —
# plan, preview, commit — under their session, as the console asks under it,
# on the interactive path, granting the
# whole ask, its flows among it. Answers one line, `GRANTED=` and the
# profile's id; a plan the components projection cannot answer yet is
# asked again, for up to ten seconds.

fn [token, name] ->
  {:ok, console} = Sanctum.Caller.establish({:session, token})
  ctx = %{console | origin: :interactive}
  ref = "tincture:local." <> name
  decisions = %{ref: ref, origins: [:interactive]}

  # The components projection may still be behind the unit the proof just
  # wrote, which the plan answers as unavailable rather than waiting.
  plan =
    Enum.reduce_while(1..100, nil, fn _try, _ ->
      case Sanctum.Consent.Plan.plan(ctx, %{ref: ref}) do
        {:ok, plan} ->
          {:halt, plan}

        {:error, {:unavailable, _what}} ->
          Process.sleep(100)
          {:cont, nil}
      end
    end)
  {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

  {:ok, %{profile_id: profile_id}} =
    Sanctum.Consent.Commit.commit(ctx, %{
      decisions: decisions,
      plan_token: plan.plan_token,
      proof: preview.proof,
      commit_digest: preview.commit_digest,
      expected_consent_revision: plan.expected_consent_revision
    })

  "GRANTED=" <> profile_id
end
