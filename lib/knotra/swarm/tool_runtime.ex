defmodule Knotra.Swarm.ToolRuntime do
  @moduledoc """
  Swarm-scoped tool boundary for members that may declare write tools.

  Read-only calls keep the default validate/authorize/execute path. A write call
  is validated and authorized first, then the swarm's host-supplied
  `:write_policy` decides:

  * `:approve` executes the tool once;
  * `{:escalate, reason}` records an escalation with the coordinator and returns
    `{:error, :escalation_required}` without calling the tool;
  * `:reject` returns `{:error, :write_rejected}` without an effect.

  The policy is a trusted host function; model output never grants authority.
  The coordinator must record the escalation before the member's terminal
  snapshot, so the runtime uses a bounded synchronous call.
  """

  @behaviour Knotra.ToolRuntime

  @escalation_timeout 5_000

  @impl true
  def supports_writes?, do: true

  @impl true
  def execute(call, tools, auth, opts) do
    with {:ok, module, validated} <-
           Knotra.ToolRuntimes.Default.prepare(call, tools, auth, true) do
      if module.definition().read_only do
        delegate_or_invoke(opts[:delegate], call, tools, auth, module, validated)
      else
        case decide(opts[:policy], call, validated, opts) do
          :approve -> invoke(module, validated, auth)
          :reject -> {:error, :write_rejected}
          {:escalate, reason} -> escalate(opts, call, validated, reason)
          _other -> {:error, :invalid_write_policy}
        end
      end
    end
  end

  defp delegate_or_invoke({delegate, delegate_opts}, call, tools, auth, _module, _validated)
       when delegate != __MODULE__ do
    delegate.execute(call, tools, auth, delegate_opts)
  end

  defp delegate_or_invoke(_delegate, _call, _tools, auth, module, validated) do
    invoke(module, validated, auth)
  end

  defp invoke(module, args, auth) do
    case module.call(args, auth) do
      {:ok, output} when is_binary(output) -> {:ok, output}
      other -> other
    end
  end

  defp decide(nil, _call, _args, _opts), do: {:escalate, :no_write_policy}
  defp decide(fun, call, args, opts) when is_function(fun, 3), do: fun.(call, args, opts)
  defp decide(fun, call, args, _opts) when is_function(fun, 2), do: fun.(call, args)

  defp decide({module, function}, call, args, opts)
       when is_atom(module) and is_atom(function),
       do: apply(module, function, [call, args, opts])

  defp decide(_policy, _call, _args, _opts), do: :reject

  defp escalate(opts, call, arguments, reason) do
    record(opts[:coordinator], %{
      agent: opts[:agent],
      task: opts[:task],
      tool: call.name,
      arguments: arguments,
      reason: reason
    })

    {:error, :escalation_required}
  end

  defp record(coordinator, escalation) when is_pid(coordinator) do
    GenServer.call(coordinator, {:escalation, escalation}, @escalation_timeout)
  catch
    :exit, _ -> :ok
  end

  defp record(_coordinator, _escalation), do: :ok
end
