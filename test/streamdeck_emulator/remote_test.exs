defmodule StreamdeckEmulator.RemoteTest do
  # Remote is a named process shared with the rest of the suite.
  use ExUnit.Case, async: false

  alias StreamdeckEmulator.Remote

  setup do
    on_exit(&Remote.disable/0)
  end

  test "is off until enabled" do
    refute Remote.status().enabled
    refute Remote.enabled?()
    refute Remote.valid_token?("anything")
    refute Remote.valid_token?(nil)
  end

  test "enabling listens on the network with a pairing token in the URL" do
    assert {:ok, %{enabled: true, port: port} = status} = Remote.enable()
    assert is_integer(port) and port > 0

    if status.host do
      assert status.url =~ ~r"^http://#{Regex.escape(status.host)}:#{port}/remote\?pair="
      [_, token] = Regex.run(~r/pair=(.+)$/, status.url)
      assert Remote.valid_token?(token)
    end

    # The listener serves the same endpoint (here reached through loopback).
    assert {:ok, %{status: 200}} = Req.get("http://127.0.0.1:#{port}/api/state", retry: false)
  end

  test "enabling again makes a new code; disabling revokes it and stops listening" do
    {:ok, first} = Remote.enable()
    old = token(first)
    {:ok, second} = Remote.enable()
    assert second.port == first.port

    if old do
      refute Remote.valid_token?(old)
      assert Remote.valid_token?(token(second))
    end

    :ok = Remote.disable()
    refute Remote.enabled?()
    assert {:error, _} = Req.get("http://127.0.0.1:#{first.port}/api/state", retry: false)
  end

  test "lists private IPv4 addresses" do
    for ip <- Remote.lan_addresses() do
      assert ip =~ ~r/^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/
    end
  end

  defp token(%{url: nil}), do: nil

  defp token(%{url: url}),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("pair")
end
