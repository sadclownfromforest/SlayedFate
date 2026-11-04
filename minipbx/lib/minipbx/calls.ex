defmodule MiniPbx.Calls do
  @moduledoc "Calls that are in progress (each `MiniPbx.Call` publishes its summary in the registry)."

  def active do
    MiniPbx.CallReg
    |> Registry.select([{{{:active, :"$1"}, :_, :"$2"}, [], [:"$2"]}])
    |> Enum.sort_by(& &1["started"])
  end

  def hangup(id) when is_binary(id), do: MiniPbx.Call.admin_hangup(id)
end
