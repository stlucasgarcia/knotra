defmodule KnotraBots.Tools.Refund do
  @moduledoc """
  Approval-gated refund for a return-eligible order.

  `read_only: false` makes this a consequential proposal: the durable runtime
  records a bound approval, and the chat relay waits for a human decision. The
  effect is a fake append to the demo's effects ledger; no money moves and no
  payment provider is contacted.
  """

  @behaviour Knotra.Tool

  alias KnotraBots.Commerce

  @impl true
  def definition do
    %{
      name: "refund",
      description: "Issue a refund for a return-eligible order (mock ledger effect)",
      read_only: false,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "order" => %{"type" => "string"},
          "reason" => %{"type" => "string"}
        },
        "required" => ["order", "reason"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def validate(%{"order" => order, "reason" => reason} = args)
      when is_binary(order) and order != "" and is_binary(reason) and reason != "" and
             map_size(args) == 2 do
    with true <- String.length(reason) <= 240,
         {:ok, order} <- existing_order(order),
         %{eligible: true} <- Commerce.return_policy(order) do
      {:ok, args}
    else
      false -> {:error, :reason_too_long}
      {:error, reason} -> {:error, reason}
      %{eligible: false} -> {:error, :not_return_eligible}
    end
  end

  def validate(_args), do: {:error, :invalid_arguments}

  @impl true
  def authorize(_args, %{tenant: tenant}) do
    if tenant == KnotraBots.tenant(), do: :ok, else: {:error, :forbidden}
  end

  @impl true
  def call(%{"order" => order, "reason" => reason}, _scope) do
    order = String.downcase(String.trim(order))
    amount = Commerce.total_cents(Commerce.order(order))

    append("refund #{order} #{Commerce.money(amount)} · #{reason}")

    {:ok, "Refund of #{Commerce.money(amount)} for #{order} queued: #{reason}."}
  end

  defp existing_order(order) do
    order = String.downcase(String.trim(order))

    if Commerce.order?(order), do: {:ok, Commerce.order(order)}, else: {:error, :unknown_order}
  end

  defp append(line) do
    path = KnotraBots.effects_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, line <> "\n", [:append])
  end
end
