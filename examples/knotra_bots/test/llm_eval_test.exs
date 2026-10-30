defmodule KnotraBots.LLMEvalTest do
  @moduledoc """
  Live LLM-as-judge evaluation for the coordinator swarm.

  This module is tagged `:llm_eval` and excluded from ordinary `mix test`. Run it
  with a real provider key:

      mix test --only llm_eval

  The system under test is deterministic (fake models and tools). Tribunal's
  judge makes the real API calls, and `repeat: 3` with `pass_rule: :all` requires
  every judged attempt to pass.
  """
  use ExUnit.Case, async: false
  use Tribunal.ExUnit

  @moduletag :llm_eval

  @expected """
  Created agents: Refund Specialist, Stock Specialist.
  The in-policy refund for ord-5 completed.
  The out-of-policy refund for ord-3 was escalated without an effect.
  The restock completed.
  The notification completed.
  """

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    notices = Path.expand("../_build/llm-notices-#{suffix}.log", __DIR__)
    effects = Path.expand("../_build/llm-effects-#{suffix}.log", __DIR__)

    File.rm(notices)
    File.rm(effects)
    Application.put_env(:knotra_bots, :notices_path, notices)
    Application.put_env(:knotra_bots, :effects_path, effects)

    on_exit(fn ->
      File.rm(notices)
      File.rm(effects)

      Application.put_env(
        :knotra_bots,
        :notices_path,
        Path.expand("../_build/notices.log", __DIR__)
      )

      Application.put_env(
        :knotra_bots,
        :effects_path,
        Path.expand("../_build/effects.log", __DIR__)
      )
    end)

    :ok
  end

  test "the coordinator's created team is judged as correct" do
    output = fn ->
      case KnotraBots.Swarms.run(
             KnotraBots.Agents.list(),
             :coordinator,
             "Plan the refund and restock backlog"
           ) do
        {:ok, result} -> summary(result)
        {:error, {:incomplete, result}} -> summary(result)
        {:error, reason} -> "swarm failed: #{inspect(reason)}"
      end
    end

    result =
      tribunal_assert(output,
        input: "Plan the refund and restock backlog with a coordinator-created team.",
        evaluation_input: "Plan the refund and restock backlog with a coordinator-created team.",
        expected_output: @expected,
        expected: [correctness: [threshold: 0.8]],
        repeat: 3,
        pass_rule: :all
      )

    assert result.sample.repeat == 3
  end

  defp summary(result) do
    created =
      case result.created_agents do
        [] -> "none"
        names -> Enum.join(names, ", ")
      end

    """
    Created agents: #{created}.
    The in-policy refund for ord-5 #{completed(result, "refund-in-policy")}.
    The out-of-policy refund for ord-3 #{escalation(result, "refund-escalated")}.
    The restock #{completed(result, "restock")}.
    The notification #{completed(result, "notify")}.
    """
  end

  defp completed(result, id) do
    case Enum.find(result.tasks, &(&1.id == id)) do
      %{status: :completed} -> "completed"
      _ -> "did not complete"
    end
  end

  defp escalation(result, id) do
    case Enum.find(result.tasks, &(&1.id == id)) do
      %{error: :escalation_required} -> "was escalated without an effect"
      _ -> "was not escalated"
    end
  end
end
