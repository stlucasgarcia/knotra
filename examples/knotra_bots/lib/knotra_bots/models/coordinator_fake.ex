defmodule KnotraBots.Models.CoordinatorFake do
  @moduledoc """
  Offline coordinator model.

  Returns a fixed plan for the storefront backlog so the coordinator path runs
  without a provider. The online path uses the configured ReqLLM model with the
  same JSON contract.
  """

  @behaviour Knotra.Model

  @impl true
  def call(_request, _opts), do: {:ok, %Knotra.Reply{text: JSON.encode!(plan())}}

  @doc "The fixed plan used by the offline demo and tests."
  def plan do
    %{
      "agents" => [
        %{
          "name" => "Refund Specialist",
          "handle" => "refund-specialist",
          "prompt" =>
            "You review refunds. Look up the order and its return policy before proposing a refund.",
          "tools" => ["order_lookup", "return_policy", "refund"]
        },
        %{
          "name" => "Stock Specialist",
          "handle" => "stock-specialist",
          "prompt" =>
            "You own stock. Check the SKU and propose a restock when the quantity is safe.",
          "tools" => ["stock_lookup", "restock"]
        }
      ],
      "tasks" => [
        %{
          "id" => "refund-in-policy",
          "input" => "refund ord-5 because it arrived late",
          "agent" => "Refund Specialist",
          "depth" => 0
        },
        %{
          "id" => "refund-escalated",
          "input" => "refund ord-3 because it arrived late",
          "agent" => "Refund Specialist",
          "depth" => 0
        },
        %{
          "id" => "restock",
          "input" => "restock sku-tee-01 by 24 units",
          "agent" => "Stock Specialist",
          "depth" => 0
        },
        %{
          "id" => "notify",
          "input" => "notify ops that ord-4 is delayed",
          "agent" => "Concierge",
          "depth" => 0
        }
      ]
    }
  end
end
