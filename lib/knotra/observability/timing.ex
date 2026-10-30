defmodule Knotra.Observability.Timing do
  @moduledoc false

  @terminal [:completed, :failed, :cancelled, :blocked, :rejected, :expired, :waiting]

  @doc """
  Derives turn and phase timings from an execution's oldest-first event list.

  A turn starts at `:model_started` and ends at the next `:model_started`, a
  terminal status (including `:waiting`), or the last event, so it includes the
  model call and any tool work that follows it. A durable wait does not inflate
  the turn duration; a tool approved during the wait still contributes its
  execution time to the aggregate `tool_ms`.
  `model_ms` is model-request to model-reply latency; `tool_ms` is the sum of
  completed tool calls in the turn.
  """
  def summarize(events) when is_list(events) do
    total_ms =
      case List.last(events) do
        nil -> 0
        %{elapsed_ms: elapsed} -> max(elapsed, 0)
      end

    {turns, open, _tools, detached_ms} =
      Enum.reduce(events, {[], nil, %{}, 0}, fn event, {turns, open, tools, detached_ms} ->
        case event.type do
          :model_started ->
            turns = close_turn(open, event.elapsed_ms, turns)

            turn = %{
              number: length(turns) + 1,
              started_ms: event.elapsed_ms,
              model_started_ms: event.elapsed_ms,
              model_ms: 0,
              tool_ms: 0,
              other_ms: 0,
              duration_ms: 0,
              ended_ms: nil,
              tools: 0,
              usage: nil
            }

            {turns, turn, tools, detached_ms}

          :model_result ->
            open =
              case open do
                nil ->
                  nil

                turn ->
                  %{
                    turn
                    | model_ms: max(event.elapsed_ms - turn.model_started_ms, 0),
                      usage: Map.get(event.data || %{}, :usage)
                  }
              end

            {turns, open, tools, detached_ms}

          :tool_started ->
            {turns, open, put_tool(tools, event), detached_ms}

          :tool_result ->
            {turns, open, tools, detached_ms} =
              take_tool(turns, open, tools, detached_ms, event)

            {turns, open, tools, detached_ms}

          type when type in @terminal ->
            # A wait closes the turn but keeps pending tool starts: the approved
            # call runs after the wait, before the next model turn.
            tools = if type == :waiting, do: tools, else: %{}
            {close_turn(open, event.elapsed_ms, turns), nil, tools, detached_ms}

          _ ->
            {turns, open, tools, detached_ms}
        end
      end)

    turns = close_turn(open, total_ms, turns) |> Enum.reverse()

    durations = Enum.map(turns, & &1.duration_ms)
    model_ms = Enum.sum(Enum.map(turns, & &1.model_ms))
    tool_ms = Enum.sum(Enum.map(turns, & &1.tool_ms)) + detached_ms
    turn_count = length(turns)

    %{
      total_ms: total_ms,
      turn_count: turn_count,
      last_turn_ms: List.last(durations) || 0,
      avg_turn_ms: if(turn_count == 0, do: 0, else: div(Enum.sum(durations), turn_count)),
      slowest_turn_ms: if(durations == [], do: 0, else: Enum.max(durations)),
      model_ms: model_ms,
      tool_ms: tool_ms,
      other_ms: Enum.sum(Enum.map(turns, & &1.other_ms)),
      turns: turns
    }
  end

  @doc "Aggregate timing fields without the per-turn list."
  def summary(events) do
    events |> summarize() |> Map.delete(:turns)
  end

  defp close_turn(nil, _ended_ms, turns), do: turns

  defp close_turn(turn, ended_ms, turns) do
    ended_ms = max(ended_ms, turn.started_ms)
    duration_ms = ended_ms - turn.started_ms
    other_ms = max(duration_ms - turn.model_ms - turn.tool_ms, 0)

    turn = %{
      turn
      | ended_ms: ended_ms,
        duration_ms: duration_ms,
        other_ms: other_ms
    }

    [turn | turns]
  end

  defp put_tool(tools, event) do
    data = event.data || %{}
    call = Map.get(data, :call) || %{}

    case call_id(call) do
      nil -> tools
      id -> Map.put(tools, id, event.elapsed_ms)
    end
  end

  defp take_tool(turns, nil, tools, detached_ms, event) do
    case tool_duration(tools, event) do
      {:ok, duration, tools} -> {turns, nil, tools, detached_ms + duration}
      :error -> {turns, nil, tools, detached_ms}
    end
  end

  defp take_tool(turns, open, tools, detached_ms, event) do
    data = event.data || %{}
    call = Map.get(data, :call) || %{}
    id = call_id(call)

    case id && Map.pop(tools, id) do
      {started_ms, tools} when is_integer(started_ms) ->
        duration_ms = max(event.elapsed_ms - started_ms, 0)

        turn = %{
          open
          | tool_ms: open.tool_ms + duration_ms,
            tools: open.tools + 1
        }

        {turns, turn, tools, detached_ms}

      _ ->
        {turns, open, tools, detached_ms}
    end
  end

  defp tool_duration(tools, event) do
    data = event.data || %{}
    call = Map.get(data, :call) || %{}
    id = call_id(call)

    case id && Map.pop(tools, id) do
      {started_ms, tools} when is_integer(started_ms) ->
        {:ok, max(event.elapsed_ms - started_ms, 0), tools}

      _ ->
        :error
    end
  end

  defp call_id(%{id: id}) when is_binary(id), do: id
  defp call_id(_call), do: nil
end
