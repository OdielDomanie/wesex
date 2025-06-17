defmodule Wesex do
  @moduledoc """
  Example usage:

      defmodule AutobahnTest do
        alias Wesex.Connection
        use GenServer

        def start_link(opts) do
          {wesex_opts, genserver_opts} = Keyword.split(opts, [:url, :headers, :adapter_opts, :init_arg])
          GenServer.start_link(__MODULE__, wesex_opts, genserver_opts)
        end


        @impl GenServer
        def init(url: url) do
          {:ok, %{url: url, conn: nil}, {:continue, :connect}}
        end

        @impl GenServer
        def handle_continue(:connect, state) do
          {:ok, conn} = Connection.connect(state.url)
          {:noreply, %{state | conn: conn}}
        end

        @impl GenServer
        def handle_info(info, state) do
          {events, c} = Connection.event(state.conn, info)
          do_events(%{state | conn: c}, events)
        end

        defp do_events(state, []), do: {:noreply, state}

        defp do_events(state, [{:received, msg} | rest]) do
          {_, results, c} = Wesex.Connection.send(state.conn, msg)
          do_events(%{state | conn: c}, rest ++ results)
        end

        defp do_events(state, [:open | rest]) do
          do_events(state, rest)
        end

        defp do_events(state, [{:closing, _} | rest]) do
          do_events(state, rest)
        end

        defp do_events(state, [{:closed, _} | _rest]) do
          {:stop, :normal, state}
        end
      end
  """
end
