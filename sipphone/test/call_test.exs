defmodule SipPhone.CallTest do
  # Two accounts without a registrar call each other directly over localhost UDP,
  # exercising INVITE / 180 / 200 / ACK / BYE end to end.
  use ExUnit.Case, async: false

  alias SipPhone.{Account, Accounts}

  setup do
    {:ok, a} = Accounts.save(%{"username" => "alice", "local_port" => 15060, "registrar" => ""})
    {:ok, b} = Accounts.save(%{"username" => "bob", "local_port" => 15061, "registrar" => "", "auto_answer" => false})

    on_exit(fn ->
      Accounts.delete(a)
      Accounts.delete(b)
    end)

    {:ok, a: a, b: b}
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      v = fun.() -> v
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(100) && wait_for(fun, tries - 1)
    end
  end

  test "direct call is established, then hung up by the caller", %{a: a, b: b} do
    assert {:ok, _cid} = Account.call(a, "127.0.0.1:15061")

    incoming =
      wait_for(fn ->
        Enum.find(Account.snapshot(b).calls, &(&1.dir == "in" and &1.state == "ringing"))
      end)

    assert :ok = Account.answer(b, incoming.id)

    wait_for(fn -> Enum.any?(Account.snapshot(a).calls, &(&1.state == "established")) end)
    wait_for(fn -> Enum.any?(Account.snapshot(b).calls, &(&1.state == "established")) end)

    [out] = Account.snapshot(a).calls
    assert :ok = Account.hangup(a, out.id)

    wait_for(fn -> Account.snapshot(a).calls == [] end)
    wait_for(fn -> Account.snapshot(b).calls == [] end)
  end

  test "caller can cancel while the callee is ringing", %{a: a, b: b} do
    assert {:ok, cid} = Account.call(a, "127.0.0.1:15061")
    wait_for(fn -> Enum.any?(Account.snapshot(b).calls, &(&1.state == "ringing")) end)
    wait_for(fn -> Enum.any?(Account.snapshot(a).calls, &(&1.state == "ringing")) end)
    assert :ok = Account.hangup(a, cid)
    wait_for(fn -> Account.snapshot(a).calls == [] end)
    wait_for(fn -> Account.snapshot(b).calls == [] end)
  end

  test "callee can decline", %{a: a, b: b} do
    assert {:ok, _} = Account.call(a, "127.0.0.1:15061")
    inc = wait_for(fn -> Enum.find(Account.snapshot(b).calls, &(&1.state == "ringing")) end)
    assert :ok = Account.hangup(b, inc.id)
    wait_for(fn -> Account.snapshot(a).calls == [] end)
  end
end
