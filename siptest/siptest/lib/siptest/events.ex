defmodule SipTest.Events do
  @moduledoc "Fan-out of run events to all connected browser sessions."

  def broadcast(event) do
    Registry.dispatch(SipTest.Clients, :ui, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event, event})
    end)
  end
end
