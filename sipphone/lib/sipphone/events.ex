defmodule SipPhone.Events do
  @moduledoc "Fan-out of UI events and decoded audio to all connected browser sessions."

  def broadcast(event), do: dispatch({:event, event})

  def audio(call_id, pcm), do: dispatch({:audio, call_id, pcm})

  defp dispatch(msg) do
    Registry.dispatch(SipPhone.Clients, :ui, fn entries ->
      for {pid, _} <- entries, do: send(pid, msg)
    end)
  end
end
