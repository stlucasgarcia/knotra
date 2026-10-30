defmodule KnotraBots.Application do
  @moduledoc false
  use Application

  @instance KnotraBots.Instance

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: KnotraBots.PubSub},
      KnotraBots.Repo,
      instance_spec(),
      {Task.Supervisor, name: KnotraBots.TaskSupervisor},
      KnotraBots.Chat,
      KnotraBotsWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: KnotraBots.Supervisor)
  end

  @doc "Starts the Knotra runtime under the application supervisor."
  def start_instance do
    case Supervisor.restart_child(KnotraBots.Supervisor, @instance) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> Supervisor.start_child(KnotraBots.Supervisor, instance_spec())
      {:error, :running} -> {:ok, Process.whereis(@instance)}
      other -> other
    end
  end

  @doc "Stops the Knotra runtime without stopping the Repo; used for restart demonstrations."
  def stop_instance, do: Supervisor.terminate_child(KnotraBots.Supervisor, @instance)

  defp instance_spec do
    {Knotra,
     name: @instance,
     max_executions: 8,
     durable: [
       repo: KnotraBots.Repo,
       access: KnotraBots.Access,
       demo_tools: [
         KnotraBots.Tools.OrderLookup,
         KnotraBots.Tools.CustomerLookup,
         KnotraBots.Tools.StockLookup,
         KnotraBots.Tools.ReturnPolicy,
         KnotraBots.Tools.Notify,
         KnotraBots.Tools.Refund,
         KnotraBots.Tools.Restock
       ],
       max_pending: 50
     ]}
  end
end
