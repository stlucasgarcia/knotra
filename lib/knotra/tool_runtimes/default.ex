defmodule Knotra.ToolRuntimes.Default do
  @moduledoc """
  Default tool execution boundary: host argument validation, authorization, then
  execution. This milestone accepts only declared read-only tools; that restriction
  is policy, not a sandbox or a separate execution mechanism.
  """
  @behaviour Knotra.ToolRuntime

  @impl true
  def execute(call, tools, auth, _opts) do
    with {:ok, module, validated} <- prepare(call, tools, auth, false),
         {:ok, output} when is_binary(output) <- module.call(validated, auth) do
      {:ok, validated, output}
    else
      {:ok, _non_binary} -> {:error, :invalid_plugin_result}
      other -> other
    end
  end

  @doc false
  def prepare(%{name: name, arguments: args}, tools, auth, approval_only) do
    case Enum.find(tools, &(&1.definition().name == name)) do
      nil ->
        {:error, :unknown_tool}

      module ->
        definition = module.definition()

        with true <-
               definition.read_only == true or (approval_only and definition.read_only == false),
             true <- is_map(args),
             {:ok, validated} when is_map(validated) <- module.validate(args),
             :ok <- module.authorize(validated, auth) do
          {:ok, module, validated}
        else
          false -> {:error, :write_tool_not_supported}
          {:error, reason} when is_atom(reason) -> {:error, reason}
          _ -> {:error, :invalid_arguments}
        end
    end
  end

  @doc false
  def schema(definition) do
    ReqLLM.Tool.new(
      name: definition.name,
      description: definition.description,
      parameter_schema: definition.parameters,
      callback: fn _ -> {:error, :use_knotra_tool_runtime} end
    )
  end
end
