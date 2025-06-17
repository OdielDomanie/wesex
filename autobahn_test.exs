defmodule AutobahnTest do
  alias Wesex.Connection
  # use Wesex

  use GenServer

  # Fails 6.4.3 and 6.4.4 when we send a ping first
  # Maybe a mint_web_socket bug?

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

  def run(from, to) do
    Task.async_stream(
      from..to,
      fn i ->
        {_pid, ref} =
          spawn_monitor(fn -> run_case(i) end)

        receive do
          {:DOWN, ^ref, _, _, _} ->
            nil
        end
      end,
      timeout: 300_000,
      max_concurrency: 20
    )
    |> Stream.run()
  end

  defp run_case(i) do
    {:ok, ws} =
      start_link(url: "ws://127.0.0.1:9001/runCase?case=#{i}&agent=wesex")

    ref = Process.monitor(ws)

    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end

  def update_report do
    {:ok, _ws} =
      start_link(url: "ws://127.0.0.1:9001/updateReports?agent=wesex")
  end
end

"""
podman run -it --rm \
    -v "${PWD}/autobahn/config:/config" \
    -v "${PWD}/autobahn/reports:/reports" \
    -p 9001:9001 \
    --name fuzzingserver \
    crossbario/autobahn-testsuite
"""
