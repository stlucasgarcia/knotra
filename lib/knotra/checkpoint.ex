defmodule Knotra.Checkpoint do
  @moduledoc false
  @max_bytes 2_000_000
  def version, do: 2
  @structs [Knotra.Reply, ReqLLM.Message, ReqLLM.Message.ContentPart, ReqLLM.ToolCall]
  # Literal vocabulary is loaded with this module in every fresh VM. Being an
  # existing atom in the writer VM is not proof that a checkpoint is portable.
  # Arbitrary model metadata should use string keys/values, not dynamic atoms.
  @portable_atoms ~w(
    nil true false ok error format input options response_timeout loop_state
    exchanges last counts limits stage remaining_ms approval version id call_id
    name arguments disposition pending expires_at definition_version status output
    events observation_error turns tools retries steps max_turns max_tool_calls
    max_retries max_steps timeout reply results call text calls usage continuation
    accepted running waiting blocked failed completed cancelled model tool setup
    loop observation terminal_observation started model_started model_result
    tool_started tool_result retry sequence elapsed_ms type data reason
    role content tool_calls tool_call_id metadata reasoning_details response_id function
    filename url file_id media_type assistant user system developer thinking
    image image_url audio video video_url file cache_control ephemeral
    input_tokens output_tokens total_tokens cached_tokens cache_read_tokens
    cache_creation_tokens reasoning_tokens input_tokens_details output_tokens_details
    input_cost output_cost total_cost
    invalid_configuration unsupported_composition invalid_tool_definitions
    invalid_model_reply invalid_tool_request pending_tools turn_limit tool_limit
    step_limit retries_exhausted deadline_exceeded plugin_exception plugin_exit
    task_exit invalid_plugin_result observer_failed observer_timeout
    unsupported_checkpoint checkpoint_too_large stale_execution persistence_unavailable
    persistence_failed incompatible_checkpoint interrupted unknown_tool
    write_tool_not_supported forbidden invalid_arguments model_error
    unsupported_tool_call incomplete_response empty_response provider_unavailable
    temporarily_unavailable answered_version decision approve reject rejected approval_rejected
    approved operation decided dispatching succeeded result not_dispatched dispatch_not_started
    uncertain_effect approval_mismatch expired approval_expired ready admitted operation_id active_deadline_at approval_answered request_id
  )a

  # Only inert data, never functions, processes, ports or references. Do not decode
  # arbitrary Erlang terms, create atoms, or serialize the execution process state.
  def encode(value) do
    if data?(value) do
      bytes = :erlang.term_to_binary(value)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: {:error, :checkpoint_too_large}
    else
      {:error, :unsupported_checkpoint}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    Enum.each(@structs, &Code.ensure_loaded/1)

    try do
      value = :erlang.binary_to_term(bytes, [:safe])
      if data?(value), do: {:ok, value}, else: {:error, :unsupported_checkpoint}
    rescue
      ArgumentError -> {:error, :unsupported_checkpoint}
    end
  end

  def decode(_), do: {:error, :unsupported_checkpoint}

  defp data?(value) when is_atom(value), do: value in @portable_atoms
  defp data?(value) when is_binary(value) or is_number(value), do: true
  defp data?([]), do: true
  defp data?([head | tail]), do: data?(head) and list?(tail)
  defp data?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&data?/1)

  defp data?(%{__struct__: module} = value) when module in @structs,
    do: value |> Map.from_struct() |> data?()

  defp data?(%{__struct__: _}), do: false

  defp data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> data?(key) and data?(item) end)

  defp data?(_), do: false
  defp list?([]), do: true
  defp list?([head | tail]), do: data?(head) and list?(tail)
  defp list?(_), do: false
end
